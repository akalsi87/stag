#lang racket

(provide 
  ; Return a (list types-module util-module) of python-module objects.
  bdlat->python-modules 

  ; Write a python source code entity to a string.
  render-python

  ; TODO: For testing only (but how *will* unit testing work?)
  bdlat->name-map
  bdlat->types-module

  ; values describing parts of python code
  (struct-out python-module)      (struct-out python-import)
  (struct-out python-class)       (struct-out python-annotation)
  (struct-out python-assignment)  (struct-out python-def)
  (struct-out python-invoke)      (struct-out python-dict))

(require (prefix-in bdlat: "bdlat.rkt") ; BDE "attribute types" from SXML
         threading                      ; thrush combinator macros (~> ~>>)
         srfi/1                         ; list procedures (e.g. any)
         scribble/text/wrap)            ; (wrap-line text num-chars)

; TODO: For use when developing only.
(define (TODO)
  (error "You've encountered something that is not yet implemented."))

(struct python-module
  (description ; string
   docs        ; list of paragraphs (strings)
   imports     ; list of python-import
   statements) ; list of any of python-class, python-assignment, etc.
  #:transparent) 

(struct python-import
  (from-module ; symbol
   symbols)    ; a list of symbols or a single symbol
  #:transparent) 

(struct python-class
  (name        ; symbol
   bases       ; list of symbols
   docs        ; list of paragraphs (strings)
   statements) ; list of annotations and/or assignments
  #:transparent) 

(struct python-annotation
  (attribute ; symbol
   type      ; string or list of symbol/string
   docs      ; list of paragraphs
   default)  ; default value ('#:omit to ignore)
  #:transparent) 

(struct python-assignment
  (lhs   ; symbol
   rhs   ; value
   docs) ; list of paragraphs
  #:transparent) 

(struct python-def
  (name  ; symbol
   args  ; list of either symbol or pair (symbol, value)
   body) ; list of statements
  #:transparent) 

(struct python-invoke
  (name  ; symbol or list of symbol
   args) ; list of either value or pair (symbol, value)
  #:transparent) 

(struct python-dict
  (items) ; list of pair (key, value)
  #:transparent) 

(define (contains-array? bdlat-type)
  ; Return whether the specified bdlat-type contains an array; i.e. whether
  ; it's either a sequence with an array-typed element or a choice with an
  ; array-typed element.
  (match-type-class bdlat-type contains-array? bdlat:array bdlat:nullable))

(define (contains-nullable? bdlat-type)
  ; Return whether the specified bdlat-type contains an nullable; i.e. whether
  ; it's either a sequence with an nullable-typed element or a choice with an
  ; nullable-typed element.
  (match-type-class bdlat-type contains-nullable? bdlat:nullable bdlat:array))

(define-syntax-rule (match-type-class argument recur matching-case other-case)
  ; Generate code that is the shared body between contains-array? and
  ; contains-nullable?. The matching-case is the type class that we're
  ; looking for (either bdlat:array or bdlat:nullable), while other-case
  ; is the one we're not looking for (e.g. bdlat:nullable or bdlat:array).
  ; recur is the name of the procedure in which this macro is being used; the
  ; idea is to define a recursive procedure. argument is the initial bdlat
  ; type on which to match.
  (match argument
    [(bdlat:sequence _ _ elements) (any recur elements)]
    [(bdlat:choice _ _ elements)   (any recur elements)]
    [(bdlat:element _ type _ _)    (recur type)]
    [(other-case type)             (recur type)]
    [(matching-case _)             #t]
    [_                             #f]))

(define (contains-basic-type? bdlat-type matching-case)
  ; Return whether the specified bdlat type contains within it the basic type
  ; specified as matching-base.
  (let recur ([outer-type bdlat-type])
    (match outer-type
        [(bdlat:sequence _ _ elements) (any recur elements)]
        [(bdlat:choice _ _ elements)   (any recur elements)]
        [(bdlat:element _ type _ _)    (recur type)]
        [(bdlat:nullable type)         (recur type)]
        [(bdlat:array type)            (recur type)]
        [(bdlat:basic type)            (equal? type matching-case)]
        [_                             #f])))

(define (bdlat->imports types)
  ; Deduce from the specified bdlat types which python modules a module
  ; defining those types must import.
  ; e.g. if there are any "sequence" types, then NamedTuple will have to be
  ; imported from the typing module. Note that bdlat->built-in also contains
  ; information about which bdlat basic types map to python types, so if
  ; either procedure is modified, the other might need to be updated as well.

  (define (maybe-import predicate import-args)
    ; If the predicate is true for any of the types, return
    ; (python-import ...). Otherwise return the empty list. This is used
    ; below to construct a list of imports.
    (if (any predicate types)
      (list (apply python-import import-args))
      '()))

  (append
    (maybe-import (lambda (type) (contains-basic-type? type "date")) 
      '(datetime date))
    (maybe-import (lambda (type) (contains-basic-type? type "time")) 
      '(datetime time))
    (maybe-import (lambda (type) (contains-basic-type? type "dateTime")) 
      '(datetime datetime))
    (maybe-import (lambda (type) (contains-basic-type? type "duration")) 
      '(datetime timedelta))
    (maybe-import bdlat:enumeration? '(enum Enum))
    (maybe-import bdlat:choice? '(namedunion NamedUnion))
    (maybe-import contains-array? '(typing List))
    (maybe-import bdlat:sequence? '(typing NamedTuple))
    (maybe-import contains-nullable? '(typing Optional))))

(define (bdlat-name->class-name bdlat-name)
  ; TODO: stub
  bdlat-name)

(define (bdlat-name->attribute-name bdlat-name)
  ; TODO: stub
  bdlat-name)

(define (bdlat-name->enumeration-value-name bdlat-name)
  ; TODO: stub
  bdlat-name)

(define (extend-name-map name-map bdlat-type)
  ; Fill the specified hash table with mappings between the names of
  ; user-defined types and elements from the specified bdlat-type into
  ; python class and attribute names. Return the hash table, which is modified
  ; in place (unless there are no names to map, in which case it's returned
  ; unmodified).
  (let recur ([name-map name-map] ; the hash table we're populating
              [class-name #f]     ; when we recur on a type's elements
              [item bdlat-type])  ; the bdlat struct we're inspecting
    (match item
        [(bdlat:sequence name _ elements)
         ; Map the sequence name as a class name and then recur on each of its
         ; elements to map their names.
         (hash-set! name-map name 
           (~> name bdlat-name->class-name string->symbol))
         (for-each (lambda (elem) (recur name-map name elem)) elements)]

        [(bdlat:choice name _ elements)   
         ; Map the choice name as a class name and then recur on each of its
         ; elements to map their names.
         (hash-set! name-map name 
           (~> name bdlat-name->class-name string->symbol))
         (for-each (lambda (elem) (recur name-map name elem)) elements)]

        [(bdlat:enumeration name _ values)
         ; Map the enumeration name as a class name and then recur on each of
         ; its values to map their names.
         (hash-set! name-map name 
           (~> name bdlat-name->class-name string->symbol))
         (for-each (lambda (value) (recur name-map name value)) values)]

        [(bdlat:element name type _ _)
         ; Element names are mapped from a key that is a (list class element).
         (hash-set! name-map (list class-name name)
           (~> name bdlat-name->attribute-name string->symbol))]

        [(bdlat:enumeration-value name _ _)
         ; Enumeration value names are mapping from a key that is a
         ; (list class value).
         (hash-set! name-map (list class-name name)
           (~> name bdlat-name->enumeration-value-name string->symbol))])
         
    ; Return the hash map, which has been (maybe) modified in place.
    name-map))

(define (bdlat->name-map types)
  ; Return a hash table mapping bdlat type, element, and enumeration value
  ; names to the corresponding python class name symbols and attribute name
  ; symbols. Each key is either a string indicating a type name or a pair of
  ; string indicating a type.attribute name, where the first in the pair is
  ; the class name and the second in the pair is the attribute name. The
  ; mapped value is always a single symbol, e.g.
  ;
  ;  "FooThing" -> 'FooThing
  ;  ("FooThing" . "highWaterMark") -> 'high_water_mark
  (let ([name-map (make-hash)])
    (for-each (lambda (type) (extend-name-map name-map type)) types)
    name-map))

(define *default-types-module-description*
  "Provide typed attribute classes.")

(define *default-types-module-docs*
  `("This module provides typed attribute classes generated from a schema."
    ,(string-join '("Instances of the types defined in this module are "
                    "immutable, and may be converted to and from "
                    "JSON-compatible objects using the similarly-named "
                    "utilities module that is dual to this module.")
       "")))

(define (capitalize str)
  (match (string->list str)
    [(cons first-letter the-rest) 
     (list->string (cons (char-upcase first-letter) the-rest))]
    [_
     str]))

(define (bdlat->default default py-type)
  (if (equal? default '#:omit)
    ; No default was specified. Apply type-specific policies.
    (match py-type
      [(list 'List _)     '|[]|]  ; lists always default to empty
      [(list 'Optional _) 'None]  ; optionals always default to None
      [_                  default])
    ; A default was specified. Unless it's actually a string type, convert
    ; it into a symbol. Also, handle booleans properly (python capitalizes
    ; its boolean literals).
    (match py-type
      ['str                   default] ; keep as a string
      [(list 'Optional 'str)  default] ; keep as a string
      ['bool                  (~> default capitalize string->symbol)]
      [(list 'Optional 'bool) (~> default capitalize string->symbol)]
      [_                      (string->symbol default)])))

(define (bdlat->built-in type)
  ; Note that bdlat->imports also contains information about which bdlat basic
  ; types map to python types, so if either procedure is modified, the other
  ; might need to be updated as well.
  (case type
    [("string" "token" "normalizedString") 'str]
    [("int" "byte" "integer" "long" "negativeInteger" "nonNegativeInteger"
      "nonPositiveInteger" "positiveInteger" "short" "unsignedLong"
      "unsignedInt" "unsignedShort" "unsignedByte") 'int]
    [("decimal" "float" "double") 'float]
    [("boolean") 'bool]
    [("base64Binary" "hexBinary") 'bytes]
    [("date") 'date]
    [("time") 'time]
    [("dateTime") 'datetime]
    [("duration") 'timedelta]))

(define (bdlat->type-name type name-map)
  (match type
    ; Lookup the type name, but output a string instead of a symbol, so that
    ; when the python code is rendered, it's a "forward reference."
    [(? string? name) 
     (~>> name (hash-ref name-map) symbol->string)]

    ; A nullable type maps to ('Optional ...) where the "..." is determined by
    ; recursion.
    [(bdlat:nullable name)
     `(Optional ,(bdlat->type-name name name-map))]

    ; An array type is handled simlarly to a nullable, but using 'List instead
    ; of 'Optional.
    [(bdlat:array name)
     `(List ,(bdlat->type-name name name-map))]

    ; Basic types get mapped to python built-ins.
    [(bdlat:basic name) (bdlat->built-in name)]))

(define (element->annotation element parent-name name-map)
  ; parent-name is the bdlat name of the class that contains element.
  (match element
    [(bdlat:element name type docs default)
     (let ([py-type (bdlat->type-name type name-map)])
        (python-annotation
          (hash-ref name-map (list parent-name name)) ; attribute (name)
          py-type
          docs
          (bdlat->default default py-type)))]))       ; default value

(define (enumeration-value->assignment value parent-name name-map)
  ; parent-name is the bdlat name of the class that contains the enum value.
  (match value
    [(bdlat:enumeration-value name docs id)
     ; - name needs to be looked up in name-map
     ; - id is an integral constant
     (python-assignment
       (hash-ref name-map (list parent-name name)) ; left hand side
       id                                          ; right hand side
       docs)]))                                      

(define (python-class-by-category 
           base-class         ; e.g. 'NamedTuple
           bdlat-name         ; e.g. "MyType"
           name-map           ; populated earlier
           type-docs          ; list of paragraphs
           member-transformer ; procedure that maps a member to a statement
           members)           ; list of bdlat:element or list
                              ; of bdlat:enumeration-value
  ; Return a python-class modeling a bdlat sequence, a bdlat choice, or a
  ; bdlat enumeration, depending on the specified base-class and the specified
  ; statement-transformer.
  (python-class 
    (hash-ref name-map bdlat-name) ; class name
    (list base-class)              ; base classes (there's only one)
    type-docs
    (map (lambda (elem) (member-transformer elem bdlat-name name-map))
         members)))                ; statements

(define (bdlat->class type name-map)
  ; Return a python-class translated from the specified bdlat type. Use the
  ; specified hash table to map bdlat identifiers into python identifiers.
  (match type
    [(bdlat:sequence name docs elements)
     (python-class-by-category
       'NamedTuple name name-map docs element->annotation elements)]

    [(bdlat:choice name docs elements)
     (python-class-by-category
       'NamedUnion name name-map docs element->annotation elements)]

    [(bdlat:enumeration name docs values)
     (python-class-by-category
       'Enum name name-map docs enumeration-value->assignment values)]))

(define (bdlat->types-module types name-map description docs)
  (python-module
    description
    docs
    (bdlat->imports types)
    (map (lambda (type) (bdlat->class type name-map)) types)))

(define (util-module types-module-name name-map)
  (TODO))

(define (bdlat->python-modules types 
                               types-module-name
                               [description *default-types-module-description*]
                               [docs *default-types-module-docs*])
  (TODO))

(define (csv list-of-symbols indent-level indent-spaces)
  ; Return "foo, bar, baz" given '(foo bar baz). This operation is performed
  ; a few times within render-python.
  (~> list-of-symbols
      (map (lambda (form) (render-python form indent-level indent-spaces)) _)
      (string-join _ ", ")))

(define (render-python form [indent-level 0] [indent-spaces 4])
  (let ([IND   (make-string (* indent-level indent-spaces) #\space)] ; indent
        [TRIPQ "\"\"\""]) ; triple quote
    (match form
      [(python-module description docs imports statements)
       ; """This is the description.
       ;
       ; documentation...
       ; """
       ;
       ; ... imports ...
       ;
       ; ... statements ...
       (~a "\n" IND TRIPQ description
         (string-join docs (~a "\n\n" IND) #:before-first "\n\n") 
         "\n" IND TRIPQ "\n\n\n"
         ; imports
         (string-join (map (lambda (imp)
                             (render-python imp indent-level indent-spaces))
                        imports)
           "")
         "\n\n"
         ; statements (classes, functions, globals, etc.)
         (string-join (map (lambda (stm)
                             (render-python stm indent-level indent-spaces)) 
                        statements)
           "\n"))]

      [(python-import from-module names)
       ; can be one of
       ;     import something
       ; or
       ;     from something import thing
       ; or
       ;     from something import thing1, thing2, thing3
       (cond 
         [(null? names)
           (~a IND "import " from-module "\n")]
         [(not (list? names))
           (~a IND "from " from-module " import " names "\n")]
         [else
           (string-join (map (lambda (name) 
                                (~a IND "from " from-module " import " name)) 
                            names) 
             "\n")])]
      
      [(python-class name bases docs statements)
       ; class Name(Base1, Base2):
       ;     """documentation blah blah
       ;     """
       ;     ...
       (~a IND "class " name
         (let ([bases-text (csv bases indent-level indent-spaces)])
           (if (= (string-length bases-text) 0) 
             ""
             (~a "(" bases-text ")")))
         ":\n"
         ; documentation
         (if (empty? docs) 
           ""
           (let ([tab (make-string indent-spaces #\space)])
             (~a IND tab TRIPQ (string-join docs (~a "\n\n" IND tab)) 
               "\n" IND tab TRIPQ "\n")))
         ; statements
         (string-join 
           (map (lambda (stm) 
                  (render-python stm (+ indent-level 1) indent-spaces))
                statements)
           "")
         "\n")]

      ; TODO: Consider unifying annotations and assignments.
      [(python-annotation attribute type docs default)
       ; # docs...
       ; attribute : type = default
       (~a 
         ; the docs
         (if (empty? docs)
           ""
           (let ([margin (~a IND "# ")])
             (~a (string-join 
                   (map (lambda (doc) (~a margin doc)) docs)
                   (~a "\n" margin "\n"))
                "\n")))
         ; the attribute name
         IND attribute
         ; the type name
         (if (equal? type '#:omit)
           ""
           (~a " : " 
             (if (list? type)
               ; If type is a list, then it's something like Optional["Foo"]
               ; or Union[str, int] (though the latter won't happen). Note the
               ; use of ~s in the map, instead of ~a, so that types that are
               ; spelled as strings (like the names of user-defined types) are
               ; rendered quoted. This way, those identifiers don't have to be
               ; defined already in the python module (it's a forward type
               ; reference).
               (~a (first type) "["
                 (string-join (map ~s (rest type)) ", ") 
                 "]")
               ; If type is not a list, then just print it.
               (~a type))))
         ; the default (assigned) value
         (if (equal? default '#:omit)
           ""
           (~a " = " (render-python default indent-level indent-spaces)))
         "\n")]

      [(python-assignment lhs rhs docs)
       (render-python
         ; An assignment is an annotation whose type is omitted.
         (python-annotation lhs '#:omit docs rhs)
         indent-level
         indent-spaces)]

      [(python-def name args body)
       ; def name(arg1, arg2):
       ;     body...
       (~a IND "def " name "(" (csv args indent-level indent-spaces) "):\n"
         (string-join 
           (map (lambda (statement) 
                  (render-python 
                    statement (+ indent-level 1) indent-spaces))
             body)
           "")
         "\n")]

      [(python-invoke name args)
       (~a name "(" (csv args indent-level indent-spaces) ")")]

      [(python-dict items)
       ; {key1: value1, ...}
       (~a "{"
         (string-join
           ; map each (key . value) pair to "key: value"
           (map 
             (match-lambda [(cons key value)
               (~a (render-python key indent-level indent-spaces)
                 ": "
                 (render-python value indent-level indent-spaces))])
             items)
           ", ")
          "}")]

      [(? symbol? value)
       ; Symbols are here notable in that they're printed with ~a, not ~s.
       ; I want the spelling of the symbol to be literal in the python
       ; source code, as opposed to escaped as a symbol, e.g. [] not |[]|.
       (~a value)]

      [(? string? value)
       ; ~s so that it's printed quoted and escaped.
       (~s value)]

      [(? number? value)
       (~a value)])))
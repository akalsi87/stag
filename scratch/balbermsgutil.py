"""Provide codecs for types defined in balbermsg.

"""
import balbermsg
import gencodeutil
import typing


def to_json(obj: typing.Any) -> typing.Any:
    return gencodeutil.to_json(obj, _name_mappings)


def from_json(return_type: typing.Any, obj: typing.Any) -> typing.Any:
    return gencodeutil.from_json(return_type, obj, _name_mappings)


_name_mappings = {
    balbermsg.BerEncoderOptions:
    gencodeutil.NameMapping({
        "trace_level":
        "TraceLevel",
        "bde_version_conformance":
        "BdeVersionConformance",
        "datetime_fractional_second_precision":
        "DatetimeFractionalSecondPrecision",
        "encode_empty_arrays":
        "EncodeEmptyArrays",
        "thing":
        "thing",
        "color":
        "color",
        "encode_date_and_time_types_as_binary":
        "EncodeDateAndTimeTypesAsBinary"
    }),
    balbermsg.Color:
    gencodeutil.NameMapping({
        "BLUE": "BLUE",
        "GREEN": "GREEN",
        "RED": "RED",
        "CRAZY_WACKY_COLOR": "crazy-WACKYColor"
    }),
    balbermsg.BerDecoderOptions:
    gencodeutil.NameMapping({
        "max_depth": "MaxDepth",
        "trace_level": "TraceLevel",
        "skip_unknown_elements": "SkipUnknownElements",
        "max_sequence_size": "MaxSequenceSize"
    }),
    balbermsg.SomeChoice:
    gencodeutil.NameMapping({
        "bar": "bar",
        "foo": "foo"
    })
}

# This is the version string identifying the version of stag that generated
# this code. Search through the code generator's git repository history for
# this string to find the commit of the contemporary code generator.
_code_generator_version = "The tiny sunken funny constable overrides the tiny agnostic discounted lanyard while the gravel smothers the rotund fantastic white rum."

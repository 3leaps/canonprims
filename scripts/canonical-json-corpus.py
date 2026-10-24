#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Author the canonical-json/v0 conformance corpus.

Every expected output below is written by hand or taken from RFC 8785. None
is produced by a canonprims implementation. `scripts/corpus-witness.sh`
checks the accept cases against two independent witnesses (ECMAScript
JSON.stringify under node, and the crucible Python checker).

Usage:
  canonical-json-corpus.py          write the corpus tree
  canonical-json-corpus.py --check  exit 1 if the tree differs from this table
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "conformance" / "canonical-json" / "v0"
CORPUS = "canonical-json/v0"
SCHEME = "jcs/rfc8785"

OK = "ok"

# (id, input bytes, expected outcome, expected output bytes or None, limits or None, note)
CASES: list[tuple[str, bytes, str, bytes | None, dict | None, str]] = []


def ok(case_id: str, raw: bytes | str, out: bytes | str, note: str, limits: dict | None = None) -> None:
    CASES.append((case_id, _b(raw), OK, _b(out), limits, note))


def refuse(case_id: str, raw: bytes | str, code: str, note: str, limits: dict | None = None) -> None:
    CASES.append((case_id, _b(raw), code, None, limits, note))


def _b(value: bytes | str) -> bytes:
    return value if isinstance(value, bytes) else value.encode("utf-8")


# Generated inputs: prefix + unit * count + suffix, too large to commit.
GENERATED: list[dict] = []


def generated(case_id: str, prefix: str, unit: str, count: int, suffix: str, expect: str, note: str,
              same_output: bool = False, limits: dict | None = None) -> None:
    GENERATED.append({
        "id": case_id,
        "generate": {"prefix": prefix, "unit": unit, "count": count, "suffix": suffix},
        "expect": expect,
        "same_output": same_output,
        "limits": limits,
        "note": note,
    })


# --- RFC 8785 examples -------------------------------------------------------

ok("rfc8785-3.2.2-example",
   b'{\n  "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],\n'
   b'  "string": "\\u20ac$\\u000F\\u000aA\'\\u0042\\u0022\\u005c\\\\\\"\\/",\n'
   b'  "literals": [null, true, false]\n}',
   '{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],'
   '"string":"\u20ac$\\u000f\\nA\'B\\"\\\\\\\\\\"/"}',
   "RFC 8785 section 3.2.2 input and output")

ok("rfc8785-3.2.3-sorting",
   b'{\n  "\\u20ac": "Euro Sign",\n  "\\r": "Carriage Return",\n'
   b'  "\\ufb33": "Hebrew Letter Dalet With Dagesh",\n  "1": "One",\n'
   b'  "\\ud83d\\ude00": "Emoji: Grinning Face",\n  "\\u0080": "Control",\n'
   b'  "\\u00f6": "Latin Small Letter O With Diaeresis"\n}',
   '{"\\r":"Carriage Return","1":"One","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis",'
   '"\u20ac":"Euro Sign","\U0001f600":"Emoji: Grinning Face","\ufb33":"Hebrew Letter Dalet With Dagesh"}',
   "RFC 8785 section 3.2.3 sorting example")

ok("rfc8785-appendix-b-numbers",
   "[0, -0, 5e-324, -5e-324, 1.7976931348623157e308, -1.7976931348623157e308, "
   "9007199254740992, -9007199254740992, 2.9514790517935283e20, 9.999999999999997e22, 1e23, "
   "1.0000000000000001e23, 9.999999999999997e20, 9.999999999999999e20, 1e21, "
   "9.999999999999997e-7, 0.000001, 333333333.3333332, 333333333.33333325, 333333333.3333333, "
   "333333333.3333334, 333333333.33333343, -0.0000033333333333333333, 1424953923781206.2]",
   "[0,0,5e-324,-5e-324,1.7976931348623157e+308,-1.7976931348623157e+308,"
   "9007199254740992,-9007199254740992,295147905179352830000,9.999999999999997e+22,1e+23,"
   "1.0000000000000001e+23,999999999999999700000,999999999999999900000,1e+21,"
   "9.999999999999997e-7,0.000001,333333333.3333332,333333333.33333325,333333333.3333333,"
   "333333333.3333334,333333333.33333343,-0.0000033333333333333333,1424953923781206.2]",
   "RFC 8785 Appendix B values, written with exponents where the RFC's decimal is not the exact value")

# --- Structure and whitespace ------------------------------------------------

ok("ws-object", b'{\n  "y": 2,\n  "x": 1\n}\n', '{"x":1,"y":2}', "whitespace removed, members sorted")
ok("ws-all-kinds", b' \t\r\n[ 1 ,\t2\r\n]\r\n \t', "[1,2]", "all four JSON whitespace bytes, inside and around")
ok("empty-object", "{}", "{}", "empty object")
ok("empty-array", "[]", "[]", "empty array")
ok("empty-containers-ws", "{ \n } ", "{}", "whitespace inside an empty object")
ok("empty-array-ws", "[\t]", "[]", "whitespace inside an empty array")
ok("top-null", "null", "null", "top-level literal")
ok("top-true", " true ", "true", "top-level literal with whitespace")
ok("top-false", "false", "false", "top-level literal")
ok("top-string", '"a"', '"a"', "top-level string")
ok("top-zero", "0", "0", "top-level number")
ok("nested-sort", '{"b":[{"d":1,"c":2}],"a":{"z":null,"y":[true,false]}}',
   '{"a":{"y":[true,false],"z":null},"b":[{"c":2,"d":1}]}', "every object level is sorted")
ok("array-order", "[3,1,2]", "[3,1,2]", "arrays keep their order")
ok("same-name-different-objects", '[{"a":1},{"a":2},{"a":{"a":3}}]', '[{"a":1},{"a":2},{"a":{"a":3}}]',
   "a name may repeat across objects")

refuse("empty-input", "", "invalid_json", "no JSON text")
refuse("whitespace-only", " \n\t", "invalid_json", "no JSON text")
refuse("trailing-value", "{} {}", "invalid_json", "two top-level values")
refuse("trailing-garbage", "[1]x", "invalid_json", "content after the value")
refuse("trailing-number", "1 2", "invalid_json", "two numbers")
refuse("trailing-comma-array", "[1,]", "invalid_json", "trailing comma")
refuse("trailing-comma-object", '{"a":1,}', "invalid_json", "trailing comma")
refuse("leading-comma", "[,1]", "invalid_json", "leading comma")
refuse("missing-colon", '{"a" 1}', "invalid_json", "missing colon")
refuse("non-string-name", "{1:2}", "invalid_json", "member name must be a string")
refuse("single-quotes", "['a']", "invalid_json", "single-quoted string")
refuse("comment", "[1/*x*/]", "invalid_json", "comments are not JSON")
refuse("literal-case", "True", "invalid_json", "literals are lowercase")
refuse("literal-short", "nul", "invalid_json", "truncated literal")
refuse("literal-long", "nulll", "invalid_json", "content after a literal")
refuse("unclosed-array", "[1,2", "invalid_json", "end of input inside an array")
refuse("unclosed-object", '{"a":1', "invalid_json", "end of input inside an object")
refuse("missing-value", '{"a":}', "invalid_json", "member with no value")
refuse("form-feed-whitespace", b"[1,\x0c2]", "invalid_json", "U+000C is not JSON whitespace")
refuse("nbsp-whitespace", b"[1,\xc2\xa02]", "invalid_json", "U+00A0 is not JSON whitespace")
refuse("bom", b"\xef\xbb\xbf{}", "invalid_json", "a byte-order mark is refused")

# --- Numbers -----------------------------------------------------------------

ok("num-spellings", "[4.50, 50.0, 1.0e0, 0.0, -0.0, 0e5, -0e-5, 1e2, 1E2, 1e+2, 1E-2, 100e-2, 0.1e1]",
   "[4.5,50,1,0,0,0,0,100,100,100,0.01,1,1]", "equivalent spellings collapse")
ok("num-thresholds", "[1e20, 1e21, 1.2345678901234568e20, 1e-6, 1e-7, 0.0000001, 0.000001, 1.5e-7, 12e20]",
   "[100000000000000000000,1e+21,123456789012345680000,0.000001,1e-7,1e-7,0.000001,1.5e-7,1.2e+21]",
   "the 1e21 and 1e-6 notation thresholds")
ok("num-subnormal-underflow",
   "[5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 4.9406564584124654e-324, 1e-400, -1e-400, "
   "2.4703282292062328e-324, 2.4703282292062327e-324]",
   "[5e-324,2.2250738585072014e-308,2.225073858507201e-308,5e-324,0,0,5e-324,0]",
   "subnormals, underflow to zero, and the round-half-even boundary at the smallest subnormal")
ok("num-max", "[1.7976931348623157e308, 1.7976931348623158e308]",
   "[1.7976931348623157e+308,1.7976931348623157e+308]", "largest finite binary64 and a spelling that rounds to it")
ok("num-precision-loss",
   "[0.1000000000000000055511151231257827021181583404541015625, 3.141592653589793238462643383279, "
   "9007199254740993.0, 9007199254740995.0, -1e-7]",
   "[0.1,3.141592653589793,9007199254740992,9007199254740996,-1e-7]",
   "fraction tokens round to nearest, ties to even; not a refusal")
ok("int-negative-zero", "-0", "0", "negative zero integer token")
ok("int-small", "[0,-1,123]", "[0,-1,123]", "small integers")
ok("int-2p53", "9007199254740992", "9007199254740992", "2^53 is exact")
ok("int-neg-2p53-plus-2", "-9007199254740994", "-9007199254740994", "an even integer above 2^53 is exact")
ok("int-2p64", "18446744073709551616", "18446744073709552000", "2^64 is exact; printed per ECMAScript")
ok("int-2p68", "295147905179352825856", "295147905179352830000", "2^68 written exactly")
ok("int-2p128", "340282366920938463463374607431768211456", "3.402823669209385e+38", "2^128 is exact")
TWO_1000 = str(2 ** 1000)
ok("int-2p1000", TWO_1000, "1.0715086071862673e+301", "2^1000 is exact: no integer width ceiling")
F64_MAX_INT = str(int(sys.float_info.max))
ok("int-f64-max", F64_MAX_INT, "1.7976931348623157e+308", "the largest finite binary64 written as an integer")

refuse("int-2p53-plus-1", "9007199254740993", "integer_outside_binary64", "2^53+1 is not a binary64 value")
refuse("int-u64-max", "18446744073709551615", "integer_outside_binary64", "2^64-1 is not a binary64 value")
refuse("int-i128-max", "170141183460469231731687303715884105727", "integer_outside_binary64",
       "2^127-1 is not a binary64 value; a saturating cast would wrongly admit it")
ok("int-2p68-es6-spelling", "295147905179352830000", "295147905179352830000",
   "the ES6 spelling of 2^68 is admitted although it is not the exact value")
ok("int-2p64-es6-spelling", "18446744073709552000", "18446744073709552000",
   "canonical output for 2^64 is admissible input: canonicalization is idempotent")
ok("int-neg-2p64-es6-spelling", "-18446744073709552000", "-18446744073709552000", "negative ES6 spelling")
ok("int-i64-min-es6-spelling", "-9223372036854776000", "-9223372036854776000", "ES6 spelling of -2^63")
refuse("int-2p64-es6-plus-1", "18446744073709552001", "integer_outside_binary64",
       "neither exact nor the ES6 spelling")
refuse("int-2p68-es6-plus-1", "295147905179352830001", "integer_outside_binary64",
       "neither exact nor the ES6 spelling")
refuse("int-2p64-es6-padded", "18446744073709552000000", "integer_outside_binary64",
       "not exact, and ES6 writes 1.8446744073709552e+22")
ok("int-9p0072e18-es6-spelling", "9007199254740994000", "9007199254740994000",
   "not exact, but byte-identical to the ES6 spelling of its nearest binary64")
refuse("int-es6-off-by-one-digit", "9007199254740994001", "integer_outside_binary64",
       "one digit away from an ES6 spelling")
refuse("int-2p1000-plus-digit", TWO_1000 + "1", "integer_outside_binary64", "near 2^1000 but not exact")
refuse("int-f64-max-plus-1", str(int(sys.float_info.max) + 1), "integer_outside_binary64",
       "one more than the largest finite binary64")
refuse("int-400-nines", "9" * 400, "integer_outside_binary64", "beyond binary64 range: an integer token, not non-finite")
refuse("int-in-array", "[1,9007199254740993]", "integer_outside_binary64", "inside a container")
refuse("num-overflow", "1.7976931348623159e308", "non_finite_number", "rounds to infinity")
refuse("num-1e400", "1e400", "non_finite_number", "exponent overflow")
refuse("num-neg-1e400", "-1e400", "non_finite_number", "negative exponent overflow")
refuse("num-fraction-overflow", "0.1e310", "non_finite_number", "fraction with exponent overflow")
for slug, raw in [("leading-zero", "01"), ("neg-leading-zero", "-01"), ("bare-minus", "-"), ("dot-end", "1."),
                  ("exp-end", "1e"), ("exp-sign-end", "1e+"), ("dot-exp", "1.e5"), ("leading-dot", ".5"),
                  ("plus", "+1"), ("hex", "0x10"), ("exp-frac", "1.5e"), ("nan", "NaN"),
                  ("infinity", "Infinity"), ("neg-infinity", "-Infinity")]:
    refuse(f"num-grammar-{slug}", raw, "invalid_json", f"number grammar: {raw}")

# --- Strings -----------------------------------------------------------------

ok("str-short-escapes", b'"\\"\\\\\\/\\b\\f\\n\\r\\t"', b'"\\"\\\\/\\b\\f\\n\\r\\t"',
   "two-character escapes; \\/ becomes /")
CONTROLS_IN = '"' + "".join(f"\\u{c:04x}" for c in range(0x20)) + '"'
CONTROLS_OUT = ('"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f'
                '\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c'
                '\\u001d\\u001e\\u001f"')
ok("str-all-controls", CONTROLS_IN, CONTROLS_OUT, "every control character, lowercase hex")
ok("str-controls-upper-hex", '"\\u001F\\u000B"', '"\\u001f\\u000b"', "uppercase hex input, lowercase output")
ok("str-del-and-separators", '"\\u007f\\u2028\\u2029"', '"\u007f\u2028\u2029"',
   "U+007F, U+2028 and U+2029 are emitted as themselves")
ok("str-latin", '"\\u00e9\\u00E9\u00e9"', '"\u00e9\u00e9\u00e9"', "escaped and raw forms are equal")
ok("str-surrogate-pair", '"\\ud83d\\ude00\\uD83D\\uDE00"', '"\U0001f600\U0001f600"', "escaped surrogate pair")
ok("str-raw-astral", '"\U0001f600\U00010000\U0010fffd"', '"\U0001f600\U00010000\U0010fffd"', "raw UTF-8 outside the BMP")
refuse("nonchar-escaped-ffff", '"\\uffff"', "noncharacter", "U+FFFF escaped")
refuse("nonchar-escaped-fffe", '"\\uFFFE"', "noncharacter", "U+FFFE escaped, uppercase hex")
refuse("nonchar-escaped-fdd0", '"\\ufdd0"', "noncharacter", "first of the U+FDD0 block")
refuse("nonchar-escaped-fdef", '"\\ufdef"', "noncharacter", "last of the U+FDD0 block")
refuse("nonchar-raw-ffff", '"\uffff"', "noncharacter", "U+FFFF as raw UTF-8")
refuse("nonchar-raw-fdd5", '"a\ufdd5b"', "noncharacter", "raw, mid-string")
refuse("nonchar-pair-1fffe", '"\\ud83f\\udffe"', "noncharacter", "U+1FFFE as an escaped surrogate pair")
refuse("nonchar-raw-10ffff", '"\U0010ffff"', "noncharacter", "U+10FFFF, the last code point, as raw UTF-8")
refuse("nonchar-pair-10ffff", '"\\udbff\\udfff"', "noncharacter", "U+10FFFF as an escaped surrogate pair")
refuse("nonchar-in-name", '{"\\ufdd0":1}', "noncharacter", "member names are strings too")
refuse("nonchar-before-dup", '{"a":1,"a\\uffff":2,"a":3}', "noncharacter", "first defect reached wins")
refuse("dup-before-nonchar", '{"a":1,"a":2,"\\uffff":3}', "duplicate_member", "first defect reached wins")
refuse("lone-before-nonchar", '"\\ud800\\uffff"', "lone_surrogate", "a high surrogate followed by a non-low escape")
ok("nonchar-neighbours", '"\\ufdcf\\ufdf0\\ufffd\\ud83f\\udffd\\ud800\\udc00"',
   '"\ufdcf\ufdf0\ufffd\U0001fffd\U00010000"', "the code points next to noncharacters are fine")
ok("str-nul-mid", '"a\\u0000b"', '"a\\u0000b"', "NUL inside a string")
ok("str-empty", '""', '""', "empty string")
ok("str-raw-del", b'"\x7f"', b'"\x7f"', "raw DEL is not a control character in JSON")

refuse("str-raw-control", b'"a\x01"', "invalid_json", "raw control byte inside a string")
refuse("str-raw-tab", b'"a\tb"', "invalid_json", "raw tab inside a string")
refuse("str-raw-newline", b'"a\nb"', "invalid_json", "raw newline inside a string")
refuse("str-bad-escape", '"\\x"', "invalid_json", "unknown escape")
refuse("str-escape-apostrophe", "\"\\'\"", "invalid_json", "\\' is not a JSON escape")
refuse("str-short-unicode", '"\\u12"', "invalid_json", "fewer than four hex digits")
refuse("str-bad-hex", '"\\u12G4"', "invalid_json", "non-hex digit")
refuse("str-capital-u", '"\\U0041"', "invalid_json", "\\U is not an escape")
refuse("str-unterminated", '"abc', "invalid_json", "end of input inside a string")
refuse("str-unterminated-escape", '"abc\\', "invalid_json", "end of input after a backslash")

refuse("surrogate-lone-high", '"\\uD800"', "lone_surrogate", "high surrogate then quote")
refuse("surrogate-lone-low", '"\\uDC00"', "lone_surrogate", "low surrogate first")
refuse("surrogate-high-then-char", '"\\uD800x"', "lone_surrogate", "high surrogate then a character")
refuse("surrogate-high-then-other-escape", '"\\uD800\\n"', "lone_surrogate", "high surrogate then a non-\\u escape")
refuse("surrogate-high-high", '"\\uD800\\uD800"', "lone_surrogate", "two high surrogates")
refuse("surrogate-low-high", '"\\uDC00\\uD800"', "lone_surrogate", "reversed pair")
refuse("surrogate-high-bmp", '"\\uD800\\u0041"', "lone_surrogate", "high surrogate then a BMP escape")
refuse("surrogate-high-end-of-input", '"\\uD800', "lone_surrogate",
       "high surrogate then end of input: the missing \\u is a surrogate defect")
refuse("surrogate-high-bad-hex", '"\\uD800\\u12"', "invalid_json",
       "after \\u the hex digits must be valid before the pair is judged")
refuse("surrogate-in-name", '{"\\uDBFF":1}', "lone_surrogate", "lone surrogate in a member name")

refuse("utf8-overlong", b'"\xc0\xaf"', "invalid_utf8", "overlong encoding")
refuse("utf8-encoded-surrogate", b'"\xed\xa0\x80"', "invalid_utf8", "UTF-8 encoded surrogate")
refuse("utf8-above-max", b'"\xf4\x90\x80\x80"', "invalid_utf8", "above U+10FFFF")
refuse("utf8-truncated", b'"\xe2\x82"', "invalid_utf8", "truncated sequence")
refuse("utf8-stray-continuation", b'"\x80"', "invalid_utf8", "continuation byte with no lead")
refuse("utf8-ff", b"\xff", "invalid_utf8", "0xFF is never UTF-8")
refuse("utf8-lone-lead", b"\xc3", "invalid_utf8", "lead byte at end of input")
refuse("utf8-precedes-grammar", b"[1,]\xff", "invalid_utf8", "encoding is judged before grammar")
refuse("utf8-precedes-duplicate", b'{"a":1,"a":2,"\xff":3}', "invalid_utf8", "encoding is judged before duplicates")

# --- Objects -----------------------------------------------------------------

refuse("dup-simple", '{"a":1,"a":2}', "duplicate_member", "repeated name")
refuse("dup-after-unescape", '{"a":1,"\\u0061":2}', "duplicate_member", "names compare after unescaping")
refuse("dup-nested", '{"x":{"a":1,"a":2}}', "duplicate_member", "inside a nested object")
refuse("dup-same-value", '{"a":1,"a":1}', "duplicate_member", "even with an equal value")
refuse("dup-before-later-defect", '{"a":1,"a":2,"b":01}', "duplicate_member", "first defect reached wins")
refuse("defect-before-dup", '{"a":01,"a":2}', "invalid_json", "first defect reached wins")
ok("sort-utf16-not-codepoint", '{"\\ufffd":1,"\\ud800\\udc00":2}', '{"\U00010000":2,"\ufffd":1}',
   "U+10000 is D800 DC00 in UTF-16, so it sorts before U+FFFD")
ok("sort-astral-vs-private-use", '{"\U00010000":1,"\ue000":2}', '{"\U00010000":1,"\ue000":2}',
   "U+10000 sorts before U+E000")
ok("sort-prefix", '{"ab":1,"a":2,"":3}', '{"":3,"a":2,"ab":1}', "a prefix sorts first; empty name first of all")
ok("sort-case", '{"b":1,"B":2,"a":3,"A":4}', '{"A":4,"B":2,"a":3,"b":1}', "uppercase before lowercase")
ok("sort-by-decoded-name", '{"\\u0062":1,"a":2}', '{"a":2,"b":1}', "sorting uses the unescaped name")
ok("name-escaped-nul", '{"a\\u0000":1,"a":2}', '{"a":2,"a\\u0000":1}',
   "a member name containing NUL: escaped on output, and sorts after its prefix")
ok("sort-trailing-supplementary", '{"a\\ud83d\\ude01":1,"a\\ud83d\\ude00":2,"a\\ufffd":3}',
   '{"a\U0001f600":2,"a\U0001f601":1,"a\ufffd":3}',
   "names differ only in a trailing supplementary code point: the second UTF-16 unit decides")
ok("sort-digits", '{"10":1,"9":2,"1":3}', '{"1":3,"10":1,"9":2}', "names are strings, not numbers")

# --- Depth -------------------------------------------------------------------

generated("depth-128", "", "[", 128, "]" * 128, OK, "exactly the default depth limit", same_output=True)
generated("depth-129", "", "[", 129, "]" * 129, "too_deep", "one beyond the default depth limit")
generated("depth-mixed-128", "", '[{"a":', 64, "1" + "}]" * 64, OK, "arrays and objects both count", same_output=True)
generated("depth-mixed-130", "", '[{"a":', 65, "1" + "}]" * 65, "too_deep", "arrays and objects both count")
generated("depth-bomb", "", "[", 1_000_000, "", "too_deep", "a million unclosed brackets: refused without recursion")
generated("depth-before-later-defect", "", "[", 129, "x", "too_deep", "the depth defect is reached first")
refuse("defect-before-depth", "[[[[[x", "invalid_json", "a grammar defect at shallow depth")
refuse("depth-zero-container", "[]", "too_deep", "with max_depth 0 any container is refused", {"max_depth": 0})
ok("depth-zero-scalar", "1", "1", "with max_depth 0 a scalar is fine", {"max_depth": 0})
ok("depth-one", '{"a":1}', '{"a":1}', "outermost container is depth 1", {"max_depth": 1})
refuse("depth-one-nested", '{"a":[]}', "too_deep", "the second level exceeds max_depth 1", {"max_depth": 1})

# --- Limits ------------------------------------------------------------------

ok("limit-bytes-exact", "[12]", "[12]", "input exactly max_bytes long", {"max_bytes": 4})
refuse("limit-bytes-over", "[1,2]", "too_large", "input one byte over max_bytes", {"max_bytes": 4})
refuse("limit-bytes-before-utf8", b"\xff\xff\xff", "too_large", "size is judged before encoding", {"max_bytes": 2})
ok("limit-string-exact", '"abc"', '"abc"', "string exactly max_string_bytes", {"max_string_bytes": 3})
refuse("limit-string-over", '"abcd"', "too_large", "string over max_string_bytes", {"max_string_bytes": 3})
refuse("limit-string-decoded", '"\\u00e9\\u00e9"', "too_large", "measured in decoded UTF-8 bytes (4)",
       {"max_string_bytes": 3})
ok("limit-string-escaped-fits", '"\\u0041\\u0042\\u0043"', '"ABC"', "18 input bytes, 3 decoded bytes",
   {"max_string_bytes": 3})
refuse("limit-string-name", '{"abcd":1}', "too_large", "member names are strings too", {"max_string_bytes": 3})
ok("limit-members-exact", '{"a":1,"b":2}', '{"a":1,"b":2}', "exactly max_object_members", {"max_object_members": 2})
refuse("limit-members-over", '{"a":1,"b":2,"c":3}', "too_large", "one member over", {"max_object_members": 2})
refuse("limit-members-before-dup", '{"a":1,"b":2,"a":3}', "too_large", "the member count is judged before the name",
       {"max_object_members": 2})
refuse("limit-members-after-quote", '{"a":1,"b":2,}', "invalid_json", "the opening quote is judged before the count",
       {"max_object_members": 2})
ok("limit-members-zero-empty", "{}", "{}", "an empty object has no members", {"max_object_members": 0})
ok("limit-members-arrays", "[1,2,3]", "[1,2,3]", "arrays are not limited by max_object_members",
   {"max_object_members": 0})
generated("huge-string-over-default", '"', "a", 100 * 1024 * 1024, '"', "too_large",
          "a 100 MiB string exceeds the default max_bytes")
generated("large-string-within-default", '"', "\u00e9", 4 * 1024 * 1024, '"', OK,
          "an 8 MiB string within the defaults", same_output=True)


# --- Writer ------------------------------------------------------------------

def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    index = []
    seen: set[str] = set()
    for case_id, raw, expect, out, limits, note in CASES:
        assert case_id not in seen, case_id
        seen.add(case_id)
        entry: dict = {"id": case_id, "input": f"cases/{case_id}.in", "expect": expect}
        files[f"cases/{case_id}.in"] = raw
        if expect == OK:
            assert out is not None
            files[f"cases/{case_id}.out"] = out
            entry["output"] = f"cases/{case_id}.out"
            entry["digest"] = "sha256:" + sha256_hex(out)
        if limits:
            entry["limits"] = limits
        entry["note"] = note
        index.append(entry)
    for g in GENERATED:
        assert g["id"] not in seen, g["id"]
        seen.add(g["id"])
        gen = g["generate"]
        entry = {"id": g["id"], "generate": gen, "expect": g["expect"]}
        if g["expect"] == OK:
            assert g["same_output"]
            data = (gen["prefix"] + gen["unit"] * gen["count"] + gen["suffix"]).encode("utf-8")
            entry["output"] = "=input"
            entry["digest"] = "sha256:" + sha256_hex(data)
        if g["limits"]:
            entry["limits"] = g["limits"]
        entry["note"] = g["note"]
        index.append(entry)
    doc = {
        "corpus": CORPUS,
        "scheme": SCHEME,
        "default_limits": {
            "max_bytes": 16 * 1024 * 1024,
            "max_depth": 128,
            "max_object_members": 1024 * 1024,
            "max_string_bytes": 16 * 1024 * 1024,
        },
        "cases": index,
    }
    files["cases.json"] = (json.dumps(doc, indent=2, ensure_ascii=True) + "\n").encode("ascii")
    manifest = {
        "corpus": CORPUS,
        "scheme": SCHEME,
        "files": {name: "sha256:" + sha256_hex(data) for name, data in sorted(files.items())},
    }
    files["MANIFEST.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("ascii")
    return files


def main(argv: list[str]) -> int:
    check = argv[1:] == ["--check"]
    if argv[1:] and not check:
        sys.stderr.write(__doc__)
        return 2
    files = build()
    on_disk = {str(p.relative_to(ROOT)).replace("\\", "/") for p in ROOT.rglob("*") if p.is_file()} if ROOT.exists() else set()
    if check:
        bad = sorted(name for name, data in files.items()
                     if not (ROOT / name).is_file() or (ROOT / name).read_bytes() != data)
        extra = sorted(on_disk - set(files))
        for name in bad:
            sys.stderr.write(f"corpus: {name} differs from the authoring table\n")
        for name in extra:
            sys.stderr.write(f"corpus: {name} is not in the authoring table\n")
        if bad or extra:
            return 1
        digest = sha256_hex(files["MANIFEST.json"])
        sys.stdout.write(f"sha256:{digest}\n")
        return 0
    for name in on_disk - set(files):
        (ROOT / name).unlink()
    for name, data in files.items():
        path = ROOT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    sys.stdout.write(f"sha256:{sha256_hex(files['MANIFEST.json'])}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

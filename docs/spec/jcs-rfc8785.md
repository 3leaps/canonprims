# Scheme `jcs/rfc8785`

This page is normative for every canonprims implementation of the
`jcs/rfc8785` scheme. The conformance corpus
(`conformance/canonical-json/v0/`) is the executable form of it. Where the
corpus and this page disagree, that is a defect in one of them; neither wins
silently.

## Output

The output is the RFC 8785 JSON Canonicalization Scheme serialization of the
input, as UTF-8 bytes, with no byte-order mark and no trailing newline.

- **Whitespace**: none between tokens.
- **Literals**: `null`, `true`, `false`.
- **Strings**: as ECMAScript `JSON.stringify` (RFC 8785 §3.2.2.2).
  - `"` and `\` become `\"` and `\\`.
  - U+0008, U+0009, U+000A, U+000C and U+000D become `\b`, `\t`, `\n`, `\f`
    and `\r`.
  - Every other code point below U+0020 becomes `\u00xx`, with lowercase hex.
  - Every other code point, including U+007F, U+2028 and U+2029, is emitted
    as itself in UTF-8. (Noncharacters never reach the output: they are
    refused on input.)
  - `\/` in the input becomes `/`.
  - String data is never normalized: no NFC, no case folding.
- **Numbers**: the IEEE 754 binary64 value, serialized by ECMAScript
  `Number::toString` (RFC 8785 §3.2.2.3).
  - `-0` serializes as `0`.
  - Exponent form is used below `1e-6` and at or above `1e21`, as
    `1e+21` and `1e-7`.
- **Arrays**: elements keep their order.
- **Objects**: members are sorted by their names, compared as sequences of
  UTF-16 code units (RFC 8785 §3.2.3). The comparison is unsigned and runs
  unit by unit; a name that is a prefix of another sorts first.

## Input domain

Input is a byte sequence holding exactly one JSON text (RFC 8259) under
I-JSON constraints (RFC 7493). Nothing is repaired. Anything outside the
domain is a **refusal**, identified by one of the codes below. The code is
normative. A refusal may also carry a byte offset; the offset is informative,
for diagnostics only, and implementations may disagree on it.

| Code | Meaning |
| --- | --- |
| `too_large` | A size limit was exceeded: input bytes, one string's decoded bytes, or one object's member count |
| `invalid_utf8` | The input is not well-formed UTF-8 (Unicode Table 3-7). This covers overlong forms, encoded surrogates (`ED A0 80`–`ED BF BF`) and code points above U+10FFFF |
| `invalid_json` | Not a JSON text: grammar errors, a byte-order mark, raw control characters (U+0000–U+001F) inside a string, whitespace other than space/tab/LF/CR, trailing content, empty input |
| `lone_surrogate` | A `\uD800`–`\uDFFF` escape that is not part of a high-then-low escaped pair |
| `noncharacter` | A string (member name or value) contains a Unicode noncharacter, raw or escaped: U+FDD0–U+FDEF, or any code point ending in FFFE or FFFF (66 in all), as RFC 7493 §2.1 forbids |
| `duplicate_member` | An object member name repeats an earlier name in the same object, compared after unescaping |
| `non_finite_number` | A number token with a fraction or exponent whose value rounds to infinity |
| `integer_outside_binary64` | A number token with no fraction and no exponent whose exact value is not a binary64 value |
| `too_deep` | Arrays and objects nest deeper than the depth limit |

`check` adds one outcome: `not_canonical`. The input is in the domain, but
its bytes are not the canonical bytes.

## Numbers in detail

A number token is classified by its grammar, before its value is computed.

- **Integer token** (`-?(0|[1-9][0-9]*)`, no fraction, no exponent): admitted
  when either of these holds:
  - Its exact mathematical value is a binary64 value. There is no width
    ceiling: `9007199254740992` (2^53), `18446744073709551616` (2^64) and
    2^1000 written out in full are admitted.
  - The token is byte-identical to the ECMAScript `Number::toString` spelling
    of its nearest binary64, for example `18446744073709552000`. This keeps
    canonical output admissible as input: canonicalizing 2^64 yields that
    spelling, and `check` must accept it.

  Every other integer token is refused with `integer_outside_binary64`. That
  includes `9007199254740993`, `18446744073709551615`, and any token whose
  magnitude exceeds the largest finite binary64, even though it would round to
  infinity. In both admitted forms the output is the ES6 spelling of the
  admitted value.
- **Fraction or exponent token**: converted to the nearest binary64, with ties
  to even (a correctly rounded parse).
  - A value that rounds to infinity is refused with `non_finite_number`.
  - A value that underflows is admitted as the rounded result, possibly
    `0` or a subnormal.
  - Loss of precision is not a refusal: `9007199254740993.0` becomes
    `9007199254740992`.

This asymmetry is deliberate. RFC 8785 fixes how a binary64 value is
serialized; this scheme additionally fixes which integer tokens are
admitted. An integer token that is neither exact nor already canonical is
refused rather than rounded. Callers that need exact large quantities should
carry them as strings. A fraction or exponent
token already states a binary64 value under RFC 8785.

## Order of detection

Every input that is refused has exactly one correct code. The rules below fix
which code applies when a document contains more than one defect.

1. **Input size.** If the input is longer than `max_bytes`, the result is
   `too_large`.
2. **Encoding.** If the whole input is not well-formed UTF-8, the result is
   `invalid_utf8`, wherever the bad bytes are.
3. **Parse.** One left-to-right pass. The first defect reached wins. Within
   that pass:
   - **Whitespace.** Leading and trailing whitespace (space, tab, LF, CR) is
     skipped. A byte-order mark is `invalid_json` at offset 0. Content after
     the single top-level value is `invalid_json`.
   - **Containers.** Opening an array or object when it would make the depth
     exceed `max_depth` is `too_deep`. This happens at the opening bracket,
     before anything inside it is read. The outermost container is depth 1. A
     top-level scalar is depth 0. With `max_depth` 0, any container is
     refused.
   - **Object members.** Each member goes through these steps in order:
     1. The next byte must be `"`, or the result is `invalid_json`.
     2. If the object already holds `max_object_members` members, the result
        is `too_large`.
     3. The name string is parsed under the string rules below.
     4. If the name repeats an earlier name in this object, the result is
        `duplicate_member`.
     5. Whitespace, then `:`, or the result is `invalid_json`.
     6. The value is parsed.
     7. Then `,` or `}`, or the result is `invalid_json`.
   - **Strings.** Decoding is code point by code point.
     - A raw byte below 0x20 is `invalid_json`. So is an unknown escape, and a
       `\u` escape without four hex digits. Hex digits may be upper or lower
       case.
     - After an escaped high surrogate (`\uD800`–`\uDBFF`), the next two bytes
       must be exactly `\u`, or the result is `lone_surrogate`. This includes
       end of input. The four hex digits that follow must be valid, or the
       result is `invalid_json`. They must then name a low surrogate
       (`DC00`–`DFFF`), or the result is `lone_surrogate`.
     - An escaped low surrogate that does not follow a high one is
       `lone_surrogate`.
     - Each decoded code point that is a noncharacter is `noncharacter`,
       whether it came from raw UTF-8, a `\u` escape, or an escaped
       surrogate pair. The check happens when the code point is decoded,
       before it is appended.
     - After each decoded code point is appended, if the string's decoded
       UTF-8 length exceeds `max_string_bytes`, the result is `too_large`.
       This applies to member names and to values.
     - End of input before the closing `"` is `invalid_json`.
   - **Numbers.** The longest prefix matching the JSON number grammar is the
     token. If the grammar fails partway through the token (`-`, `01`, `1.`,
     `1e`, `1.e5`), the result is `invalid_json`. Otherwise the token is
     classified as in *Numbers in detail*.
   - **Literals.** `null`, `true` and `false` must match exactly, or the
     result is `invalid_json`.

## Limits

Every public entry point takes limits explicitly. The defaults are:

| Limit | Default | Measures |
| --- | --- | --- |
| `max_bytes` | 16 777 216 (16 MiB) | input length in bytes |
| `max_depth` | 128 | array/object nesting |
| `max_object_members` | 1 048 576 | members in any one object |
| `max_string_bytes` | 16 777 216 (16 MiB) | decoded UTF-8 bytes of any one string |

Implementations must not use the call stack for nesting, so a caller may
raise `max_depth` without risk of stack exhaustion. Work is linear in the
input when every object's members arrive in canonical order; an object
whose members arrive out of order re-sorts its own bytes when it closes.
Re-sorting copies those bytes once per enclosing out-of-order object, and
sorting n members costs O(n log n) name comparisons, each linear in the
shorter name. So the worst case is proportional to input size times object
nesting depth, plus the comparison cost of sorting each object.

Limits apply to the input only. Canonical output can be longer than its
input (`1e20` canonicalizes to 21 bytes), so canonical output is admissible
input under limits at least as large as its own size, not necessarily under
the limits that produced it.

A limit of 0 is valid, and means none of that thing is allowed: with
`max_object_members` 0, `{}` is still admitted, because no member is
started. In languages whose limit type is signed, a negative limit behaves
as 0. Exceeding a
limit is a refusal. It is never an unbounded allocation and never a panic.

## Digest

`digest` canonicalizes, then hashes the canonical bytes. The result is
`<alg>:<lowercase hex>`. The only algorithm in this version is `sha256`.
A refusal from canonicalization is returned unchanged.

## Scheme identity

| Field | Value |
| --- | --- |
| Scheme identifier | `jcs/rfc8785` |
| Specification | RFC 8785 |
| Corpus | `canonical-json/v0` |
| Corpus digest | `sha256:` of the corpus `MANIFEST.json` bytes |

An implementation reports the corpus digest it was gated against, so a
digest's provenance can state "canonical per `(scheme, corpus digest)`".

## Service interface

Each language exposes the same four verbs. Names follow that language's
conventions.

| Verb | Result |
| --- | --- |
| `canonicalize(scheme, input, limits)` | canonical bytes, or a refusal |
| `check(scheme, input, limits)` | success when `input` is byte-identical to its canonical form; otherwise the refusal, or `not_canonical` |
| `digest(scheme, input, limits, alg)` | `"sha256:<hex>"`, or a refusal |
| `scheme_info(scheme)` | name, specification, corpus name, corpus digest |

Two errors are about the call, not the input. An unknown scheme identifier
is `unknown_scheme`. An unknown digest algorithm is `unknown_algorithm`.
These are not refusal codes. Each language represents them as its own
error kind, and they never appear in the corpus.

## Conformance harness protocol

Every implementation provides a corpus test and a differential driver that
read and write the same bytes, so that two implementations can be compared
with `cmp`.

**Corpus result line.** For each case in `cases.json`, in file order, one
line of the form:

    <id> ok <sha256 hex of the canonical output>
    <id> <refusal code>

Under the environment variable `CANON_RESULTS_OUT=<path>`, the corpus test
writes these lines to `<path>`, LF-terminated, with no other content.

**Differential driver.** The driver reads stdin one LF-terminated line at a
time. Each line is the lowercase hex of one input; an empty line is the
empty input. For each line it writes exactly one line to stdout:

    ok <lowercase hex of the canonical bytes>
    <refusal code>

The driver always uses the default limits. It exits 0 when it reaches the end
of its input. A line that is not valid hex is a usage error: exit 2.

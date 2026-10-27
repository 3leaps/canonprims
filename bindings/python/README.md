# canonprims (Python)

RFC 8785 JSON canonicalization over a strict I-JSON loader: a binding over the
Rust `canonprims-json` crate, gated by the same `canonical-json/v0`
conformance corpus as the Rust and Go implementations.

```python
import canonprims

limits = canonprims.Limits()  # explicit on every call; documented defaults
canonprims.canonicalize(b'{"b":1,"a":2}', limits)  # b'{"a":2,"b":1}'
canonprims.digest(b'{"b":1,"a":2}', limits)        # 'sha256:...'
canonprims.check(b'{"a":2,"b":1}', limits)         # None, or raises Refusal
canonprims.scheme_info()
```

Input is bytes (any buffer); a `str` is encoded as UTF-8. An input with no
canonical form raises `canonprims.Refusal` (a `ValueError`) with a normative
`code` and an informative byte `offset`. Nothing is repaired.

Requires CPython 3.10 or later. See the repository README and
`docs/spec/jcs-rfc8785.md` for the scheme.

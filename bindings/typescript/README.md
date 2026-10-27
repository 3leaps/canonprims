# @3leaps/canonprims

RFC 8785 JSON canonicalization over a strict I-JSON loader: a binding over the
Rust `canonprims-json` crate, compiled to one WebAssembly module with no
imports, for Node.js (20+), Deno, Bun and browsers. It passes the same
`canonical-json/v0` conformance corpus as the Rust, Go and Python
implementations. No runtime dependencies.

```ts
import { canonicalize, check, digest, limits, schemeInfo } from "@3leaps/canonprims";

const l = limits(); // explicit on every call; documented defaults
canonicalize('{"b":1,"a":2}', l); // Uint8Array of {"a":2,"b":1}
digest('{"b":1,"a":2}', l);       // "sha256:..."
check('{"a":2,"b":1}', l);        // returns, or throws Refusal
schemeInfo();
```

Input is a `Uint8Array` or any `ArrayBufferView` (read as its bytes); a string
is encoded as UTF-8, and a string with an unpaired surrogate (no UTF-8 form) is
a `TypeError`. An input longer than `maxBytes` is refused before it is copied
into the module. An input with no canonical form throws `Refusal` with a
normative `code` and an informative byte `offset`. Nothing is repaired. Limits
follow the spec: a negative limit behaves as 0, and a limit above 2^32 - 1
behaves as that maximum.

See the repository README and `docs/spec/jcs-rfc8785.md` for the scheme.

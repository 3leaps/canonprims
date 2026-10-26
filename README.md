# canonprims

Canonical serialization for structured data (RFC 8785 and successors).

canonprims turns a structured document into one exact byte sequence, so that
two programs, in two languages, on two operating systems, hash it to the same
digest. Its first scheme is the RFC 8785 JSON Canonicalization Scheme
(`jcs/rfc8785`).

There are two implementations:

- **Rust** crates (`canonprims-core`, `canonprims-json`) and the `canon`
  command.
- **Go**, a pure-Go package (`github.com/3leaps/canonprims/canon`) in the
  root module, that uses only the standard library and needs no cgo.

Both must pass the same conformance corpus (`conformance/canonical-json/v0`)
and produce byte-identical results on generated input. CI fails if either
one disagrees.

The two share a parser architecture (an explicit container stack, members
written in place and re-sorted only when out of order), so their agreement
is weaker evidence against a shared parser-design error. The independent
evidence comes from elsewhere: number serialization is implemented
differently in each (ryu-based in Rust, `strconv` with an exact `math/big`
integer check in Go), and the corpus expectations are hand-derived, with the
file-based accept cases also checked against ECMAScript and a separate Python
checker (see Development).

### Packages

| Language | Package | Status |
| --- | --- | --- |
| Rust | `canonprims-core`, `canonprims-json` (crates.io) | shipped with v0.1.0 |
| Go | `github.com/3leaps/canonprims` (package `canon`) | shipped with v0.1.0 |
| TypeScript | `@3leaps/canonprims` (npm), from the Rust implementation | planned |
| Python | `canonprims` (PyPI), from the Rust implementation | planned |

There is no TypeScript or Python binding yet.

## Status

Pre-release (0.1.0 in development). The API may change before the first tag.

## Use

### Command line

```console
$ echo '{"b": 2, "a": [1.0, 1e21]}' | canon jcs
{"a":[1,1e+21],"b":2}
$ echo '{"b": 2, "a": 1}' | canon jcs --digest
sha256:...
$ canon jcs --check fixture.json    # exit 0 only if already canonical
$ canon info
{"corpus":"canonical-json/v0","corpus_digest":"sha256:...","scheme":"jcs/rfc8785","spec":"RFC 8785"}
$ canon version --extended
{"name":"canon","schemes":[{"corpus":"canonical-json/v0",...}],"version":"0.1.0"}
```

The command writes data to stdout and diagnostics to stderr. Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | The input was refused, or `--check` found it not canonical |
| 2 | Usage error |
| 4 | The input could not be read |
| 5 | The output could not be written |

### Rust

```rust
use canonprims_json::canonprims_core::{DigestAlg, Limits};

let limits = Limits::default();
let bytes = canonprims_json::canonicalize(br#"{"b":2,"a":1}"#, &limits)?;
assert_eq!(bytes, br#"{"a":1,"b":2}"#);
let digest = canonprims_json::digest(br#"{"b":2,"a":1}"#, &limits, DigestAlg::Sha256)?;
```

### Go

```go
import "github.com/3leaps/canonprims/canon"

out, err := canon.Canonicalize(canon.JCS, input, canon.DefaultLimits())
d, err := canon.Digest(canon.JCS, input, canon.DefaultLimits(), "sha256")
```

## What it refuses

Nothing is repaired. Input outside the RFC 8785 / I-JSON domain is refused
with a named code that is the same in both languages:

`invalid_json`, `invalid_utf8`, `duplicate_member`, `lone_surrogate`,
`noncharacter`, `non_finite_number`, `integer_outside_binary64`, `too_deep`,
`too_large`.

Every call takes explicit limits on input size, nesting depth, object
members and string length. When a limit is exceeded the call returns a
refusal. It never panics and never allocates without bound.

The precise rules, including which code applies when an input has several
defects, are in [docs/spec/jcs-rfc8785.md](docs/spec/jcs-rfc8785.md).

## What it does not do

- **No Unicode normalization.** Strings are canonicalized as given, and NFC
  is the caller's policy.
- **No YAML or other formats.** Convert to JSON first.
- **No schema validation.**

## Development

```console
make check        # everything CI runs: fmt, lint, tests, corpus, witnesses, crosscheck, deny
make crosscheck   # Rust and Go agreement only
make corpus       # regenerate the corpus from scripts/canonical-json-corpus.py
make doctor       # host tool versions against the recommended minimums
make pr-final     # before a PR: check plus the maintainer's public-surface scan
```

Requirements:

- Rust 1.88 or later.
- Go 1.21 or later for the module (CI uses Go 1.26).
- Python 3.
- Node.js and network access to GitHub, for the independent corpus witnesses.
- `cargo-deny`.

`.goneat/tools.yaml` declares a recommended minimum version for each host tool
the checks and the release ceremony run (git, gh, jq, Python, gpg, minisign,
Go), and `make doctor` reports each one against it (`DOCTOR_SCOPE=dev` for the
development set). It fails when a tool is missing, older, or prints a version
it cannot read; `config/doctor-versions.txt` says how each tool's version is
read. The minimums are the versions this repository is known to
work with, not proven lower bounds; older versions may work, YMMV. Two are
firm: jq 1.6 rejects a jq keyword used as a variable name, and the release
scripts refuse Python older than 3.11.

The corpus expectations are written by hand or taken from RFC 8785. They are
not produced by either implementation. `make witness` checks the expected
bytes of every file-based accept case against ECMAScript `JSON.stringify`
and against a separate Python checker pinned by commit and sha256
(`config/witness.sha256`). The Python checker cannot witness the five
accept cases for ES6-spelled integers, and says so. Neither witness enforces
the strict input domain, so refusal cases and generated cases rest on the
two implementations agreeing.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work, as defined in the Apache-2.0 license,
shall be dual licensed as above, without any additional terms or conditions.

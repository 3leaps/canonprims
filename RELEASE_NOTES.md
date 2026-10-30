# Release Notes

The latest three releases, newest first. The complete history is in
[CHANGELOG.md](CHANGELOG.md); the notes for each cut are in
[docs/releases/](docs/releases/).

---

## v0.1.3 - 2026-10-30

OIDC Trusted Publishing for PyPI and npm, published-release staging and live
registry digest verification, and release-script portability hardening. The
library, bindings, conformance corpus and `canon` command are unchanged from
0.1.2.

- `.github/workflows/registry-publish.yml`: environment-gated OIDC publication
  of the signed GitHub release wheels to PyPI (`canonprims`) and tarball to npm
  (`@3leaps/canonprims`), followed by live registry digest and PEP 740 /
  Sigstore provenance verification.
- `make release-github-preflight`, `make release-stage-published`,
  `make release-verify-registries`, `make release-stage`,
  `make release-crates-clean` and `make release-pack-npm-redirector`.
- OpenPGP signer command-line pinning and default `~/.gnupg` keyring refusal,
  Bash 3.2 empty-array expansion guard, Rust `canon-diff` hex-parsing parity
  and Windows-portable surface test controls.

Details: [docs/releases/v0.1.3.md](docs/releases/v0.1.3.md).

---

## v0.1.2 - 2026-10-28

Python and TypeScript bindings, gated by the same conformance corpus and in
byte-for-byte agreement with Rust.

- Python package `canonprims`: abi3 wheels for CPython 3.10 and later on
  linux amd64/arm64, darwin arm64 and windows amd64/arm64.
- npm package `@3leaps/canonprims`: one WebAssembly module, no runtime
  dependencies.
- Both are signed release assets; the registry packages are those files.

Details: [docs/releases/v0.1.2.md](docs/releases/v0.1.2.md).

---

## v0.1.1 - 2026-10-27

The first published release: the RFC 8785 JSON Canonicalization Scheme in Rust and in
pure Go, gated against one conformance corpus and in byte-for-byte agreement.

- Rust crates `canonprims-core` and `canonprims-json` on crates.io.
- Go module `github.com/3leaps/canonprims`, package `canon`, standard library
  only and cgo-free.
- The `canon` command for linux amd64/arm64, darwin arm64 and windows
  amd64/arm64.
- One signed tag, `v0.1.1`, for the crates and the Go module. (A `v0.1.0`
  tag exists but was never released.)

Details: [docs/releases/v0.1.1.md](docs/releases/v0.1.1.md).

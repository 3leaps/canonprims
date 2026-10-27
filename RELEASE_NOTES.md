# Release Notes

The latest three releases, newest first. The complete history is in
[CHANGELOG.md](CHANGELOG.md); the notes for each cut are in
[docs/releases/](docs/releases/).

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

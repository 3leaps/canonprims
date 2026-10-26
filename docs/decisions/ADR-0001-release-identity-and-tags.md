---
id: "ADR-0001"
title: "Release identity: one signed tag, committed public pins"
status: "accepted"
date: "2026-10-23"
revised: "2026-10-25"
---

# ADR-0001: Release Identity: One Signed Tag, Committed Public Pins

## Context

canonprims ships two independent implementations of one scheme from one
repository: Rust crates published to crates.io, and a pure-Go package in the
root Go module (`github.com/3leaps/canonprims`, package `canon`). Both are
versioned together and released from the same commit. Because the Go module is
at the repository root, Go resolves it from the plain `vX.Y.Z` tag; a module in
a subdirectory would need a second, path-prefixed tag.

The release process follows crucible PDR-0008: public pins are committed and
read from the tagged commit, one checker derives and verifies the fingerprint
anchors, and the checker and the release tag are explicit inputs with no
fallback.

## Decision

1. **One version, one tag.** A release `X.Y.Z` is the annotated tag
   `vX.Y.Z`, signed by the committed signing subkey and pointing at a commit
   of `main`. It releases the Rust crates and the Go module together. The tag
   set is fixed in the release scripts, not configuration, so nothing in a
   checkout can change it; verification requires exactly this one tag. A tree
   whose root `go.mod` is missing or declares another module path cannot be
   released, and verification refuses a tag that is missing, unsigned,
   lightweight, or points at another commit. The tag is created locally and
   then pushed.
2. **One GitHub release**, bound to `vX.Y.Z`. Its assets are the `canon` CLI
   archives for linux amd64/arm64, darwin arm64 and windows amd64/arm64, the
   source archive (`git archive` of the tagged commit, rebuilt and compared
   by the maintainer before the draft), an SBOM of the source tree and its locked dependencies, the licenses, the public pins and anchors, the release notes, and the
   signed checksum manifests.
3. **Crates published in dependency order** from
   `config/release/publishable-crates.txt` (`canonprims-core`, then
   `canonprims-json`). `canonprims-cli` is not published. Package
   verification is compiled in credential-free CI, each crate against
   the registry with its predecessors already published; the maintainer
   packages without compiling, reproduces the verified archive byte for byte,
   and the registry token is released only for that archive's checksum.
   Before the tag workflow or the pre-tag gate
   compiles anything, the source must be inert for Cargo: no toolchain
   selector, Cargo configuration, build script, procedural macro, symlink,
   escaping manifest path, or dependency from git, another registry, or a
   path outside the tree.
4. **Explicit inputs.** The release tag comes only from
   `CANONPRIMS_RELEASE_TAG`; a bare `RELEASE_TAG` is refused by `make`, and no
   step derives a tag from `VERSION`, `git describe` or the branch. The checker
   comes only from the absolute path in `CANONPRIMS_DECERNOR_BIN` (decernor
   0.1.8 or newer), with no `PATH` or unprefixed fallback.
5. **Read-only CI.** The tag workflow verifies the tag against the committed
   pin, validates the committed anchors with a digest-pinned checker, and
   builds artifacts. It holds no write, signing or registry authority. The
   maintainer creates the draft, signs the manifests and publishes locally.

## Consequences

- The Go module and the Rust crates always carry the same version, including
  for a release where only one of them changed.
- A Go consumer resolving `github.com/3leaps/canonprims@vX.Y.Z` gets the
  commit the Rust crates were published from.
- Adding a nested Go module, which would need its own tag, is a change to the
  tag set, this record, and the verification tests together.

## Revision (2026-10-25)

Before any release, the Go module moved from `go/canon` to the repository
root and the release went from two tags (`vX.Y.Z` and `go/canon/vX.Y.Z`) to
one. No release was made under the two-tag rule.

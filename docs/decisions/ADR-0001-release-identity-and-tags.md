---
id: "ADR-0001"
title: "Release identity: two signed tags at one commit, committed public pins"
status: "accepted"
date: "2026-10-23"
---

# ADR-0001: Release Identity: Two Signed Tags at One Commit, Committed Public Pins

## Context

canonprims ships two independent implementations of one scheme from one
repository: Rust crates published to crates.io, and a pure-Go module at
`go/canon` (`github.com/3leaps/canonprims/go/canon`). Go resolves a module in
a subdirectory only from a tag prefixed with that directory, so the Go module
needs its own tag. Both implementations are versioned together and released
from the same commit.

The release process follows crucible PDR-0008: public pins are committed and
read from the tagged commit, one checker derives and verifies the fingerprint
anchors, and the checker and the release tag are explicit inputs with no
fallback.

## Decision

1. **One version, two tags, one commit.** A release `X.Y.Z` is the annotated
   tags `vX.Y.Z` and `go/canon/vX.Y.Z`, both signed by the committed signing
   subkey and both pointing at the same commit of `main`. The tag set is
   fixed in the release scripts, not configuration, so nothing in a checkout
   can narrow it; verification requires exactly these two tags. A tree without
   `go/canon/go.mod` cannot be released, and verification refuses a release
   where either tag is missing, unsigned, lightweight, or points at another
   commit. Tags are created locally and pushed in one atomic push.
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
5. **Read-only CI.** The tag workflow verifies both tags against the committed
   pin, validates the committed anchors with a digest-pinned checker, and
   builds artifacts. It holds no write, signing or registry authority. The
   maintainer creates the draft, signs the manifests and publishes locally.

## Consequences

- The Go module and the Rust crates always carry the same version, including
  for a release where only one of them changed.
- A Go consumer resolving `go/canon@vX.Y.Z` gets the commit the Rust crates
  were published from.
- Adding another module with its own tag is a change to the tag set,
  this record, and the verification tests together.

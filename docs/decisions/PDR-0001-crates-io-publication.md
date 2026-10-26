---
id: "PDR-0001"
title: "crates.io publication: packages verified in CI, token released only for the verified package"
status: "accepted"
date: "2026-10-24"
relates-to:
  - "ADR-0001-release-identity-and-tags.md"
  - "ADR-0002-no-links-in-release-paths.md"
  - "../../RELEASE_CHECKLIST.md"
---

# PDR-0001: crates.io Publication: Packages Verified in CI, Token Released Only for the Verified Package

## Context

Building a crate runs code from the crate and its dependencies (build
scripts, procedural macros). If that happens on the machine that holds the
registry token, the build can read or use the token, whatever the release
steps intend. `cargo publish` also always repackages, so a package checked
earlier is not necessarily the one uploaded.

## Decision

1. **Release packages are verified only in credential-free CI.** The tag workflow
   verifies the first crate's package (`cargo package`, which builds it);
   every later crate is verified by a read-only workflow dispatched on the
   release tag after its predecessors are on crates.io, so it resolves exactly
   as consumers will. Neither holds a registry credential or a persisted
   checkout credential.
2. **Evidence is bound to the exact archive.** The verification record names
   the repository, the tag object, the commit, the run and attempt, the
   Cargo version, the crate, version, registry, and the SHA-256 of the archive
   that was verified, hashed before anything could repackage it. The
   maintainer fetches it from an exactly selected successful run of the right
   workflow at the anchored commit and checks the archive against the digest.
3. **The publication ceremony never compiles.** Locally, `cargo package
   --no-verify` in a fresh Cargo home must reproduce the verified archive byte
   for byte. The pre-tag gate does build and test the maintainer's own main
   checkout (ordinary development), so it refuses to run while a Cargo
   credentials file or token variable is present, and packages without
   compiling in an empty Cargo home.
4. **The token is released only for that archive.** `cargo publish
   --no-verify` runs with one credential provider, from the trusted checkout:
   it releases the token only for the approved registry, crate, version and
   checksum Cargo reports for the archive it is about to send, never caches
   it, and refuses every other operation. An environment token is refused.
5. **Completion is checked, not assumed.** After the upload the index checksum
   and the downloaded published archive must both equal the verified digest.
6. **One crate at a time, in order.** `config/release/publishable-crates.txt`
   is the order; a crate already on the index is never republished. A failure
   after an earlier crate is published is an explicit partial release.

## Consequences

- Publication needs a CI run per crate after the first, and the maintainer's
  typed confirmation (or an explicit confirmation naming the verified digest).
- The registry's read path is not authenticated; the provider answers Cargo's
  read request with a placeholder that is not a credential.
- The real-Cargo test covers the first crate against a local registry; later
  crates rely on the same mechanism plus their own CI verification and the
  pre-upload byte match.

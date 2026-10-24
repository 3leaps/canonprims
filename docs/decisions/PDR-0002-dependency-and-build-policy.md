---
id: "PDR-0002"
title: "Dependencies come from crates.io only, cool before adoption, and build at a pinned toolchain"
status: "accepted"
date: "2026-10-24"
relates-to:
  - "https://github.com/3leaps/crucible/blob/main/docs/decisions/EPR-0001-published-artifact-dependency-integrity.md"
  - "../../deny.toml"
  - "../../.goneat/dependencies.yaml"
---

# PDR-0002: Dependencies Come from crates.io Only, Cool Before Adoption, and Build at a Pinned Toolchain

## Decision

1. **Sources.** Rust dependencies come from crates.io only: no git, path or
   other-registry dependency outside the workspace (`deny.toml` `[sources]`;
   the release source check refuses them again at the tag). The Go module has
   no requirements at all.
2. **Leaf.** canonprims depends on no other estate primitive library
   (`scripts/deps-check.sh`).
3. **TLS.** OpenSSL and native-tls are banned; anything needing TLS uses
   rustls (`deny.toml` `[bans]`).
4. **Licenses and advisories.** Permissive licenses only; advisories are
   checked on every change (`make deny`).
5. **Cooling.** A new dependency version must be at least seven days old before
   it is adopted (`.goneat/dependencies.yaml`); the threshold is not lowered.
   The standing exemptions are the project's own public organizations and
   their crate-name prefixes. Any other exception is added per package, with a
   date and a reason, through review.
6. **Toolchain.** The workspace `rust-version` (1.88.0) is the MSRV; it is
   tested (`make msrv-check`) and every release and registry step runs at it.
   No toolchain file is committed; the release source check refuses one.
7. **Lockfile.** `Cargo.lock` is committed and every build, test and package
   step uses `--locked`.
8. **CI.** Workflows are read-only, pin every action by full commit SHA, and
   are themselves pinned by digest (ADR-0001).

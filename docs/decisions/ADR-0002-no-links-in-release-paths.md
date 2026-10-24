---
id: "ADR-0002"
title: "Release and configuration paths never follow links"
status: "accepted"
date: "2026-10-24"
relates-to:
  - "ADR-0001-release-identity-and-tags.md"
  - "https://github.com/3leaps/crucible/blob/main/docs/decisions/PDR-0008-release-public-identity-in-tree.md"
  - "https://github.com/3leaps/crucible/blob/main/docs/decisions/EPR-0002-verification-gate-integrity.md"
---

# ADR-0002: Release and Configuration Paths Never Follow Links

## Context

The release steps read trust inputs (pins, anchors, the ceremony anchor, the
checker binary, tag messages, verification records, the registry token file)
and write release outputs (staged assets, checksum manifests, signatures,
anchors, fetched artifacts). A symbolic link in one of those positions lets
whoever can create the link choose what is read or overwritten: a planted
`SHA256SUMS` link would have the manifest written over an arbitrary file, a
linked pin directory would substitute another key, and a link in the tagged
source would let Cargo package a file from outside the tree.

## Decision

1. **Named inputs are regular files.** A trust or configuration input named
   by a variable or argument must be a regular file whose final path
   component is not a link; executables named this way must also be absolute
   paths. Directories named as inputs follow the same rule.
2. **Outputs are created, not followed.** A release output is written only
   where nothing exists yet, or into a directory the step created; an existing
   entry, link or not, is refused rather than replaced. Pin and anchor files
   are written once and never overwritten.
3. **Ancestors may be links; the named component may not.** Platform
   locations such as a temporary directory reached through a link are
   accepted. Where a path must be compared against the repository (outside or
   inside it), it is compared after resolving it.
4. **The release source contains no links.** The tagged commit is checked with
   git plumbing before anything compiles or packages it; a link, submodule, or
   escaping path refuses the release (ADR-0001, point 3).
5. **Fetched artifacts are regular files.** Anything downloaded from a
   workflow run or the release is checked entry by entry, and an artifact that
   holds anything other than the expected regular files is refused.
6. **Every rule has a negative control.** A test plants a link at the guarded
   position and must fail at that guard, for the reason the guard names, with
   the link target left untouched.

## Consequences

- An exact-inventory check already refuses unexpected entries in the release
  directory; the write-time refusals of point 2 are a second layer for the
  window between that check and the write.
- Operators pass real paths. A configuration that relied on a linked key or
  directory must name the target instead.
- This governs release, signing and publication tooling. It does not restrict
  the library's own behavior or ordinary development checkouts.

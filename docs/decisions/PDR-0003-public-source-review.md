---
id: "PDR-0003"
title: "Public source, history and change text carry no private context"
status: "accepted"
date: "2026-10-24"
relates-to:
  - "https://github.com/3leaps/oss-policies/blob/main/SENSITIVE-LOCAL-DATA.md"
---

# PDR-0003: Public Source, History and Change Text Carry No Private Context

## Decision

This repository follows the [3 Leaps OSS Sensitive Local Data Policy](https://github.com/3leaps/oss-policies/blob/main/SENSITIVE-LOCAL-DATA.md).
Source, tests, fixtures, comments, documentation, decision records, branch
names, commit messages, and pull-request text must not contain private
filesystem paths, home-directory names, internal hosts, non-public repository
or organization names, planning identifiers, or review-process detail. The
same applies to deny lists, expected strings and negative tests: a guard that
needs to name a class of dependency uses a pattern, not a list of private
names. Test paths and values are synthetic.

Change text states what changed and how it was verified. It does not narrate
how the change came about.

## Checks

Two checks, split by what they may know:

- `make check`, run in CI on every change, includes `scripts/content-check.py`.
  It refuses generic shapes in tracked files: local home paths, private-key
  blocks, access tokens and "remove before commit" markers. It holds no
  vocabulary, so it is safe in a public workflow.
- `make pr-final`, run by the maintainer before opening or updating a pull
  request, adds `scripts/surface-scan.sh`: limensafe with the maintainer's
  catalog, named by `LIMENSAFE_CATALOG_PATH` and kept outside this repository.
  It scans the tracked tree, each new commit message, the pull-request title
  and body, and the branch name, after proving the catalog blocks its own
  canary. The catalog is never given to CI. Unset, the scan is skipped with a
  warning under `make prepush` and required under `make pr-final` and the
  pre-tag gate; a set but invalid path fails.

A clean scan does not replace reading the public text.

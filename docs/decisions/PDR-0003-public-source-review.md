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

Before a push, `make prepush` runs the maintainer's surface check when
`CANONPRIMS_SURFACE_CHECK` names one (an executable outside the repository);
the pre-tag gate requires it. A clean check does not replace reading the
public text.

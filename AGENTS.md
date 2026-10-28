# canonprims — AI Agent Guide

## Read first

1. This file — operational protocols
2. `AGENTS.local.md` if present (untracked; machine-local only)
3. `README.md` — product identity
4. `docs/spec/jcs-rfc8785.md` — the normative scheme definition

canonprims is a **leaf primitive**: Rust crates plus an independent pure-Go
twin. Both implementations must agree byte for byte on the corpus and on
generated input.

## Operating model

| Aspect | Setting |
| ------ | ------- |
| Mode | Supervised (human reviews before commit) |
| Classification | code-substantive |
| Default role | devlead |
| Identity | Per session (no persistent memory) |

## Quick reference

| Task | Command |
| ---- | ------- |
| Full gate | `make check` |
| Fast gate | `make precommit` |
| Rust tests | `make test-rust` |
| Go tests | `make test-go` |
| Agreement | `make crosscheck` |
| Python binding | `make python-check` |
| Corpus | `make corpus` / `make corpus-check` |

## Session protocol

### Before changes

- Read the spec before changing either implementation. A behaviour change
  starts in `docs/spec/`, then the corpus (`scripts/canonical-json-corpus.py`),
  then both implementations, in the same change.
- Corpus expectations are written by hand or taken from an RFC. Never
  generate expected bytes with canonprims itself.
- Keep changes minimal and focused.

### Before committing

- Run `make check`.
- Verify no unintended changes with `git diff`.
- Do not put planning IDs, local path names, or secrets in tracked files.
  Planning and machine-local notes stay outside this tree;
  `.gitignore` is a convenience filter, not a security boundary.
  This follows the
  [3 Leaps OSS Sensitive Local Data](https://github.com/3leaps/oss-policies/blob/main/SENSITIVE-LOCAL-DATA.md)
  policy.

## Do / Do not

### Do

- Keep refusal codes identical across languages
- Take `Limits` explicitly on every public entry point
- Start every source file with `SPDX-License-Identifier: MIT OR Apache-2.0`
- Put logic in library crates; the CLI only parses argv and formats output
- Log on stderr; data on stdout

### Do not

- Push without maintainer approval
- Add a dependency on any other prim, or on `rsfulmen`, to any crate or to
  the Go module (`make deps-check` refuses it)
- Add a third-party Go dependency, or a public `serde_json` type to core or json
- Normalize Unicode, parse YAML, or add schema validation
- Repair input silently
- Commit secrets or local guidance files
- Add GPL/LGPL/AGPL dependencies

## Critical rules

### Never push without approval

```bash
git add <files>       # OK
git commit -m "..."   # OK
git push              # NEVER without explicit approval
```

### License

MIT OR Apache-2.0. All dependencies must stay permissively licensed.

## Key files

| Path | Purpose |
| ---- | ------- |
| `docs/spec/jcs-rfc8785.md` | Normative scheme definition |
| `conformance/canonical-json/v0` | Conformance corpus (generated; do not hand-edit) |
| `scripts/canonical-json-corpus.py` | Corpus authoring table |
| `crates/canonprims-core` | Schemes, refusal codes, limits, digests |
| `crates/canonprims-json` | RFC 8785 over a strict I-JSON loader |
| `crates/canonprims-cli` | The `canon` command |
| `go.mod`, `canon/` | Pure-Go twin (root module, standard library only) |
| `scripts/crosscheck.sh` | Rust/Go byte-for-byte agreement |
| `bindings/python` | Python binding (PyO3); its own Cargo workspace, never a release crate |
| `scripts/python-check.sh` | Python wheel, tests, corpus and Rust agreement |
| `VERSION` | Version SSOT |
| `.fulmen/repo.yaml` | Repository class declaration (prims, Profile B, leaf) |

# Release Notes

The latest three releases, newest first. The complete history is in
[CHANGELOG.md](CHANGELOG.md); the notes for each cut are in
[docs/releases/](docs/releases/).

---

## v0.1.5 - 2026-11-09

The command-line binary is now `canonprims` (it was `canon`), with three new
`jcs` modes for golden vectors, NDJSON prefixes and canonical sets, and the
library helpers behind them in Rust and Go. The Go package path, crate names,
bindings and conformance corpus are unchanged.

- `canonprims jcs --vector`, `--ndjson-array [--head N]` and `--sort-set`.
  `--ndjson-array` and `--sort-set` combine with each other and with one of
  `--vector` or `--digest`; `--sort-set` also combines with `--check`.
- `canonprims-json` and Go package `canon`: vector, strict NDJSON-prefix and
  canonical-set helpers, with refusal codes `not_an_array` and
  `duplicate_set_element`, held byte for byte equal by `make crosscheck`.
- Release archives are `canonprims-X.Y.Z-<platform>`; staging and verifying a
  published 0.1.0 to 0.1.4 release still expects its `canon-*` names.

Details: [docs/releases/v0.1.5.md](docs/releases/v0.1.5.md).

---

## v0.1.4 - 2026-10-31

Release preflight alignment for read-only GitHub Actions `GITHUB_TOKEN`
execution inside `registry-publish.yml`. The library, bindings, conformance
corpus and `canon` command are unchanged from 0.1.3.

- `scripts/release-github-preflight.sh`: handles `GITHUB_TOKEN` (`contents: read`)
  responses under `GITHUB_ACTIONS=true` (redacted `bypass_actors: null` on tag
  rulesets and release `.immutable == true` verification when
  `/immutable-releases` requires `Administration` scope), while keeping strict
  admin checks on maintainer preflight.
- Records `v0.1.3` arm64 runner image versions in `docs/releases/v0.1.3.md`.

Details: [docs/releases/v0.1.4.md](docs/releases/v0.1.4.md).

---

## v0.1.3 - 2026-10-31

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
  Bash 3.2 empty-array expansion guard, Rust `canon-diff` hex-parsing parity,
  Windows-portable surface test controls, and verbatim `LICENSE-MIT` /
  `LICENSE-APACHE` texts with `NOTICE` separated in root and binding packages.

Details: [docs/releases/v0.1.3.md](docs/releases/v0.1.3.md).

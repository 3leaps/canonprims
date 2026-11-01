# Release Notes

The latest three releases, newest first. The complete history is in
[CHANGELOG.md](CHANGELOG.md); the notes for each cut are in
[docs/releases/](docs/releases/).

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

---

## v0.1.2 - 2026-10-28

Python and TypeScript bindings, gated by the same conformance corpus and in
byte-for-byte agreement with Rust.

- Python package `canonprims`: abi3 wheels for CPython 3.10 and later on
  linux amd64/arm64, darwin arm64 and windows amd64/arm64.
- npm package `@3leaps/canonprims`: one WebAssembly module, no runtime
  dependencies.
- Both are signed release assets; the registry packages are those files.

Details: [docs/releases/v0.1.2.md](docs/releases/v0.1.2.md).

# Release Checklist

How a maintainer cuts a canonprims release. A release is one signed annotated
tag, `vX.Y.Z`, at a commit of `main`; it releases the Rust crates, the root
Go module, the Python wheels and the npm package together ([ADR-0001](docs/decisions/ADR-0001-release-identity-and-tags.md)); the
signing material and the trust rules are in
[docs/security/README.md](docs/security/README.md).

Signing, tagging, publishing and registry uploads are maintainer steps on the
maintainer's machine. CI holds no signing, release or registry authority.

## Prerequisites

- `gpg`, `minisign`, `gh`, `jq`, `python3` (3.11 or newer), `npm`, `uv` and the
  workspace MSRV toolchain installed. `make doctor` reports each tool's version
  against the recommended minimum in `.goneat/tools.yaml` and fails on any tool
  that is missing, older, or whose version it cannot read.
- decernor 0.1.8 or newer as a regular file at an absolute path
- limensafe and the maintainer's catalog, which the pre-tag gate requires for
  the public-surface scan (it never runs in CI)
- The ceremony environment (outside this repository):

  ```bash
  export CANONPRIMS_RELEASE_TAG="vX.Y.Z"                  # explicit; never derived
  export CANONPRIMS_TAG_MESSAGE_DIR="/path/outside/the/repository/$CANONPRIMS_RELEASE_TAG"
  export CANONPRIMS_DECERNOR_BIN=/absolute/path/to/decernor
  export CANONPRIMS_TAGGER_NAME='3 Leaps Infosec Team'    # config/release/tagger-identity.txt
  export CANONPRIMS_TAGGER_EMAIL=infosec@3leaps.net
  export CANONPRIMS_PGP_KEY_ID='<signing subkey>!'        # config/release/signing-subkey.txt
  export CANONPRIMS_GPG_HOMEDIR=/path/outside/the/repository
  export CANONPRIMS_GPG_SIGNING_FINGERPRINT='<primary>'   # approved primary, from a trusted channel
  export CANONPRIMS_MINISIGN_KEY=/path/to/minisign/secret/key
  export CANONPRIMS_RELEASE_ANCHOR_FILE=/path/outside/the/repository/anchor
  export LIMENSAFE_CATALOG_PATH=/path/outside/the/repository/catalog
  ```

  A bare `RELEASE_TAG` is refused by `make`.

## 0. First adoption only: public pins

The pins are written once and land on `main` through review before any release
uses them.

- [ ] With `CANONPRIMS_GPG_HOMEDIR`, `CANONPRIMS_PGP_KEY_ID` and
  `CANONPRIMS_MINISIGN_PUB_EXPORT` (the approved minisign public key) loaded:
  `make release-export-pin`. It writes
  `docs/security/release-signing-keys.asc`,
  `docs/security/canonprims-minisign.pub` and
  `config/release/signing-subkey.txt`, refusing to overwrite and writing
  nothing unless all three validate. Commit them, then
  `scripts/release-validate-pin.sh --pins-only`.
- [ ] `make release-insert-anchors`: decernor derives
  `keys/expected-fingerprints.{txt,ndjson}` from the committed exports, twice,
  and compares. Commit them.
- [ ] `make release-validate-pin`. The anchors must match the org's published
  release fingerprints; a mismatch is a stop.

## Changing a workflow

Every file under `.github/workflows/` and `.github/actions/` is pinned by
digest in `config/release/release-workflow.sha256`; every workflow must declare top-level
`permissions: contents: read`, and no job may grant more except the two
environment-gated OIDC publication jobs (`publish-pypi` and `publish-npm`) in
`.github/workflows/registry-publish.yml`, which grant `id-token: write` only inside
their required-reviewer `publish-pypi` and `publish-npm` environments. (Any workflow can be
edited into one that runs on a tag, so all of them are pinned.) Editing one
fails `make check` and `make release-preflight` until the pin is updated, and
tag verification checks the pin in the tagged commit. To change one:

- [ ] Edit the workflow or action and update its line in the pin file in the
  same change (`shasum -a 256 <file>`).
- [ ] Have the change reviewed as a trust-file change: the pin moving is the
  signal that CI or release behavior changed.

## 1. Release pack

- [ ] All in-scope PRs merged; on `main`, clean, in sync with `origin/main`.
- [ ] `VERSION` and the `Cargo.toml` workspace version set to `X.Y.Z`
  (`make version-check`).
- [ ] `CHANGELOG.md`: move `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, and
  **advance the compare links by hand**: `[Unreleased]: .../compare/vX.Y.Z...HEAD`
  and `[X.Y.Z]: .../compare/vPREV...vX.Y.Z` (the first release links to its
  tag). Every `## [x.y.z]` heading needs its footer definition.
- [ ] `docs/releases/vX.Y.Z.md`: the cut notes, starting with `# vX.Y.Z`. They
  record the `conformance/canonical-json/v0/MANIFEST.json` sha256 and the
  Rust/Go crosscheck seeds and input count, and state that `canon` verifies no
  signatures (so it embeds no key).
- [ ] Merge the release pack with an exact squash message whose body ends with
  the standard attribution footer, then check it: `git log -1 --format=%B`.
- [ ] `make release-preflight` on the merged `main`: clean tree, on `main`,
  equal to `origin/main`, `make release-github-preflight` (verifying that the
  `publish-pypi` and `publish-npm` GitHub Environments require maintainer review
  and allow only `v*` tags, the `Tag Publish Protection` ruleset is active on
  `refs/tags/v*`, and `immutable_releases` is enabled), the release source inert
  for Cargo (checked before anything compiles), `make check`,
  `make release-tooling-test`, `make release-check`, notes and changelog present.
- [ ] Main CI is green on this exact commit. Preflight alone is not enough.

## 2. Tags

- [ ] `make release-prepare-tag-message`. It creates `vX.Y.Z.txt` in
  `CANONPRIMS_TAG_MESSAGE_DIR` and never overwrites. Complete it: subject
  `Release X.Y.Z`, the release text, and the attribution footer.
- [ ] `make release-validate-pin`.
- [ ] `make release-tag`: the tag, signed by the committed subkey, local only,
  at `HEAD`, which must equal `origin/main`.
- [ ] `make release-verify-tag`: message bytes, tagger, target, and the
  signature against the pin committed in the tagged commit.
- [ ] `make release-push-tag`: one push, then the remote object is
  re-verified.
- [ ] `make release-verify-remote-tag`: the tag verifies against the committed
  pin and the approved primary, and GitHub reports it verified.
- [ ] Record the ceremony identity once, outside the repository, and keep
  `CANONPRIMS_RELEASE_ANCHOR_FILE` set for every later step (download refuses
  to run without it):
  `CANONPRIMS_EXPECTED_TAG_OBJECT=<vX.Y.Z object> CANONPRIMS_EXPECTED_COMMIT=<commit> make release-record-anchor`.
  Every later step (download, draft, sign, upload, publish) is bound to the
  tag object and the commit.

## 3. Release workflow

- [ ] The tag-triggered `Release` workflow is green: the tag verified, the
  committed anchors checked by the pinned decernor, five CLI archives, five
  Python wheels (each installed alone and tested on its platform), the npm
  package (installed from its tarball and tested), the source archive, the
  SBOM and the release identity uploaded as workflow artifacts. `make release-download` rebuilds the source archive from the
  verified commit and refuses one that differs.

- [ ] Record in `docs/releases/vX.Y.Z.md` (in a follow-up commit after the
  release) the runner group and the runner image version from the job logs of
  the two arm64 cells, which have no versioned runner label.

## 4. GitHub release (draft, then publish)

- [ ] Immutable releases are enabled on the repository (a maintainer setting)
  before the first draft is created.

Run from the trusted operator checkout on `main`; release steps read the tagged
commit as inert git objects and never run its scripts.

- [ ] `make release`: clean, download the exact successful workflow run,
  stage notes and public material from the tagged commit, checksum, create the
  draft, sign both manifests, verify and upload. The release stays a draft.
  (In a two-step ceremony where unsigned staging runs before signing, run
  `make release-stage` first, inspect `dist/release/SHA256SUMS`, and then run
  `make release-sign`, `make release-upload` and `make release-publish` without
  re-running `release-clean`.)
  - Expected assets: `canon-X.Y.Z-{linux-amd64,linux-arm64,darwin-arm64}.tar.gz`,
    `canon-X.Y.Z-{windows-amd64,windows-arm64}.zip`,
    `canonprims-X.Y.Z-cp310-abi3-{manylinux_2_17_x86_64.manylinux2014_x86_64,manylinux_2_17_aarch64.manylinux2014_aarch64,macosx_11_0_arm64,win_amd64,win_arm64}.whl`,
    `3leaps-canonprims-X.Y.Z.tgz`,
    `canonprims-X.Y.Z-src.tar.gz`, `sbom-X.Y.Z.cdx.json`,
    `LICENSE-MIT`, `LICENSE-APACHE`, `release-notes-vX.Y.Z.md`,
    `expected-fingerprints.{txt,ndjson}`, `canonprims-minisign.pub`,
    `canonprims-release-signing-key.asc`, `SHA256SUMS`, `SHA512SUMS` and their
    `.minisig` and `.asc` signatures. Both signatures on both manifests are
    required; the OpenPGP signatures must be made by the committed signing
    subkey.
- [ ] `make release-publish`: re-verifies the local set, compares the draft's
  bytes with it, and promotes the draft.

## 5. crates.io

The publication steps never compile release code. Credential-free CI
compiles and verifies each crate's package and records its SHA-256; the
maintainer packages without compiling, must reproduce that archive byte for
byte, and uploads through `scripts/release-cargo-provider.py`, a Cargo
credential provider that releases the token only for that crate, version and
checksum. Crates go one at a time, in `make release-crates-list` order
(`canonprims-core`, then `canonprims-json`), each verified against the
registry with its predecessors already published.

- [ ] The token is in a file outside the repository
  (`CANONPRIMS_CARGO_TOKEN_FILE`), scoped to publishing updates of these
  crates. A first publication uses a short-lived token for new crates,
  revoked afterwards. `CARGO_REGISTRY_TOKEN` must not be set.
- [ ] `make release-crates-clean` so no `dist/crates/*.identity.json` from an
  earlier release remains.

For each crate in order (`CRATE=canonprims-core`, then
`CRATE=canonprims-json`):

- [ ] Its CI verification is green: for `canonprims-core`, the `crate-check`
  job of the tag workflow; for every later crate, the `Crate verification`
  workflow, dispatched on the release tag only after its predecessors are
  on crates.io (`gh workflow run crates-verify.yml --ref vX.Y.Z -f
  crate=$CRATE`).
- [ ] `make release-crates-fetch CRATE=$CRATE`: downloads the package and its
  record from the exact successful run at the anchored commit and checks the
  record names the tag object, the commit, that run and attempt, and the
  archive digest. `CANONPRIMS_CRATE_RUN_ID` selects the run when there is
  more than one.
- [ ] `make release-crate-dry-run CRATE=$CRATE`: the local package (no
  compile) equals the CI-verified archive; nothing is uploaded.
- [ ] `make release-crate-publish CRATE=$CRATE`: after a typed confirmation,
  uploads through the release provider, waits for the index entry, and checks
  both the index checksum and the downloaded published archive against the
  verified digest. A crate already on the index is refused.

## 5b. PyPI and npm

The registries receive **exact signed files from the published GitHub release**;
nothing is rebuilt.

### Standard release (`v0.1.3+`, OIDC Trusted Publishing via `registry-publish.yml`)

Once the project exists on PyPI (`canonprims` in the `3leaps` organization) and
npm (`@3leaps/canonprims`), and GitHub Environments `publish-pypi` and
`publish-npm` (required reviewer `@3leapsdave`, deployment restricted to `v*`
tags) are configured as Trusted Publishers on PyPI and npm:

- [ ] Stage and verify in dry-run mode on the release tag:
  `gh workflow run registry-publish.yml --ref vX.Y.Z -f tag=vX.Y.Z -f registry=all -f dry_run=true`
  Confirm the `verify` job restores and verifies `vX.Y.Z` against the committed
  pin, downloads the published (non-draft) GitHub release, verifies both
  minisign and OpenPGP subkey signatures on `SHA256SUMS` and `SHA512SUMS`, and
  checks all 20 asset digests and wheel/npm metadata.
- [ ] Dispatch the real OIDC publication on the release tag and approve the
  `publish-pypi` and `publish-npm` environment deployments:
  `gh workflow run registry-publish.yml --ref vX.Y.Z -f tag=vX.Y.Z -f registry=all -f dry_run=false`
  - `publish-pypi` re-verifies the 5 staged `cp310-abi3` wheel digests against
    the verified `SHA256SUMS`, uploads via `pypa/gh-action-pypi-publish` with
    PEP 740 provenance attestations, and runs
    `scripts/release-verify-registries.py --expect-provenance` (which verifies
    both wheel SHA-256 digests and `/integrity/canonprims/X.Y.Z/<wheel>/provenance`).
  - `publish-npm` re-verifies `3leaps-canonprims-X.Y.Z.tgz` against the
    verified `SHA256SUMS` and `SHA512SUMS`, publishes with OIDC provenance
    attestation (`npm publish ... --provenance --access public`), and runs
    `scripts/release-verify-registries.py --expect-provenance` (which verifies
    `dist.integrity`, `dist.shasum`, and `dist.attestations.provenance`).
- [ ] Verify locally from the maintainer checkout:
  `CANONPRIMS_RELEASE_TAG=vX.Y.Z make release-stage-published release-verify-registries`

### First publication only (before the package exists on PyPI or npm)

Because npm Trusted Publishing can only be configured on an existing package
and a first PyPI upload creates the project:

- [ ] `make release-stage-published`: downloads the published GitHub release
  into `dist/published` and verifies that the release is non-draft at the
  tagged commit, its public keys and anchors match the tagged commit,
  `SHA256SUMS` and `SHA512SUMS` verify under both minisign and the committed
  OpenPGP signing subkey, all 20 asset checksums match, and the five wheels and
  npm tarball carry version `X.Y.Z`.
- [ ] PyPI: `uvx twine upload dist/published/canonprims-X.Y.Z-cp310-abi3-*.whl`
  (the five wheel files and nothing else). On a first upload with a user-scoped
  token, transfer the project to the `3leaps` organization in PyPI project
  settings (`https://pypi.org/manage/project/canonprims/settings/`) so
  `.ownership.organization` is `"3leaps"`. (`twine --sign` is not used because
  PyPI removed `.asc` signature uploads; wheel authenticity is anchored by the
  minisign and OpenPGP signed `SHA256SUMS` on the immutable GitHub release,
  plus PEP 740 attestations when published via OIDC Trusted Publishing.)
- [ ] npm: `npm publish dist/published/3leaps-canonprims-X.Y.Z.tgz --access public`
  (authenticate via browser web-authn when prompted so no long-lived npm token
  is needed). Pass the tarball, not a directory: npm must not repack it.
  - Register OIDC Trusted Publishing (`npm >= 11.5.1`):
    `npm trust github @3leaps/canonprims --file registry-publish.yml --repo 3leaps/canonprims --env publish-npm --allow-publish -y`
  - One-time defensive bare-name redirector (`canonprims` ->
    `@3leaps/canonprims`): `make release-pack-npm-redirector`, publish
    `dist/npm-redirector/canonprims-X.Y.Z.tgz`, transfer `canonprims` to the
    `3leaps` npm org, and deprecate it immediately:
    `npm deprecate canonprims "Canonical package is @3leaps/canonprims — install @3leaps/canonprims instead."`
    (Because `^0.Y.Z` resolves to `<0.(Y+1).0` under `0.x` SemVer, immediate
    deprecation is mandatory so no consumer relies on the unscoped name across
    `0.x` minor bumps.)
- [ ] `scripts/release-verify-registries.sh --bootstrap-no-provenance`:
  re-verifies the signatures and checksums in `dist/published`, polls PyPI and
  npm (with bounded retry for index/scan propagation), and checks that:
  - PyPI (`https://pypi.org/pypi/canonprims/X.Y.Z/json`) reports
    `ownership.organization == "3leaps"` and the SHA-256 of every wheel equals
    its line in the verified `SHA256SUMS`.
  - npm (`@3leaps/canonprims@X.Y.Z`) serves the exact `dist.integrity`
    (`sha512-...`) and `dist.shasum` of the verified
    `3leaps-canonprims-X.Y.Z.tgz`.
  (`--bootstrap-no-provenance` is used only for this manual first upload before
  Trusted Publishing is registered; all subsequent releases require
  `--expect-provenance`, the default.)
- [ ] Revoke a first-publication token and configure Trusted Publishers on PyPI
  (`registry-publish.yml`, environment `publish-pypi`) and npm
  (`registry-publish.yml`, environment `publish-npm`).

## 6. After the release

- [ ] `go list -m github.com/3leaps/canonprims@vX.Y.Z` resolves.
- [ ] `pip install canonprims==X.Y.Z` and `npm install @3leaps/canonprims@X.Y.Z`
  in fresh environments import and canonicalize `{"b":1,"a":2}`.
- [ ] Someone other than the publisher verifies the published release: the
  tag, the anchors, the manifests and every digest (`CANONPRIMS_RELEASE_TAG=vX.Y.Z
  make release-stage-published release-verify-registries`).

## Porting notes for sibling `*prims` repositories

When adapting this release ceremony to other repositories in the family, two
repository-specific switches apply:

- **WASM (1 tarball) vs. N-API (8 packages) and `build.rs`:** `canonprims`
  packages a single WebAssembly tarball (`3leaps-canonprims-X.Y.Z.tgz`) and
  forbids `build.rs` across the entire tree in `scripts/release-source-check.py`.
  Repositories with native FFI or N-API TypeScript bindings publish the 7
  platform-specific npm packages before `@3leaps/<pkg>` and allowlist `build.rs`
  only on the specific FFI/N-API crates that require a build script.
- **Bare-name npm redirector (`^0.x` SemVer caveat):**
  `scripts/pack-npm-redirector.sh` pins `"@3leaps/<pkg>": "^0.Y.Z"`, which under
  `0.x` SemVer matches `<0.(Y+1).0`. Keep the immediate `npm deprecate <bare>`
  step mandatory after the one-time redirector upload so nobody depends on the
  unscoped package across `0.x` minor bumps.

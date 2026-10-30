# canonprims Makefile
# Canonical serialization primitive: Rust crates and a pure-Go twin that must
# agree byte for byte.
#
# Quick reference:
#   make help        Show available targets
#   make check       Everything CI runs on one host
#   make precommit   fmt-check, lint
#   make prepush     check
#   make crosscheck  Rust and Go agreement only
#   make python-check  Python binding: wheel, tests, corpus and Rust agreement
#   make ts-check      TypeScript binding: wasm, package, tests, corpus and Rust agreement

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: all help check precommit prepush fmt fmt-check lint test test-rust test-go msrv-check
.PHONY: pr-final surface-scan content-check jq-portability doctor
.PHONY: corpus corpus-check witness witness-controls crosscheck python-check ts-check deny deps-check workflow-pin version version-check build clean
.PHONY: release-tooling-test release-check release-preflight release-prepare-tag-message release-tag release-push-tag
.PHONY: release-verify-tag release-verify-remote-tag release-record-anchor release-export-pin release-validate-pin
.PHONY: release-insert-anchors release-crates-list release-source-check release-crates-clean release-clean
.PHONY: release-crates-fetch release-crate-dry-run release-crate-publish
.PHONY: release-download release-notes release-checksums release-create-draft release-stage release-sign release-verify
.PHONY: release-upload release-publish release release-stage-published release-verify-registries release-pack-npm-redirector

CARGO ?= cargo
GO ?= go
PYTHON ?= python3
GOENV := GOWORK=off CGO_ENABLED=0
MSRV := $(shell sed -n 's/^rust-version = "\(.*\)"/\1/p' Cargo.toml)
VERSION := $(shell tr -d ' \t\r\n' < VERSION)
PY_BINDING := bindings/python
TS_BINDING := bindings/typescript

all: check

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

check: fmt-check lint test corpus-check witness witness-controls crosscheck deps-check content-check jq-portability version-check deny workflow-pin ## Everything CI runs on one host
	@echo "[ok] check"

precommit: fmt-check lint ## Fast pre-commit gate
	@echo "[ok] precommit"

prepush: check surface-scan ## Pre-push gate (the surface scan is skipped without a catalog)
	@echo "[ok] prepush"

# Before opening or updating a PR: everything CI runs, plus the maintainer's
# public-surface scan, which is required here, including the PR title and body
# in the file named by CANONPRIMS_SURFACE_PR_TEXT.
pr-final: check ## Before opening or updating a PR: check plus the required surface scan
	@CANONPRIMS_SURFACE_SCAN_REQUIRED=1 PYTHON=$(PYTHON) scripts/surface-scan.sh
	@echo "[ok] pr-final"

# The public-surface scan uses limensafe with a maintainer catalog named by
# LIMENSAFE_CATALOG_PATH, outside this repository. It never runs in CI.
surface-scan: ## Public-surface scan (tree, commit messages, PR text, branch) when LIMENSAFE_CATALOG_PATH is set
	@PYTHON=$(PYTHON) scripts/surface-scan.sh

# Vocabulary-free shapes only (local paths, keys, tokens, commit markers); runs
# in CI as part of check.
content-check: ## Refuse local paths, private keys, tokens and commit markers in tracked files
	@$(PYTHON) -I -B scripts/content-check.py

fmt: ## Format Rust and Go
	$(CARGO) fmt --all
	$(CARGO) fmt --manifest-path $(PY_BINDING)/Cargo.toml
	$(CARGO) fmt --manifest-path $(TS_BINDING)/Cargo.toml
	gofmt -w canon

fmt-check: ## Check formatting
	$(CARGO) fmt --all -- --check
	$(CARGO) fmt --manifest-path $(PY_BINDING)/Cargo.toml -- --check
	$(CARGO) fmt --manifest-path $(TS_BINDING)/Cargo.toml -- --check
	@out="$$(gofmt -l canon)"; if [ -n "$$out" ]; then echo "gofmt: $$out"; exit 1; fi
	@echo "[ok] fmt-check"

lint: ## clippy and go vet
	$(CARGO) clippy --workspace --all-targets --all-features --locked -- -D warnings
	CARGO_TARGET_DIR=$(CURDIR)/target/python $(CARGO) clippy --manifest-path $(PY_BINDING)/Cargo.toml --all-targets --locked -- -D warnings
	CARGO_TARGET_DIR=$(CURDIR)/target/wasm $(CARGO) clippy --manifest-path $(TS_BINDING)/Cargo.toml --target wasm32-unknown-unknown --locked -- -D warnings
	$(GOENV) $(GO) vet ./...
	@echo "[ok] lint"

test: test-rust test-go ## Rust and Go tests

test-rust: ## Rust tests
	$(CARGO) test --workspace --all-features --locked

test-go: ## Go tests (standard library only, no cgo)
	$(GOENV) $(GO) test -count=1 ./...

msrv-check: ## Rust tests at the MSRV
	$(CARGO) +$(MSRV) test --workspace --all-features --locked

corpus: ## Regenerate the conformance corpus from its authoring table
	$(PYTHON) -I scripts/canonical-json-corpus.py

corpus-check: ## The committed corpus matches its authoring table
	$(PYTHON) -I scripts/canonical-json-corpus.py --check > /dev/null
	@echo "[ok] corpus-check"

witness: ## Accept cases agree with independent witnesses
	scripts/corpus-witness.sh

witness-controls: ## The witness gate fails when it must
	scripts/witness-controls.sh

crosscheck: ## Rust and Go agree byte for byte
	scripts/crosscheck.sh

python-check: ## Python binding: build the wheel, run its tests and corpus, agree with Rust
	CARGO_TARGET_DIR=$(CURDIR)/target/python PYTHON=$(PYTHON) scripts/python-check.sh

ts-check: ## TypeScript binding: build the wasm package, run its tests and corpus, agree with Rust
	PYTHON=$(PYTHON) scripts/ts-check.sh

deny: ## cargo-deny: licenses, bans, sources, advisories
	$(CARGO) deny --locked check
	$(CARGO) deny --manifest-path $(PY_BINDING)/Cargo.toml --locked check
	$(CARGO) deny --manifest-path $(TS_BINDING)/Cargo.toml --locked check

workflow-pin: ## Every workflow matches its reviewed digest and is read-only
	$(PYTHON) -B -E scripts/release-workflow-pin.py check

jq-portability: ## jq variables are valid in jq 1.6 and 1.7
	@scripts/jq-portability.sh

deps-check: ## Leaf rule: no prim, rsfulmen or Go module dependencies
	scripts/deps-check.sh
	@echo "[ok] deps-check"

doctor: ## Report host tool versions against the recommended minimums (DOCTOR_SCOPE=release|dev)
	@scripts/doctor.sh $(or $(DOCTOR_SCOPE),release)

version: ## Print the version
	@echo $(VERSION)

version-check: ## VERSION matches Cargo.toml and both bindings
	@test "$(VERSION)" = "$$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)" || { echo "VERSION and Cargo.toml differ"; exit 1; }
	@test "$(VERSION)" = "$$(sed -n 's/^version = "\(.*\)"/\1/p' $(PY_BINDING)/Cargo.toml | head -1)" || { echo "VERSION and $(PY_BINDING)/Cargo.toml differ"; exit 1; }
	@test "$(VERSION)" = "$$(sed -n 's/^version = "\(.*\)"/\1/p' $(PY_BINDING)/pyproject.toml | head -1)" || { echo "VERSION and $(PY_BINDING)/pyproject.toml differ"; exit 1; }
	@test "$(VERSION)" = "$$(sed -n 's/^version = "\(.*\)"/\1/p' $(TS_BINDING)/Cargo.toml | head -1)" || { echo "VERSION and $(TS_BINDING)/Cargo.toml differ"; exit 1; }
	@test "$(VERSION)" = "$$($(PYTHON) -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' $(TS_BINDING)/package.json)" || { echo "VERSION and $(TS_BINDING)/package.json differ"; exit 1; }
	@echo "[ok] version-check"

build: ## Release build of the canon CLI
	$(CARGO) build --release --locked -p canonprims-cli

clean: ## Remove build output
	$(CARGO) clean

# -----------------------------------------------------------------------------
# Release (crucible PDR-0008)
# -----------------------------------------------------------------------------
#
# A release is one signed annotated tag, vX.Y.Z, at a commit of main; it
# releases the Rust crates and the root Go module together. The tag is an explicit input (CANONPRIMS_RELEASE_TAG); it is
# never derived from VERSION, git describe or the branch, and a bare
# RELEASE_TAG from any origin is refused so it cannot stand in for it.
#
# Maintainer inputs (local environment; never in this tree):
#   CANONPRIMS_RELEASE_TAG             vX.Y.Z
#   CANONPRIMS_TAG_MESSAGE_DIR         per-release message directory ending in the tag
#   CANONPRIMS_DECERNOR_BIN            absolute path to decernor >= 0.1.8 (no fallback)
#   CANONPRIMS_TAGGER_NAME/EMAIL       the committed tagger identity
#   CANONPRIMS_PGP_KEY_ID              the committed signing subkey followed by !
#   CANONPRIMS_GPG_HOMEDIR             external GPG home
#   CANONPRIMS_GPG_SIGNING_FINGERPRINT the approved primary fingerprint
#   CANONPRIMS_MINISIGN_KEY            minisign secret key locator (signing only)
#   CANONPRIMS_RELEASE_ANCHOR_FILE     external ceremony anchor record
#
# The public pins are committed (docs/security, keys/, config/release) and
# every verify and staging step reads them from the tagged commit.
# CI holds no signing, release or registry authority.

# Release stages must not overlap under `make -j`.
.NOTPARALLEL:

ifneq ($(origin RELEASE_TAG),undefined)
$(error RELEASE_TAG is not accepted; set CANONPRIMS_RELEASE_TAG=vX.Y.Z)
endif
REQUIRE_RELEASE_TAG = @if [ -z "$(CANONPRIMS_RELEASE_TAG)" ]; then \
	echo "error: CANONPRIMS_RELEASE_TAG=vX.Y.Z is required"; exit 1; fi

DIST_RELEASE := dist/release
DIST_PUBLISHED := dist/published
DIST_CRATES := dist/crates
# Per-cut notes file for the version in the tree (preflight only; not a tag).
NOTES_NAME := v$(strip $(VERSION))

release-tooling-test: ## Synthetic release-tooling controls (no operator keys or credentials)
	scripts/release-tooling-test.sh

release-check: version-check ## Package the published crates locally (does not publish)
	scripts/check-packages.sh

release-preflight: ## Pre-tag gate on a clean main synced with origin
	@source scripts/release-decernor.sh && resolve_release_decernor && echo "[ok] checker $$RELEASE_DECERNOR_BIN"
	@test -z "$$(git status --porcelain)" || { echo "error: working tree not clean"; git status --short; exit 1; }
	@# The gate builds and tests the tree; no registry credential may be readable by that code.
	@for f in "$${CARGO_HOME:-$$HOME/.cargo}/credentials.toml" "$${CARGO_HOME:-$$HOME/.cargo}/credentials"; do \
		test ! -e "$$f" || { echo "error: $$f exists; the release token lives only in CANONPRIMS_CARGO_TOKEN_FILE"; exit 1; }; \
	done
	@test -z "$${CARGO_REGISTRY_TOKEN+x}$${CARGO_REGISTRIES_CRATES_IO_TOKEN+x}" || { echo "error: unset CARGO_REGISTRY_TOKEN"; exit 1; }
	@test "$$(git symbolic-ref --quiet --short HEAD)" = main || { echo "error: release from main"; exit 1; }
	git fetch --quiet origin main
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "error: HEAD differs from origin/main"; exit 1; }
	@# The source to be tagged must be inert for Cargo before anything builds it.
	$(PYTHON) -I scripts/release-source-check.py HEAD
	$(MAKE) check release-tooling-test release-check
	CANONPRIMS_SURFACE_SCAN_REQUIRED=1 CANONPRIMS_SURFACE_SCOPE=release PYTHON=$(PYTHON) scripts/surface-scan.sh
	@test -f "docs/releases/$(NOTES_NAME).md" || { echo "error: docs/releases/$(NOTES_NAME).md is required"; exit 1; }
	@digest="$$(shasum -a 256 conformance/canonical-json/v0/MANIFEST.json | cut -c1-64)"; \
	grep -q "$$digest" "docs/releases/$(NOTES_NAME).md" || { echo "error: release notes must record the corpus MANIFEST.json sha256 $$digest"; exit 1; }
	@seeds="$$(sed -n 's/^seeds="$${CROSSCHECK_SEEDS:-\(.*\)}"$$/\1/p' scripts/crosscheck.sh)"; \
	test -n "$$seeds" || { echo "error: no crosscheck seeds found in scripts/crosscheck.sh"; exit 1; }; \
	for seed in $$seeds; do \
		grep -q "$$seed" "docs/releases/$(NOTES_NAME).md" || { echo "error: release notes must record crosscheck seed $$seed"; exit 1; }; \
	done
	@grep -q '^## \[$(VERSION)\]' CHANGELOG.md || { echo "error: CHANGELOG.md has no [$(VERSION)] section"; exit 1; }
	@grep -q '^\[$(VERSION)\]: ' CHANGELOG.md || { echo "error: CHANGELOG.md has no [$(VERSION)] compare link"; exit 1; }
	@echo "[ok] release preflight; next: make release-prepare-tag-message"

release-prepare-tag-message: ## Prepare the per-tag annotation messages (outside the repo)
	$(REQUIRE_RELEASE_TAG)
	scripts/release-tag-operator.sh prepare-message

release-tag: ## Create both release tags, signed and local only
	$(REQUIRE_RELEASE_TAG)
	scripts/release-tag-operator.sh local-tag

release-push-tag: ## Push the verified release tags atomically, then verify them
	$(REQUIRE_RELEASE_TAG)
	scripts/release-tag-operator.sh remote-push

release-verify-tag: ## Verify the local release tags against the committed pin
	$(REQUIRE_RELEASE_TAG)
	scripts/release-verify-tag.sh

release-verify-remote-tag: ## Verify the pushed release tags against the committed pin and GitHub
	$(REQUIRE_RELEASE_TAG)
	scripts/release-verify-published-tag.sh

release-record-anchor: ## Record the approved tag object and commit (no overwrite)
	$(REQUIRE_RELEASE_TAG)
	scripts/release-record-anchor.sh

release-export-pin: ## One time: write the public pins for review (refuses overwrite)
	scripts/release-export-pin.sh

release-validate-pin: ## Validate the committed public pins and anchors
	scripts/release-validate-pin.sh

release-insert-anchors: ## Derive the fingerprint anchors with decernor (refuses overwrite)
	scripts/release-insert-anchors.sh

release-crates-list: ## List the published crates in registry order
	@$(PYTHON) scripts/release-crates.py list

release-source-check: ## The tagged release source is inert for Cargo (git plumbing only)
	$(REQUIRE_RELEASE_TAG)
	@commit="$$(git rev-parse --verify --quiet "refs/tags/$(CANONPRIMS_RELEASE_TAG)^{commit}")" || { echo "error: $(CANONPRIMS_RELEASE_TAG) is absent"; exit 1; }; \
	$(PYTHON) -I scripts/release-source-check.py "$$commit"

release-crates-fetch: ## Fetch one crate's CI package verification (CRATE=name)
	$(REQUIRE_RELEASE_TAG)
	@test -n "$(CRATE)" || { echo "error: CRATE=<name> is required"; exit 1; }
	scripts/release-crates-fetch.sh "$(CANONPRIMS_RELEASE_TAG)" "$(CRATE)" "$(DIST_CRATES)"

release-crate-dry-run: ## Match the local package to the CI-verified archive (CRATE=name; no upload)
	$(REQUIRE_RELEASE_TAG)
	@test -n "$(CRATE)" || { echo "error: CRATE=<name> is required"; exit 1; }
	CANONPRIMS_CRATE_RECORDS="$(abspath $(DIST_CRATES))" scripts/release-crate-publish.sh "$(CRATE)"

release-crate-publish: ## Publish one crate through the release credential provider (CRATE=name; maintainer)
	$(REQUIRE_RELEASE_TAG)
	@test -n "$(CRATE)" || { echo "error: CRATE=<name> is required"; exit 1; }
	CANONPRIMS_CRATE_RECORDS="$(abspath $(DIST_CRATES))" scripts/release-crate-publish.sh --publish "$(CRATE)"

release-crates-clean: ## Remove dist/crates
	rm -rf "$(DIST_CRATES)"

release-clean: release-crates-clean ## Remove dist/release, dist/published, their anchors, and dist/crates
	rm -rf "$(DIST_RELEASE)" "$(DIST_RELEASE).anchor" "$(DIST_PUBLISHED)" "$(DIST_PUBLISHED).anchor"

release-download: ## Fetch the exact successful tag-workflow artifacts
	$(REQUIRE_RELEASE_TAG)
	scripts/release-fetch-ci-artifacts.sh "$(CANONPRIMS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-notes: ## Stage cut notes and public material from the tagged commit
	$(REQUIRE_RELEASE_TAG)
	scripts/release-stage-public.sh "$(DIST_RELEASE)"

release-checksums: ## Generate SHA256SUMS and SHA512SUMS
	$(REQUIRE_RELEASE_TAG)
	scripts/generate-checksums.sh "$(DIST_RELEASE)" "$(CANONPRIMS_RELEASE_TAG)"

release-create-draft: ## Create the draft release from the checksummed set
	$(REQUIRE_RELEASE_TAG)
	scripts/release-create-draft.sh "$(CANONPRIMS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-stage: ## Clean -> download -> stage -> checksums -> draft (unsigned; inspect before signing)
	$(REQUIRE_RELEASE_TAG)
	$(MAKE) release-clean
	$(MAKE) release-download
	$(MAKE) release-notes
	$(MAKE) release-checksums
	$(MAKE) release-create-draft
	@echo "[ok] unsigned draft staged in $(DIST_RELEASE); inspect SHA256SUMS, then run: make release-sign release-upload release-publish"

release-sign: ## Sign both checksum manifests with minisign and OpenPGP
	$(REQUIRE_RELEASE_TAG)
	scripts/sign-release-assets.sh "$(CANONPRIMS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-verify: ## Verify checksums, staged public material and signatures
	$(REQUIRE_RELEASE_TAG)
	scripts/verify-checksums.sh "$(DIST_RELEASE)"
	scripts/verify-staged-public.sh "$(DIST_RELEASE)"
	scripts/verify-signatures.sh "$(DIST_RELEASE)"

release-upload: release-verify ## Upload the signed set to the draft
	scripts/upload-release-assets.sh "$(CANONPRIMS_RELEASE_TAG)" "$(DIST_RELEASE)"

release-publish: ## Promote the verified draft (maintainer)
	$(REQUIRE_RELEASE_TAG)
	scripts/release-publish.sh "$(DIST_RELEASE)"

release: ## Clean -> download -> stage -> checksums -> draft -> sign -> upload
	$(REQUIRE_RELEASE_TAG)
	$(MAKE) release-stage
	$(MAKE) release-sign
	$(MAKE) release-upload
	@echo "[ok] signed draft staged; make release-publish promotes it"

release-stage-published: ## Download and verify the published GitHub release into dist/published
	$(REQUIRE_RELEASE_TAG)
	rm -rf "$(DIST_PUBLISHED)" "$(DIST_PUBLISHED).anchor"
	scripts/release-stage-published.sh "$(CANONPRIMS_RELEASE_TAG)" "$(DIST_PUBLISHED)"

release-verify-registries: ## Verify PyPI and npm serve the exact signed release bytes in dist/published
	$(REQUIRE_RELEASE_TAG)
	scripts/release-verify-registries.sh "$(DIST_PUBLISHED)" $(or $(REGISTRY),all)

release-pack-npm-redirector: ## Build the bare-name npm redirector tarball (canonprims-<version>.tgz)
	scripts/pack-npm-redirector.sh dist/npm-redirector "$(VERSION)"

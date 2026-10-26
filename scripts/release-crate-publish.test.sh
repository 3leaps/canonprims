#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# End to end with real Cargo against a local test registry: the CI step
# verifies canonprims-core and records its archive digest; the maintainer step
# packages without compiling, matches that archive, and uploads through the
# release credential provider, which releases the token only for the verified
# checksum. Negative controls: a changed archive gets no token and nothing is
# uploaded; a tampered record, an environment token, a reused publication and
# a published archive that differs all fail.
set -euo pipefail
# shellcheck source=scripts/release-test-fixture.sh
source "$(dirname "$0")/release-test-fixture.sh"
export PYTHONDONTWRITEBYTECODE=1
msrv="$(sed -n 's/^rust-version = "\(.*\)"/\1/p' "$fixture_root/Cargo.toml")"
if ! command -v cargo >/dev/null || ! cargo "+$msrv" --version >/dev/null 2>&1; then
	echo "error: this test needs cargo with the $msrv toolchain" >&2
	exit 1
fi
version="$(tr -d '\r\n' <"$fixture_root/VERSION")"
tag="v$version"

# The release source: the real tree at HEAD, as a fresh repository with
# release tags (fixture keys; the published-tag verifier is a stub here and
# is tested on its own).
repo="$fixture_dir/repo"
git -C "$fixture_root" archive HEAD | (mkdir -p "$repo" && tar -x -C "$repo")
cp "$fixture_root"/scripts/*.sh "$fixture_root"/scripts/*.py "$repo/scripts/"
git -C "$repo" init -q -b main
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" config tag.gpgsign false
git -C "$repo" remote add origin https://github.com/3leaps/canonprims.git
cat >"$repo/scripts/release-verify-published-tag.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$CANONPRIMS_EXPECTED_COMMIT" == "$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{commit}")" ]]
SH
chmod +x "$repo/scripts/release-verify-published-tag.sh"
# The tagged commit carries poisoned copies of the maintainer-side scripts;
# the trusted checkout (a newer main) has the real ones. The maintainer step
# must never run a script from the tagged tree. (The CI step runs the tagged
# tree by design, so its scripts stay real.)
maintainer_scripts=(release-crate-publish.sh release-cargo-provider.py release-crate-record.py release-index-entry.py
	check-registry-config.py release-common.sh release-gh.sh)
mkdir -p "$fixture_dir/trusted"
for name in "${maintainer_scripts[@]}"; do
	cp -p "$repo/scripts/$name" "$fixture_dir/trusted/$name"
	printf '#!/usr/bin/env bash\ntouch "%s/poisoned"\nexit 0\n' "$fixture_dir" >"$repo/scripts/$name"
done
# A cargo in the tagged tree, reached by a relative PATH entry once the
# maintainer step changes into the tagged worktree.
mkdir -p "$repo/bin"
printf '#!/usr/bin/env bash\ntouch "%s/poisoned"\nexit 0\n' "$fixture_dir" >"$repo/bin/cargo"
chmod +x "$repo/bin/cargo"
git -C "$repo" add -A
git -C "$repo" commit -qm release
git -C "$repo" tag -a -m "Release $version" "$tag"
commit="$(git -C "$repo" rev-parse HEAD)"
cp -p "$fixture_dir/trusted/"* "$repo/scripts/"
git -C "$repo" commit -qam 'trusted operator scripts'
printf 'tag=%s\nobject=%s\ncommit=%s\n' "$tag" \
	"$(git -C "$repo" rev-parse "refs/tags/$tag")" "$commit" \
	>"$fixture_dir/ceremony.anchor"
export CANONPRIMS_RELEASE_TAG="$tag" CANONPRIMS_RELEASE_ANCHOR_FILE="$fixture_dir/ceremony.anchor"
export CANONPRIMS_INDEX_WAIT_TRIES=20 CANONPRIMS_INDEX_WAIT_SECONDS=0.5
unset CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN

# The local registry.
registry="$fixture_dir/registry"
python3 "$fixture_root/scripts/test-registry.py" "$registry" 0 dummy-token >/dev/null 2>&1 &
registry_pid=$!
trap 'kill "$registry_pid" 2>/dev/null || true; fixture_cleanup' EXIT
for _ in $(seq 1 50); do [[ -f "$registry/ready" ]] && break; sleep 0.1; done
port="$(cat "$registry/ready")"
index="sparse+http://127.0.0.1:$port/index/"
dl="http://127.0.0.1:$port/dl"
# Every maintainer step runs with empty and relative PATH entries first: one
# inside the checkout (bin) and one that resolves outside it (../outside).
mkdir -p "$fixture_dir/outside"
printf '#!/usr/bin/env bash\ntouch "%s/poisoned"\nexit 0\n' "$fixture_dir" >"$fixture_dir/outside/cargo"
chmod +x "$fixture_dir/outside/cargo"
publish() { (cd "$repo" && PATH="::bin:../outside:$PATH" "$repo/scripts/release-crate-publish.sh" --registry-index "$index" --registry-dl "$dl" "$@"); }
puts() { grep -c '"m": "PUT"' "$registry/requests.log" 2>/dev/null || true; }

# The CI step: credential-free verification of core against the registry.
ci_home="$fixture_dir/ci-home"
mkdir -p "$ci_home"
printf '[registries.testreg]\nindex = "%s"\n' "$index" >"$ci_home/config.toml"
records="$fixture_dir/records"
ci_checkout="$fixture_dir/ci-checkout"
git -C "$repo" worktree add --quiet --detach "$ci_checkout" "$tag"
(cd "$ci_checkout" && env -i PATH="$PATH" HOME="$ci_home" CARGO_HOME="$ci_home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
	CANONPRIMS_RELEASE_TAG="$tag" CANONPRIMS_CRATES_REGISTRY=testreg CANONPRIMS_CRATES_INDEX="$index" \
	scripts/ci-crate-verify.sh canonprims-core "$records" >"$fixture_dir/ci.out" 2>&1) || { cat "$fixture_dir/ci.out" >&2; exit 1; }
git -C "$ci_checkout" status --porcelain --untracked-files=no | grep -q . && { echo 'error: CI step changed tracked files' >&2; exit 1; }
# The CI output is the uploaded artifact: exactly the package and its record,
# which is the inventory the fetch step accepts.
[[ "$(cd "$records" && find . -mindepth 1 -print | LC_ALL=C sort | tr '\n' ' ')" == "./canonprims-core-$version.crate ./canonprims-core.identity.json " ]] ||
	{ echo 'error: CI output holds other entries than the package and its record' >&2; exit 1; }
# The CI step refuses an existing or in-checkout output directory.
expect_fail_with 'OUT_DIR must be an absolute path that does not exist' env -i PATH="$PATH" HOME="$ci_home" CANONPRIMS_RELEASE_TAG="$tag" \
	"$ci_checkout/scripts/ci-crate-verify.sh" canonprims-core "$records"
expect_fail_with 'OUT_DIR must be outside the checkout' env -i PATH="$PATH" HOME="$ci_home" CANONPRIMS_RELEASE_TAG="$tag" \
	"$ci_checkout/scripts/ci-crate-verify.sh" canonprims-core "$ci_checkout/crates/out"
git -C "$repo" worktree remove --force "$ci_checkout"
digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$records/canonprims-core.identity.json")"
export CANONPRIMS_CRATE_RECORDS="$records"
printf 'dummy-token\n' >"$fixture_dir/token"
export CANONPRIMS_CARGO_TOKEN_FILE="$fixture_dir/token"

# A dry run packages without compiling and matches the CI archive.
publish canonprims-core </dev/null >"$fixture_dir/out" 2>&1 || { cat "$fixture_dir/out" >&2; exit 1; }
grep -q "packages to the CI-verified archive ($digest)" "$fixture_dir/out"
[[ "$(puts)" == 0 ]]

# Refusals before any upload.
expect_fail_with 'json requires: canonprims-core|canonprims-core@.* is not on the index' publish canonprims-json </dev/null
expect_fail_with 'unset CARGO_REGISTRY_TOKEN' env CARGO_REGISTRY_TOKEN=x \
	"$repo/scripts/release-crate-publish.sh" --registry-index "$index" --registry-dl "$dl" --publish canonprims-core </dev/null
cp "$records/canonprims-core-$version.crate" "$fixture_dir/held.crate"
printf 'x' >>"$records/canonprims-core-$version.crate"
expect_fail_with 'does not match this release' publish canonprims-core </dev/null
cp "$fixture_dir/held.crate" "$records/canonprims-core-$version.crate"
cp "$records/canonprims-core.identity.json" "$fixture_dir/held.json"
python3 - "$records/canonprims-core.identity.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r["commit"] = "0" * 40; json.dump(r, open(sys.argv[1], "w"))
PY
expect_fail_with 'does not match this release' publish canonprims-core </dev/null
cp "$fixture_dir/held.json" "$records/canonprims-core.identity.json"
[[ "$(puts)" == 0 ]]

# A record whose digest is not what this source packages to is refused
# before any upload: the record and its archive agree with each other, but
# not with the release source.
python3 - "$records/canonprims-core.identity.json" "$records/canonprims-core-$version.crate" <<'PY'
import hashlib, json, sys
open(sys.argv[2], "ab").write(b"other bytes")
r = json.load(open(sys.argv[1])); r["sha256"] = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
json.dump(r, open(sys.argv[1], "w"))
PY
expect_fail_with 'package differs from the CI-verified archive' publish --publish canonprims-core </dev/null
cp "$fixture_dir/held.json" "$records/canonprims-core.identity.json"
cp "$fixture_dir/held.crate" "$records/canonprims-core-$version.crate"
[[ "$(puts)" == 0 ]]
# With real Cargo: an approval for a checksum other than the archive Cargo
# builds gets no token, and nothing reaches the registry.
gate_home="$fixture_dir/gate-home"
mkdir -p "$gate_home"
printf '[registries.testreg]\nindex = "%s"\n[registry]\nglobal-credential-providers = ["%s"]\n' \
	"$index" "$fixture_root/scripts/release-cargo-provider.py" >"$gate_home/config.toml"
printf '{"index-url":"%s","name":"canonprims-core","vers":"%s","cksum":"%s"}' \
	"$index" "$version" "$(printf '%064d' 0)" >"$fixture_dir/wrong-approval.json"
if (cd "$repo" && env -i PATH="$PATH" HOME="$gate_home" CARGO_HOME="$gate_home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
	RUSTUP_TOOLCHAIN="$msrv" CANONPRIMS_CARGO_APPROVAL="$fixture_dir/wrong-approval.json" \
	CANONPRIMS_CARGO_TOKEN_FILE="$fixture_dir/token" \
	cargo publish --no-verify --locked --registry testreg -p canonprims-core) >"$fixture_dir/gate.out" 2>&1; then
	echo 'error: cargo published with a mismatched approval' >&2
	exit 1
fi
grep -q 'is not approved' "$fixture_dir/gate.out" || { cat "$fixture_dir/gate.out" >&2; exit 1; }
[[ "$(puts)" == 0 ]] || { echo 'error: an upload reached the registry without approval' >&2; exit 1; }
# An ancestor .cargo/config.toml naming another provider outranks CARGO_HOME;
# the environment override used by the ceremony outranks both. (The ceremony
# sets it for crates.io and for the test registry; this exercises the latter.)
hostile="$fixture_dir/hostile-provider"
printf '#!/bin/sh\ntouch "%s/hostile-ran"\nexit 1\n' "$fixture_dir" >"$hostile"
chmod +x "$hostile"
mkdir -p "$fixture_dir/.cargo"
printf '[registry]\nglobal-credential-providers = ["%s"]\n' "$hostile" >"$fixture_dir/.cargo/config.toml"
(cd "$repo" && env -i PATH="$PATH" HOME="$gate_home" CARGO_HOME="$gate_home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
	RUSTUP_TOOLCHAIN="$msrv" CARGO_REGISTRIES_TESTREG_CREDENTIAL_PROVIDER="$fixture_root/scripts/release-cargo-provider.py" \
	CANONPRIMS_CARGO_APPROVAL="$fixture_dir/wrong-approval.json" CANONPRIMS_CARGO_TOKEN_FILE="$fixture_dir/token" \
	cargo publish --no-verify --locked --registry testreg -p canonprims-core) >"$fixture_dir/gate.out" 2>&1 || true
[[ ! -e "$fixture_dir/hostile-ran" ]] || { echo 'error: an ancestor-configured provider ran despite the override' >&2; exit 1; }
grep -q 'is not approved' "$fixture_dir/gate.out" || { cat "$fixture_dir/gate.out" >&2; exit 1; }
[[ "$(puts)" == 0 ]]
# Without the override the ancestor provider wins (the reason for it).
(cd "$repo" && env -i PATH="$PATH" HOME="$gate_home" CARGO_HOME="$gate_home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
	RUSTUP_TOOLCHAIN="$msrv" cargo publish --no-verify --locked --registry testreg -p canonprims-core) >/dev/null 2>&1 || true
[[ -e "$fixture_dir/hostile-ran" ]] || { echo 'error: the ancestor-provider control did not reach the hostile provider' >&2; exit 1; }
rm -f "$fixture_dir/hostile-ran"
# The ceremony refuses an ancestor Cargo configuration outright (here it is
# also an ancestor of the trusted checkout, so the first check refuses it).
# shellcheck disable=SC2016 # expands in the child shell
expect_fail_with 'may not name an index or command' env TMPDIR="$fixture_dir" bash -c \
	'cd "$1" && scripts/release-crate-publish.sh --registry-index "$2" --registry-dl "$3" canonprims-core' _ "$repo" "$index" "$dl" </dev/null
rm -rf "$fixture_dir/.cargo"
rm -rf "$repo/target"
# The provider itself refuses a mismatched checksum, read and other
# operations (the step above stops before Cargo; this drives the provider).
prov="$fixture_root/scripts/release-cargo-provider.py"
printf '{"index-url":"%s","name":"canonprims-core","vers":"%s","cksum":"%s"}' "$index" "$version" "$digest" >"$fixture_dir/approval.json"
ask() { printf '%s\n' "$1" | CANONPRIMS_CARGO_APPROVAL="$fixture_dir/approval.json" CANONPRIMS_CARGO_TOKEN_FILE="$fixture_dir/token" \
	python3 -I "$prov" --cargo-plugin | tail -1; }
reg="{\"index-url\":\"$index\",\"name\":\"testreg\"}"
[[ "$(ask "{\"v\":1,\"registry\":$reg,\"kind\":\"get\",\"operation\":\"publish\",\"name\":\"canonprims-core\",\"vers\":\"$version\",\"cksum\":\"$digest\"}")" == *'"token": "dummy-token"'* ]]
for request in \
	"{\"v\":1,\"registry\":$reg,\"kind\":\"get\",\"operation\":\"publish\",\"name\":\"canonprims-core\",\"vers\":\"$version\",\"cksum\":\"$(printf '%064d' 0)\"}" \
	"{\"v\":1,\"registry\":$reg,\"kind\":\"get\",\"operation\":\"publish\",\"name\":\"canonprims-json\",\"vers\":\"$version\",\"cksum\":\"$digest\"}" \
	"{\"v\":1,\"registry\":{\"index-url\":\"https://github.com/rust-lang/crates.io-index\"},\"kind\":\"get\",\"operation\":\"publish\",\"name\":\"canonprims-core\",\"vers\":\"$version\",\"cksum\":\"$digest\"}" \
	"{\"v\":1,\"registry\":$reg,\"kind\":\"get\",\"operation\":\"yank\",\"name\":\"canonprims-core\",\"vers\":\"$version\"}" \
	"{\"v\":1,\"registry\":$reg,\"kind\":\"login\"}"; do
	[[ "$(ask "$request")" == *'"Err"'* ]] || { echo "error: provider released a token for $request" >&2; exit 1; }
done
[[ "$(ask "{\"v\":1,\"registry\":$reg,\"kind\":\"get\",\"operation\":\"read\"}")" != *dummy-token* ]]

# Without a terminal, publication needs the exact confirmation.
expect_fail_with 'canonprims-core not confirmed' publish --publish canonprims-core </dev/null
# shellcheck disable=SC2016 # expands in the child shell
expect_fail_with 'canonprims-core not confirmed' env CANONPRIMS_CRATE_PUBLISH_CONFIRM="canonprims-core@$version:$(printf '%064d' 0)" \
	bash -c 'cd "$1" && PATH="bin:$PATH" scripts/release-crate-publish.sh --registry-index "$2" --registry-dl "$3" --publish canonprims-core' _ "$repo" "$index" "$dl" </dev/null
[[ "$(puts)" == 0 ]]
export CANONPRIMS_CRATE_PUBLISH_CONFIRM="canonprims-core@$version:$digest"

# The real publication: the token is released for the verified checksum only.
export CANONPRIMS_CARGO_PROVIDER_LOG="$fixture_dir/provider.log"
publish --publish canonprims-core </dev/null >"$fixture_dir/out" 2>&1 || { cat "$fixture_dir/out" >&2; exit 1; }
grep -q "published and verified ($digest)" "$fixture_dir/out"
[[ "$(puts)" -ge 1 ]]
python3 - "$fixture_dir/provider.log" "$digest" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
ops = [(r["operation"], r["decision"]) for r in records]
assert ops == [("read", "placeholder"), ("publish", "released")], ops
assert records[1]["cksum"] == sys.argv[2], records[1]
PY
# Index reads never carried the token; the upload did.
python3 - "$registry/requests.log" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["m"] == "GET":
        assert r["auth"] in (None, ""), r
    if r["m"] == "PUT":
        assert r["auth"] == "dummy-token", r
PY
cmp "$registry/crates/canonprims-core-$version.crate" "$records/canonprims-core-$version.crate"
# Publishing the same version again is refused before Cargo runs.
expect_fail_with 'already on the index' publish --publish canonprims-core </dev/null
# Completion is checked against the downloaded published archive: on a fresh
# registry whose downloads are altered, the upload succeeds but the step fails.
kill "$registry_pid"
wait "$registry_pid" 2>/dev/null || true
registry="$fixture_dir/registry2"
mkdir -p "$registry"
touch "$registry/corrupt-downloads"
python3 "$fixture_root/scripts/test-registry.py" "$registry" 0 dummy-token >/dev/null 2>&1 &
registry_pid=$!
for _ in $(seq 1 50); do [[ -f "$registry/ready" ]] && break; sleep 0.1; done
port="$(cat "$registry/ready")"
index="sparse+http://127.0.0.1:$port/index/"
dl="http://127.0.0.1:$port/dl"
expect_fail_with 'published canonprims-core archive differs from the verified one' publish --publish canonprims-core </dev/null
# On a fresh registry that records another checksum for the same bytes, the
# index check refuses; the downloaded bytes would have matched.
kill "$registry_pid"
wait "$registry_pid" 2>/dev/null || true
registry="$fixture_dir/registry3"
mkdir -p "$registry"
touch "$registry/wrong-index-cksum"
python3 "$fixture_root/scripts/test-registry.py" "$registry" 0 dummy-token >/dev/null 2>&1 &
registry_pid=$!
for _ in $(seq 1 50); do [[ -f "$registry/ready" ]] && break; sleep 0.1; done
port="$(cat "$registry/ready")"
index="sparse+http://127.0.0.1:$port/index/"
dl="http://127.0.0.1:$port/dl"
expect_fail_with 'the index checksum for canonprims-core differs from the verified archive' publish --publish canonprims-core </dev/null
cmp -s "$registry/crates/canonprims-core-$version.crate" "$records/canonprims-core-$version.crate"
fresh_registry() {
	kill "$registry_pid" 2>/dev/null || true
	wait "$registry_pid" 2>/dev/null || true
	registry="$fixture_dir/registry-$1"
	mkdir -p "$registry"
	[[ -z "${2:-}" ]] || printf '%s\n' "$2" >"$registry/seed"
	python3 "$fixture_root/scripts/test-registry.py" "$registry" 0 dummy-token >/dev/null 2>&1 &
	registry_pid=$!
	for _ in $(seq 1 50); do [[ -f "$registry/ready" ]] && break; sleep 0.1; done
	port="$(cat "$registry/ready")"
	index="sparse+http://127.0.0.1:$port/index/"
	dl="http://127.0.0.1:$port/dl"
}
real_cargo="$(command -v cargo)"
# A yanked version of the crate is refused before the provider is asked and
# nothing is uploaded.
fresh_registry yanked "canonprims-core {\"name\":\"canonprims-core\",\"vers\":\"$version\",\"deps\":[],\"cksum\":\"$digest\",\"features\":{},\"yanked\":true}"
rm -f "$fixture_dir/yanked-provider.log"
# shellcheck disable=SC2016 # expands in the child shell
expect_fail_with "canonprims-core@$version is yanked on the index" env CANONPRIMS_CARGO_PROVIDER_LOG="$fixture_dir/yanked-provider.log" \
	CANONPRIMS_CRATE_PUBLISH_CONFIRM="canonprims-core@$version:$digest" \
	bash -c 'cd "$1" && scripts/release-crate-publish.sh --registry-index "$2" --registry-dl "$3" --publish canonprims-core' _ "$repo" "$index" "$dl" </dev/null
[[ "$(puts)" == 0 && ! -e "$fixture_dir/yanked-provider.log" ]] || { echo 'error: a yanked version reached the provider or the registry' >&2; exit 1; }
fresh_registry late-check
# A configuration planted in an ancestor of the scratch tree after the first
# checks (here, while packaging) is caught by the recheck before the upload.
late="$(mktemp -d)"
mkdir -p "$late/bin"
printf '#!/bin/bash\nmkdir -p "%s/tmp/.cargo"\nprintf "[registry]\\nglobal-credential-providers = [\\"%s\\"]\\n" >"%s/tmp/.cargo/config.toml"\nexec %q "$@"\n' \
	"$late" "$hostile" "$late" "$real_cargo" >"$late/bin/cargo"
chmod +x "$late/bin/cargo"
mkdir -p "$late/tmp"
# shellcheck disable=SC2016 # expands in the child shell
expect_fail_with 'ancestor of the release source is forbidden' env TMPDIR="$late/tmp" PATH="$late/bin:$PATH" \
	CANONPRIMS_CRATE_PUBLISH_CONFIRM="canonprims-core@$version:$digest" bash -c \
	'cd "$1" && scripts/release-crate-publish.sh --registry-index "$2" --registry-dl "$3" --publish canonprims-core' _ "$repo" "$index" "$dl" </dev/null
[[ ! -e "$fixture_dir/hostile-ran" && "$(puts)" == 0 ]] || { echo 'error: the late-planted provider ran or an upload happened' >&2; exit 1; }
rm -rf "$late"
fresh_registry late-upload
# Planted during the upload itself (after every check), only the environment
# override keeps the planted provider from running.
late="$(mktemp -d)"
mkdir -p "$late/bin" "$late/tmp"
# shellcheck disable=SC2016 # expands in the stub
printf '#!/bin/bash\nif [[ "$1" == publish ]]; then mkdir -p "%s/tmp/.cargo"; printf "[registry]\\nglobal-credential-providers = [\\"%s\\"]\\n" >"%s/tmp/.cargo/config.toml"; fi\nexec %q "$@"\n' \
	"$late" "$hostile" "$late" "$real_cargo" >"$late/bin/cargo"
chmod +x "$late/bin/cargo"
# shellcheck disable=SC2016 # expands in the child shell
env TMPDIR="$late/tmp" PATH="$late/bin:$PATH" CANONPRIMS_CRATE_PUBLISH_CONFIRM="canonprims-core@$version:$digest" bash -c \
	'cd "$1" && scripts/release-crate-publish.sh --registry-index "$2" --registry-dl "$3" --publish canonprims-core' _ "$repo" "$index" "$dl" \
	</dev/null >"$fixture_dir/late.out" 2>&1 || true
[[ -e "$late/tmp/.cargo/config.toml" ]] || { echo 'error: the during-upload plant did not happen' >&2; cat "$fixture_dir/late.out" >&2; exit 1; }
[[ ! -e "$fixture_dir/hostile-ran" ]] || { echo 'error: a provider planted during the upload ran' >&2; exit 1; }
rm -rf "$late"
[[ "$(puts)" -ge 1 ]] || { echo 'error: the during-upload control never reached the upload' >&2; exit 1; }
[[ ! -e "$fixture_dir/poisoned" ]] || { echo 'error: the maintainer step ran a script from the tagged tree' >&2; exit 1; }
echo '[ok] crate publication end to end with real Cargo and the release provider'

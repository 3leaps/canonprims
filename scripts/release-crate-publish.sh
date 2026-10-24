#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Publish one crate to crates.io without compiling release code on this
# machine.
#
#   1. Bind: the recorded ceremony anchor, the published tags, the inert
#      release source, and a scratch worktree of the tagged commit whose files
#      equal the tagged blobs. The CI verification record for the crate
#      (credential-free CI compiled and verified the package) must name the
#      same tag objects, commit, crate, version and registry.
#   2. Package without compiling: `cargo package --no-verify` in a fresh,
#      empty Cargo home must reproduce the CI-verified archive byte for byte.
#   3. Upload (with --publish): `cargo publish --no-verify` in another fresh
#      Cargo home whose only credential provider is release-cargo-provider.py.
#      It releases the token only for this crate, version and the verified
#      checksum, which Cargo computes from the exact archive it sends; any
#      other archive gets no token and nothing is transmitted. Afterwards the
#      published archive is downloaded and must have the same digest.
#
# Usage: release-crate-publish.sh [--publish] CRATE
# Inputs: CANONPRIMS_RELEASE_TAG, CANONPRIMS_RELEASE_ANCHOR_FILE,
#   CANONPRIMS_CRATE_RECORDS (directory from release-crates-fetch.sh), and for
#   --publish CANONPRIMS_CARGO_TOKEN_FILE (a file holding the crates.io token;
#   CARGO_REGISTRY_TOKEN must not be set).
# Test-only: --registry-index URL --registry-dl URL select a local registry;
# a release run never passes them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/release-common.sh
source "$root/scripts/release-common.sh"
die() {
	echo "error: $*" >&2
	exit 1
}
publish=0
# The index URL Cargo reports to credential providers for crates.io (its
# canonical name, whatever the transport; checked against Cargo 1.88).
index_url="https://github.com/rust-lang/crates.io-index"
crates_io_index="$index_url"
registry_name=crates-io
download="https://static.crates.io/crates"
while [[ $# -gt 1 ]]; do
	case "$1" in
	--publish) publish=1 ;;
	--registry-index) index_url="$2"; registry_name=testreg; shift ;;
	--registry-dl) download="$2"; shift ;;
	*) die "unknown option $1" ;;
	esac
	shift
done
crate="${1:-}"
# Commands resolve only from absolute directories outside the trusted
# checkout: an empty, dot or relative PATH entry would resolve against the
# tagged worktree once the steps below change into it.
trusted_path=
IFS=: read -r -a path_entries <<<"$PATH"
for entry in "${path_entries[@]}"; do
	[[ "$entry" == /* && -d "$entry" ]] || continue
	resolved="$(cd "$entry" && pwd -P)"
	case "$resolved" in "$root" | "$root"/*) continue ;; esac
	trusted_path="${trusted_path:+$trusted_path:}$resolved"
done
[[ -n "$trusted_path" ]] || die 'no absolute PATH entry'
PATH="$trusted_path"
export PATH
for tool in cargo python3 curl git shasum; do
	command -v "$tool" >/dev/null || die "$tool not found on the trusted PATH"
done
python_bin="$(command -v python3)"
[[ "$python_bin" == /* ]] || die 'python3 must resolve to an absolute path'
grep -Fxq "$crate" "$root/config/release/publishable-crates.txt" || die 'one published crate required'
[[ -z "${CARGO_REGISTRY_TOKEN+x}${CARGO_REGISTRIES_CRATES_IO_TOKEN+x}" ]] ||
	die 'unset CARGO_REGISTRY_TOKEN: the token reaches Cargo only through the release provider'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die 'clean trusted operator checkout required'
msrv="$(sed -n 's/^rust-version = "\(.*\)"/\1/p' "$root/Cargo.toml")"
[[ "$msrv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'workspace rust-version is required'

# 1. Bind.
load_ceremony_anchor
commit="$CANONPRIMS_EXPECTED_COMMIT"
"$root/scripts/check-registry-config.py"
"$root/scripts/release-verify-published-tag.sh"
records="${CANONPRIMS_CRATE_RECORDS:-}"
[[ "$records" == /* && -d "$records" && ! -L "$records" ]] || die 'CANONPRIMS_CRATE_RECORDS must name the fetched verification records'
scratch="$(mktemp -d "${TMPDIR:-/tmp}/canonprims-publish.XXXXXX")"
source_tree="$scratch/source"
cleanup() {
	git -C "$root" worktree remove --force "$source_tree" >/dev/null 2>&1 || true
	rm -rf "$scratch"
}
trap cleanup EXIT
"$root/scripts/release-source-check.py" "$commit" --repo "$root"
git -C "$root" worktree add --quiet --detach "$source_tree" "$commit"
"$root/scripts/release-source-check.py" "$commit" --repo "$root" --worktree "$source_tree"
"$root/scripts/check-registry-config.py" --source-root "$source_tree"
version="$(tr -d '\r\n' <"$source_tree/VERSION")"
[[ "$(release_tag)" == "v$version" ]] || die 'verified source version differs from the ceremony tag'

fresh_home() {
	mktemp -d "$scratch/cargo-home.XXXXXX"
}
registry_args=()
if [[ "$index_url" != "$crates_io_index" ]]; then
	registry_args=(--registry testreg)
	registry_config() { printf '[registries.testreg]\nindex = "%s"\n' "$index_url"; }
	sparse_index="$index_url"
else
	registry_config() { :; }
	sparse_index="https://index.crates.io/"
fi
# Index state comes from the sparse index itself; no crate is downloaded.
index_cksum() {
	python3 -I "$root/scripts/release-index-entry.py" "$sparse_index" "$1" "$version"
}
indexed() {
	local rc=0
	index_cksum "$1" >/dev/null 2>&1 || rc=$?
	# A yanked version exists on the registry and can never be published again.
	[[ "$rc" != 3 ]] || die "$1@$version is yanked on the index"
	[[ "$rc" -le 1 ]] || die "could not read the index entry for $1"
	return "$rc"
}
while IFS= read -r predecessor; do
	[[ "$predecessor" != "$crate" ]] || break
	indexed "$predecessor" || die "$predecessor@$version is not on the index; publish it first"
done <"$root/config/release/publishable-crates.txt"
if indexed "$crate"; then
	die "$crate@$version is already on the index"
fi
verified="$("$root/scripts/release-crate-record.py" check "$records/$crate.identity.json" "$records/$crate-$version.crate" \
	--tag "$(release_tag)" --object "$CANONPRIMS_EXPECTED_TAG_OBJECT" \
	--module-object "$CANONPRIMS_EXPECTED_MODULE_TAG_OBJECT" --commit "$commit" \
	--crate "$crate" --version "$version" --registry "$registry_name")" || die "the CI verification record for $crate does not match this release"

# 2. Package without compiling; it must be the CI-verified archive.
home="$(fresh_home)"
registry_config >"$home/config.toml"
(cd "$source_tree" && env -i PATH="$PATH" HOME="$home" CARGO_HOME="$home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
	RUSTUP_TOOLCHAIN="$msrv" cargo package --no-verify --locked -p "$crate" >/dev/null)
archive="$source_tree/target/package/$crate-$version.crate"
# The record check already bound the CI archive to this digest.
[[ "$(shasum -a 256 "$archive" | cut -c1-64)" == "$verified" ]] ||
	die "$crate package differs from the CI-verified archive"
[[ -z "$(git -C "$source_tree" status --porcelain --untracked-files=all)" ]] || die 'packaging changed the release source'
if [[ "$publish" == 0 ]]; then
	echo "[ok] $crate $version packages to the CI-verified archive ($verified); nothing uploaded"
	exit 0
fi

# 3. Upload through the release provider only.
token_file="${CANONPRIMS_CARGO_TOKEN_FILE:-}"
[[ "$token_file" == /* && -f "$token_file" && -s "$token_file" && ! -L "$token_file" ]] ||
	die 'CANONPRIMS_CARGO_TOKEN_FILE must name a file holding the registry token'
# Publication is confirmed by the maintainer: typed at a terminal, or, without
# one, CANONPRIMS_CRATE_PUBLISH_CONFIRM set to exactly CRATE@VERSION:SHA256.
if [[ -t 0 ]]; then
	printf 'Publish %s %s (sha256 %s)? Type the crate name to continue: ' "$crate" "$version" "$verified"
	read -r answer
	[[ "$answer" == "$crate" ]] || die "publication of $crate not confirmed"
else
	[[ "${CANONPRIMS_CRATE_PUBLISH_CONFIRM:-}" == "$crate@$version:$verified" ]] ||
		die "publication of $crate not confirmed: no terminal, and CANONPRIMS_CRATE_PUBLISH_CONFIRM is not $crate@$version:<verified sha256>"
fi
upload_home="$(fresh_home)"
# The provider runs under an interpreter named by absolute path, never one
# resolved from PATH.
printf '#!/bin/bash\nexec %q -I %q "$@"\n' "$python_bin" "$root/scripts/release-cargo-provider.py" >"$upload_home/provider"
chmod 0700 "$upload_home/provider"
python3 -I - "$upload_home/approval.json" "$index_url" "$crate" "$version" "$verified" <<'PY'
import json, sys
json.dump({"index-url": sys.argv[2], "name": sys.argv[3], "vers": sys.argv[4], "cksum": sys.argv[5]}, open(sys.argv[1], "w"))
PY
{
	registry_config
	printf '[registry]\nglobal-credential-providers = ["%s"]\n' "$upload_home/provider"
} >"$upload_home/config.toml"
# Immediately before the upload (the confirmation may have waited): no Cargo
# configuration in the source tree or any ancestor. The provider is also set
# in the environment, which outranks every configuration file.
"$root/scripts/check-registry-config.py" --source-root "$source_tree"
(cd "$source_tree" && env -i PATH="$PATH" HOME="$upload_home" CARGO_HOME="$upload_home" \
	RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" RUSTUP_TOOLCHAIN="$msrv" \
	CARGO_REGISTRY_CREDENTIAL_PROVIDER="$upload_home/provider" \
	CARGO_REGISTRIES_TESTREG_CREDENTIAL_PROVIDER="$upload_home/provider" \
	CANONPRIMS_CARGO_APPROVAL="$upload_home/approval.json" CANONPRIMS_CARGO_TOKEN_FILE="$token_file" \
	CANONPRIMS_CARGO_PROVIDER_LOG="${CANONPRIMS_CARGO_PROVIDER_LOG:-$upload_home/provider.log}" \
	cargo publish --no-verify --locked ${registry_args[@]+"${registry_args[@]}"} -p "$crate")
for _ in $(seq 1 "${CANONPRIMS_INDEX_WAIT_TRIES:-60}"); do
	indexed "$crate" && break
	sleep "${CANONPRIMS_INDEX_WAIT_SECONDS:-10}"
done
indexed "$crate" || die "$crate@$version did not appear on the index; stop and investigate"
# The registry records the checksum of what it received.
[[ "$(index_cksum "$crate")" == "$verified" ]] || die "the index checksum for $crate differs from the verified archive"
# The published archive must be the verified one.
curl --fail --silent --show-error --location --retry 3 --output "$scratch/published.crate" \
	"$download/$crate/$crate-$version.crate" || die "could not download the published $crate archive"
[[ "$(shasum -a 256 "$scratch/published.crate" | cut -c1-64)" == "$verified" ]] ||
	die "the published $crate archive differs from the verified one"
echo "[ok] $crate $version published and verified ($verified)"

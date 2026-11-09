#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Exact inventories and manifests; synthetic bytes only.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export CANONPRIMS_RELEASE_TAG=v1.2.3
source "$root/scripts/release-common.sh"
# The command-line archives were named canon through 0.1.4 and canonprims
# from 0.1.5; published older releases keep their own names.
cli_assets() { CANONPRIMS_RELEASE_TAG="$1" release_base_assets | grep -E '^canon(prims)?-[0-9]' | grep -v -- '-src\.tar\.gz$' | grep -v -- '-cp310-'; }
for pair in v0.1.0:canon v0.1.4:canon v0.1.5:canonprims v0.1.10:canonprims v0.2.0:canonprims v1.2.3:canonprims; do
    tag="${pair%%:*}" want="${pair#*:}" version="${tag#v}"
    expected="$(for p in linux-amd64.tar.gz linux-arm64.tar.gz darwin-arm64.tar.gz windows-amd64.zip windows-arm64.zip; do printf '%s-%s-%s\n' "$want" "$version" "$p"; done)"
    if [[ "$(cli_assets "$tag")" != "$expected" ]]; then
        echo "error: $tag command-line assets are not $want-*" >&2
        cli_assets "$tag" >&2
        exit 1
    fi
done
directory="$scratch/assets"
mkdir "$directory"
while IFS= read -r name; do printf 'synthetic %s\n' "$name" >"$directory/$name"; done < <(release_signable_assets)
files=()
while IFS= read -r name; do files+=("$name"); done < <(release_signable_assets | LC_ALL=C sort)
(
    cd "$directory"
    shasum -a 256 ${files[@]+"${files[@]}"} >SHA256SUMS
    shasum -a 512 ${files[@]+"${files[@]}"} >SHA512SUMS
)
"$root/scripts/validate-release-assets.sh" "$directory" checksummed
"$root/scripts/verify-checksums.sh" "$directory"
fail() { if "$@" >"$scratch/output" 2>&1; then
    echo 'error: expected asset rejection' >&2
    exit 1
fi; }
cp "$directory/SHA256SUMS" "$scratch/good256"
cp "$directory/SHA512SUMS" "$scratch/good512"
printf extra >"$directory/.hidden"
fail "$root/scripts/validate-release-assets.sh" "$directory" checksummed
rm "$directory/.hidden"
mv "$directory/canonprims-1.2.3-windows-arm64.zip" "$scratch/asset"
fail "$root/scripts/validate-release-assets.sh" "$directory" checksummed
fail "$root/scripts/verify-checksums.sh" "$directory"
mv "$scratch/asset" "$directory/canonprims-1.2.3-windows-arm64.zip"
cp "$directory/canonprims-1.2.3-windows-arm64.zip" "$directory/canonprims-1.2.4-windows-arm64.zip"
fail "$root/scripts/validate-release-assets.sh" "$directory" checksummed
rm "$directory/canonprims-1.2.4-windows-arm64.zip"
printf changed >>"$directory/expected-fingerprints.ndjson"
fail "$root/scripts/verify-checksums.sh" "$directory"
printf 'synthetic expected-fingerprints.ndjson\n' >"$directory/expected-fingerprints.ndjson"
cat "$scratch/good256" >>"$directory/SHA256SUMS"
fail "$root/scripts/verify-checksums.sh" "$directory"
cp "$scratch/good256" "$directory/SHA256SUMS"
rm "$directory/SHA512SUMS"
fail "$root/scripts/verify-checksums.sh" "$directory"
cp "$scratch/good512" "$directory/SHA512SUMS"
mv "$directory/LICENSE-MIT" "$scratch/license"
ln -s "$scratch/license" "$directory/LICENSE-MIT"
fail "$root/scripts/validate-release-assets.sh" "$directory" checksummed
fail "$root/scripts/verify-checksums.sh" "$directory"
rm "$directory/LICENSE-MIT"
mv "$scratch/license" "$directory/LICENSE-MIT"
# Absent manifests cannot produce a vacuous signature pass.
mkdir "$scratch/empty"
fail "$root/scripts/verify-signatures.sh" "$scratch/empty"
echo '[ok] exact release inventory and checksum negative controls'

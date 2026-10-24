#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Manifest signatures: both minisign and OpenPGP are required, and the OpenPGP
# signature must be made by the one signing subkey in the staged export.
# Throwaway keys only; needs gpg and minisign.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
	gpgconf --homedir "$scratch/gpg" --kill all >/dev/null 2>&1 || true
	gpgconf --homedir "$scratch/other" --kill all >/dev/null 2>&1 || true
	rm -rf "$scratch"
}
trap cleanup EXIT
command -v minisign >/dev/null || {
	echo 'error: verify-signatures tests need minisign' >&2
	exit 1
}
fail() {
	if "$@" >"$scratch/out" 2>&1; then
		echo "error: expected rejection: $*" >&2
		exit 1
	fi
}
keys() {
	local home="$1" primary
	mkdir -m 700 "$home"
	# The primary can sign too, so a primary signature is a real negative case.
	gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase '' \
		--quick-gen-key 'Synthetic release <synthetic@example.invalid>' ed25519 cert,sign 1d >/dev/null 2>&1
	primary="$(gpg --homedir "$home" --batch --with-colons --list-keys | awk -F: '$1=="fpr" {print $10; exit}')"
	gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase '' \
		--quick-add-key "$primary" ed25519 sign 1d >/dev/null 2>&1
	printf '%s %s\n' "$primary" "$(gpg --homedir "$home" --batch --with-colons --with-subkey-fingerprint --list-keys |
		awk -F: '$1=="sub" {s=1; next} s && $1=="fpr" {print $10; exit}')"
}
read -r primary subkey < <(keys "$scratch/gpg")
read -r _ other_subkey < <(keys "$scratch/other")
dir="$scratch/assets"
mkdir "$dir"
printf 'synthetic\n' >"$dir/asset"
(cd "$dir" && shasum -a 256 asset >SHA256SUMS && shasum -a 512 asset >SHA512SUMS)
minisign -G -W -p "$scratch/minisign.pub" -s "$scratch/minisign.key" >/dev/null
cp "$scratch/minisign.pub" "$dir/canonprims-minisign.pub"
gpg --homedir "$scratch/gpg" --batch --armor --export-options export-minimal --export "$subkey!" \
	>"$dir/canonprims-release-signing-key.asc"
printf 'gpg %s\nminisign %064d\n' "$primary" 0 >"$dir/expected-fingerprints.txt"
sign_all() {
	local home="$1" key="$2" manifest
	for manifest in SHA256SUMS SHA512SUMS; do
		rm -f "$dir/$manifest.minisig" "$dir/$manifest.asc"
		minisign -S -s "$scratch/minisign.key" -m "$dir/$manifest" -x "$dir/$manifest.minisig" </dev/null >/dev/null
		gpg --homedir "$home" --batch --armor --detach-sign --local-user "$key" \
			--output "$dir/$manifest.asc" "$dir/$manifest" 2>/dev/null
	done
}
verify() { "$root/scripts/verify-signatures.sh" "$dir"; }

sign_all "$scratch/gpg" "$subkey!"
verify >/dev/null

# A signature by the primary, which can sign, is not the committed subkey.
sign_all "$scratch/gpg" "$primary!"
fail verify
grep -q 'not by the committed signing subkey' "$scratch/out"

# A signature by another key fails.
sign_all "$scratch/other" "$other_subkey!"
fail verify
grep -q 'not by the committed signing subkey' "$scratch/out"

# A missing OpenPGP signature fails; it is not optional.
sign_all "$scratch/gpg" "$subkey!"
rm "$dir/SHA512SUMS.asc"
fail verify
grep -q 'Missing signature: SHA512SUMS.asc' "$scratch/out"

# A missing key file or anchor fails rather than skipping the check.
sign_all "$scratch/gpg" "$subkey!"
mv "$dir/expected-fingerprints.txt" "$scratch/anchors"
fail verify
grep -q 'are required' "$scratch/out"
mv "$scratch/anchors" "$dir/expected-fingerprints.txt"

# A changed manifest fails both signatures.
printf 'extra\n' >>"$dir/SHA256SUMS"
fail verify
grep -q 'SHA256SUMS signature INVALID' "$scratch/out"
grep -q 'SHA256SUMS PGP signature INVALID' "$scratch/out"

# Absent manifests cannot produce a vacuous pass.
mkdir "$scratch/empty"
fail "$root/scripts/verify-signatures.sh" "$scratch/empty"
# verify-public-keys: both key files present, public, and importable.
"$root/scripts/verify-public-keys.sh" "$dir" >/dev/null
keys="$scratch/keys"
mkdir "$keys"
cp "$dir/canonprims-minisign.pub" "$dir/canonprims-release-signing-key.asc" "$keys/"
mv "$keys/canonprims-minisign.pub" "$scratch/held.pub"
fail "$root/scripts/verify-public-keys.sh" "$keys"
grep -q 'canonprims-minisign.pub not found' "$scratch/out"
mv "$scratch/held.pub" "$keys/canonprims-minisign.pub"
mv "$keys/canonprims-release-signing-key.asc" "$scratch/held.asc"
fail "$root/scripts/verify-public-keys.sh" "$keys"
grep -q 'canonprims-release-signing-key.asc not found' "$scratch/out"
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nnot a key\n-----END PGP PUBLIC KEY BLOCK-----\n' >"$keys/canonprims-release-signing-key.asc"
fail "$root/scripts/verify-public-keys.sh" "$keys"
grep -q 'does not import' "$scratch/out"
echo '[ok] manifest signature controls passed'

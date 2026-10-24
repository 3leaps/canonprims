#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Newer operator anchors cannot strand manifest signing for an approved old tag.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
cleanup() {
    gpgconf --homedir "$scratch/home" --kill all >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT
fixture="$scratch/repo"
mkdir -p "$fixture/scripts" "$fixture/docs/security" "$fixture/docs/releases" "$scratch/home" "$scratch/assets"
chmod 700 "$scratch/home"
cp "$root/scripts/"{release-post-tag-selector.sh,verify-staged-public.sh,verify-public-keys.sh,release-common.sh,release-decernor.sh,release-insert-anchors.sh,install-release-anchors.sh,release-gh.sh} "$fixture/scripts/"
decernor="${CANONPRIMS_DECERNOR_BIN:-$(command -v decernor)}"
CANONPRIMS_DECERNOR_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$decernor")"
export CANONPRIMS_DECERNOR_BIN
gpg --homedir "$scratch/home" --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'Synthetic historical <historical@example.invalid>' ed25519 cert 1d >/dev/null 2>&1
primary="$(gpg --homedir "$scratch/home" --batch --with-colons --fingerprint --list-keys | awk -F: '$1=="fpr" {print $10;exit}')"
gpg --homedir "$scratch/home" --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$primary" ed25519 sign 1d >/dev/null 2>&1
subkey="$(gpg --homedir "$scratch/home" --batch --with-colons --with-subkey-fingerprint --list-keys | awk -F: '$1=="sub" {s=1;next} s && $1=="fpr" {print $10;exit}')"
gpg --homedir "$scratch/home" --batch --armor --export-options export-minimal --export "$subkey!" >"$fixture/docs/security/release-signing-keys.asc"
python3 - "$scratch/public.pub" <<'PY'
import base64,pathlib,sys
pathlib.Path(sys.argv[1]).write_text('untrusted comment: synthetic public key\n'+base64.b64encode(b'Ed'+b'\x01'*40).decode()+'\n')
PY
cp "$scratch/public.pub" "$fixture/docs/security/canonprims-minisign.pub"
printf 'historical cut\n' >"$fixture/docs/releases/v1.2.3.md"
printf '1.2.3\n' >"$fixture/VERSION"
cat >"$fixture/scripts/release-verify-published-tag.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$CANONPRIMS_EXPECTED_COMMIT" == "$(git rev-parse refs/tags/v1.2.3^{})" ]]
SH
chmod +x "$fixture/scripts/release-verify-published-tag.sh"
git init -q -b main "$fixture"
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" add -A
git -C "$fixture" commit -qm pins
"$fixture/scripts/release-insert-anchors.sh" >/dev/null
git -C "$fixture" add -A
git -C "$fixture" commit -qm historical
git -C "$fixture" tag v1.2.3
commit="$(git -C "$fixture" rev-parse HEAD)"
cp "$fixture/keys/expected-fingerprints."{txt,ndjson} "$scratch/assets/"
cp "$fixture/docs/security/release-signing-keys.asc" "$scratch/assets/canonprims-release-signing-key.asc"
cp "$scratch/public.pub" "$scratch/assets/canonprims-minisign.pub"
cp "$fixture/docs/releases/v1.2.3.md" "$scratch/assets/release-notes-v1.2.3.md"
printf 'tag=v1.2.3\nobject=%040d\nmodule_object=%040d\ncommit=%s\n' 1 3 "$commit" >"$scratch/assets.anchor"
cp "$scratch/assets.anchor" "$scratch/ceremony.anchor"
export CANONPRIMS_RELEASE_ANCHOR_FILE="$scratch/ceremony.anchor"
# Committed current operator trust data/version is deliberately different.
printf 'gpg %040d\nminisign %064d\n' 0 0 >"$fixture/keys/expected-fingerprints.txt"
printf 'newer public key\n' >"$fixture/docs/security/canonprims-minisign.pub"
printf '9.0.0\n' >"$fixture/VERSION"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'newer operator state'
export CANONPRIMS_RELEASE_TAG=v1.2.3 CANONPRIMS_GPG_SIGNING_FINGERPRINT="$primary" CANONPRIMS_PGP_KEY_ID="$subkey!" CANONPRIMS_GPG_HOMEDIR="$scratch/home"
"$fixture/scripts/release-post-tag-selector.sh" "$scratch/assets"
fail() { if "$@" >"$scratch/output" 2>&1; then
    echo 'error: invalid historical selector accepted' >&2
    exit 1
fi; }
fail env CANONPRIMS_PGP_KEY_ID=0000000000000000000000000000000000000000! "$fixture/scripts/release-post-tag-selector.sh" "$scratch/assets"
fail env CANONPRIMS_GPG_SIGNING_FINGERPRINT=0000000000000000000000000000000000000000 "$fixture/scripts/release-post-tag-selector.sh" "$scratch/assets"
mkdir "$fixture/in-repo-home"
fail env CANONPRIMS_GPG_HOMEDIR="$fixture/in-repo-home" "$fixture/scripts/release-post-tag-selector.sh" "$scratch/assets"
echo '[ok] historical post-tag selector survives newer anchors and rejects mismatches'

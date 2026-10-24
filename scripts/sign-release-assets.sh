#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Sign both release checksum manifests with minisign and with OpenPGP.
# Usage: sign-release-assets.sh <tag> [dir]
#
# Environment variables (all required):
#   CANONPRIMS_MINISIGN_KEY  - Path to the minisign secret key
#   CANONPRIMS_PGP_KEY_ID    - The committed signing subkey followed by !
#   CANONPRIMS_GPG_HOMEDIR   - GPG home outside the repository
#
# Requires: minisign, gpg
set -euo pipefail

TAG=${1:?"usage: sign-release-assets.sh <tag> [dir]"}
DIR=${2:-dist/release}
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
source "$root/scripts/release-common.sh"
export CANONPRIMS_RELEASE_TAG="$TAG"
require_published_anchor "$DIR"
"$root/scripts/validate-release-assets.sh" "$DIR" checksummed
"$root/scripts/verify-checksums.sh" "$DIR"
"$root/scripts/verify-staged-public.sh" "$DIR"
# Both signatures are required; the PGP selector must be the released subkey.
[[ -n "${CANONPRIMS_PGP_KEY_ID:-}" && -n "${CANONPRIMS_GPG_HOMEDIR:-}" ]] || {
    echo 'error: CANONPRIMS_PGP_KEY_ID and CANONPRIMS_GPG_HOMEDIR are required' >&2
    exit 1
}
"$root/scripts/release-post-tag-selector.sh" "$DIR"

if [ ! -d "$DIR" ]; then
    echo "Error: Directory $DIR does not exist"
    exit 1
fi

if [ -z "${CANONPRIMS_MINISIGN_KEY:-}" ]; then
    echo "Error: CANONPRIMS_MINISIGN_KEY environment variable not set"
    echo "Load the secure release-signing environment and retry."
    exit 1
fi

if [ ! -f "$CANONPRIMS_MINISIGN_KEY" ]; then
    echo "Error: Configured minisign key is not a readable file"
    exit 1
fi

cd "$DIR"

# Never write through a link: each signature is created, not followed.
for manifest in SHA256SUMS SHA512SUMS; do
    for signature in "$manifest.minisig" "$manifest.asc"; do
        if [ -e "$signature" ] || [ -L "$signature" ]; then
            echo "error: $signature already exists" >&2
            exit 1
        fi
    done
done

MISSING=0
for manifest in SHA256SUMS SHA512SUMS; do
    if [ ! -f "$manifest" ]; then
        echo "Error: $manifest not found in $DIR"
        MISSING=$((MISSING + 1))
    fi
done
if [ $MISSING -gt 0 ]; then
    echo ""
    echo "Did you forget to run checksums first?"
    echo "  make release-checksums"
    exit 1
fi

echo "Signing release $TAG..."

echo ""
echo "=== Minisign Signatures ==="

for manifest in SHA256SUMS SHA512SUMS; do
    if [ -f "$manifest" ]; then
        echo "Signing $manifest with minisign..."
        minisign -S -s "$CANONPRIMS_MINISIGN_KEY" \
            -m "$manifest" \
            -t "canonprims $TAG - $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            -x "${manifest}.minisig"
        echo "[ok] Created ${manifest}.minisig"
    fi
done

echo ""
echo "=== PGP Signatures ==="

for manifest in SHA256SUMS SHA512SUMS; do
    echo "Signing $manifest with PGP..."
    gpg --homedir "$CANONPRIMS_GPG_HOMEDIR" \
        --armor \
        --detach-sign \
        --local-user "$CANONPRIMS_PGP_KEY_ID" \
        --output "${manifest}.asc" \
        "$manifest"
    echo "[ok] Created ${manifest}.asc"
done

echo ""
echo "[ok] Signing complete"
ls -la ./*.minisig ./*.asc 2>/dev/null || true

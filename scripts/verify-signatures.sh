#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Verify both required signatures on both checksum manifests
# Usage: verify-signatures.sh [dir]
#
# Each manifest needs a minisign signature by the staged public key and an
# OpenPGP signature by the committed signing subkey; a missing one fails.
set -euo pipefail

DIR=${1:-dist/release}

if [ ! -d "$DIR" ]; then
    echo "Error: Directory $DIR does not exist"
    exit 1
fi

for manifest in SHA256SUMS SHA512SUMS; do
    [[ -s "$DIR/$manifest" && -s "$DIR/$manifest.minisig" && ! -L "$DIR/$manifest" && ! -L "$DIR/$manifest.minisig" ]] || {
        echo 'error: required signature or manifest missing' >&2
        exit 1
    }
done
cd "$DIR"

echo "Verifying signatures in $DIR..."

ERRORS=0

echo ""
echo "=== Minisign Verification ==="

if [ -f "canonprims-minisign.pub" ]; then
    for manifest in SHA256SUMS SHA512SUMS; do
        if [ -f "$manifest" ] && [ -f "${manifest}.minisig" ]; then
            echo "Verifying $manifest..."
            if minisign -Vm "$manifest" -p canonprims-minisign.pub; then
                echo "[ok] $manifest signature valid"
            else
                echo "[!!] $manifest signature INVALID"
                ERRORS=$((ERRORS + 1))
            fi
        elif [ -f "$manifest" ]; then
            echo "[!!] Missing signature: ${manifest}.minisig"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    echo "[!!] canonprims-minisign.pub not found - cannot verify minisign signatures"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== PGP Verification ==="

# Each manifest must carry an OpenPGP signature made by the one signing subkey
# in the staged public export (the export holds exactly the primary and that
# subkey; the staged material is bound to the tagged commit by
# verify-staged-public.sh). A signature by any other key, including the
# primary, is refused.
if [ -f "canonprims-release-signing-key.asc" ] && [ -f expected-fingerprints.txt ]; then
    GNUPGHOME=$(mktemp -d)
    export GNUPGHOME
    trap 'gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"' EXIT
    gpg --batch --quiet --import canonprims-release-signing-key.asc 2>/dev/null
    primary="$(awk '$1=="gpg" {print $2}' expected-fingerprints.txt)"
    listing="$(gpg --batch --with-colons --with-subkey-fingerprint --list-keys 2>/dev/null)"
    subkey="$(awk -F: '$1=="sub" && $12 ~ /s/ {s=1; next} s && $1=="fpr" {print $10; s=0}' <<<"$listing")"
    if [[ ! "$primary" =~ ^[0-9A-F]{40}$ || ! "$subkey" =~ ^[0-9A-F]{40}$ || "$(wc -l <<<"$subkey" | tr -d ' ')" != 1 ]]; then
        echo "[!!] staged public export does not hold exactly one signing subkey of the anchored primary"
        ERRORS=$((ERRORS + 1))
    else
        for manifest in SHA256SUMS SHA512SUMS; do
            if [ ! -f "${manifest}.asc" ] || [ -L "${manifest}.asc" ]; then
                echo "[!!] Missing signature: ${manifest}.asc"
                ERRORS=$((ERRORS + 1))
                continue
            fi
            echo "Verifying $manifest PGP signature..."
            if gpg --batch --status-fd 1 --verify "${manifest}.asc" "$manifest" 2>/dev/null |
                awk -v primary="$primary" -v subkey="$subkey" '
                    $1=="[GNUPG:]" && $2=="VALIDSIG" {valid++; signer=$3; signer_primary=$NF}
                    $1=="[GNUPG:]" && $2=="GOODSIG" {good++}
                    $1=="[GNUPG:]" && $2 ~ /^(EXPKEYSIG|EXPSIG|REVKEYSIG|KEYREVOKED|BADSIG|ERRSIG)$/ {bad++}
                    END {exit !(valid == 1 && good == 1 && !bad && signer == subkey && signer_primary == primary)}'; then
                echo "[ok] $manifest PGP signature valid (signing subkey $subkey)"
            else
                echo "[!!] $manifest PGP signature INVALID or not by the committed signing subkey"
                ERRORS=$((ERRORS + 1))
            fi
        done
    fi
else
    echo "[!!] canonprims-release-signing-key.asc and expected-fingerprints.txt are required"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "[ok] All signatures verified"
    exit 0
else
    echo "[!!] $ERRORS signature verification errors"
    exit 1
fi

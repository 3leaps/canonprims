#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Verify that exported keys contain only public material (no secrets)
# Usage: verify-public-keys.sh [dir]
#
# Critical safety check before uploading to GitHub
set -euo pipefail

DIR=${1:-dist/release}

if [ ! -d "$DIR" ]; then
	echo "Error: Directory $DIR does not exist"
	exit 1
fi

cd "$DIR"

echo "Verifying public keys contain no secret material..."

ERRORS=0

# Check minisign public key
echo ""
echo "=== Minisign Key Check ==="

if [ -f "canonprims-minisign.pub" ]; then
	# Minisign public keys start with "untrusted comment:" and contain base64 data
	# They should NOT contain "SECRET KEY" or similar
	if grep -qi "secret" "canonprims-minisign.pub"; then
		echo "[!!] DANGER: canonprims-minisign.pub may contain secret key material!"
		ERRORS=$((ERRORS + 1))
	elif grep -q "^untrusted comment:" "canonprims-minisign.pub"; then
		echo "[ok] canonprims-minisign.pub appears to be a valid public key"
	else
		echo "[!!] canonprims-minisign.pub has unexpected format"
		ERRORS=$((ERRORS + 1))
	fi
else
	echo "[!!] canonprims-minisign.pub not found"
	ERRORS=$((ERRORS + 1))
fi

# Check PGP public key
echo ""
echo "=== PGP Key Check ==="

if [ -f "canonprims-release-signing-key.asc" ]; then
	# PGP public keys should have "PUBLIC KEY BLOCK" not "PRIVATE KEY BLOCK"
	if grep -q "PRIVATE KEY BLOCK" "canonprims-release-signing-key.asc"; then
		echo "[!!] DANGER: canonprims-release-signing-key.asc contains PRIVATE KEY!"
		ERRORS=$((ERRORS + 1))
	elif grep -q "PUBLIC KEY BLOCK" "canonprims-release-signing-key.asc"; then
		echo "[ok] canonprims-release-signing-key.asc is a public key"

		# Verify it can be imported and show key info
		GNUPGHOME=$(mktemp -d)
		export GNUPGHOME
		trap 'rm -rf "$GNUPGHOME"' EXIT

		if gpg --batch --import canonprims-release-signing-key.asc 2>/dev/null; then
			echo "Key info:"
			gpg --list-keys 2>/dev/null | grep -A1 "^pub" || true
		else
			echo "[!!] canonprims-release-signing-key.asc does not import"
			ERRORS=$((ERRORS + 1))
		fi
	else
		echo "[!!] canonprims-release-signing-key.asc has unexpected format"
		ERRORS=$((ERRORS + 1))
	fi
else
	echo "[!!] canonprims-release-signing-key.asc not found"
	ERRORS=$((ERRORS + 1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
	echo "[ok] Public key verification passed"
	exit 0
else
	echo "[!!] CRITICAL: $ERRORS public key check(s) failed!"
	echo "DO NOT upload these files to GitHub!"
	exit 1
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# content-check refuses each shape in a tracked file, accepts synthetic fixture
# homes, and reads tracked files only. Fixtures are built from fragments at run
# time, so this file never holds a whole token or path.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
git init -q "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
check() { python3 -I "$root/scripts/content-check.py" "$repo" >"$scratch/out" 2>&1; }
plant() {
	printf '%s\n' "$1" >"$repo/f.txt"
	git -C "$repo" add -A
}
refused() {
	local reason="$1" text="$2"
	plant "$text"
	if check; then echo "error: accepted: $reason" >&2; exit 1; fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason'" >&2; cat "$scratch/out" >&2; exit 1; }
}
accepted() {
	plant "$1"
	check || { echo "error: refused: $1" >&2; cat "$scratch/out" >&2; exit 1; }
}
u='Us''ers' h='ho''me' name='jd''oe'
refused 'home directory' "see /$u/$name/projects/x"
refused 'home directory' "log /$h/$name/build"
refused 'Windows user profile' "C:\\$u\\$name\\code"
refused 'Windows user profile' "d:/$u/$name/code"
refused 'private key block' "-----BEGIN OPEN""SSH PRIVATE KEY-----"
refused 'private key block' "-----BEGIN PRIVATE"" KEY-----"
refused 'GitHub token' "token gh""p_$(printf 'A%.0s' $(seq 1 24))"
refused 'GitHub token' "token github""_pat_$(printf 'b%.0s' $(seq 1 30))"
refused 'AWS access key' "key AK""IA$(printf 'Q%.0s' $(seq 1 16))"
refused 'remove-before-commit marker' "x = 'DO_NOT""_COMMIT'"
# Synthetic fixture homes, CI runners and URLs are not local paths.
accepted "fixture /$h/someone/x and C:/$u/someone/y"
accepted "ci /$h/runner/work and C:\\$u\\runneradmin\\x"
accepted "url https://example.com/$u/$name/"
accepted "token ghp_short"
accepted 'plain text'
# Only tracked files are read: an untracked or ignored file is not.
plant 'clean'
printf 'see /%s/%s/x\n' "$u" "$name" >"$repo/untracked.txt"
check || { echo 'error: read an untracked file' >&2; cat "$scratch/out" >&2; exit 1; }
# The real tree is clean.
python3 -I "$root/scripts/content-check.py" "$root" >/dev/null
echo '[ok] content-check: home paths, Windows profiles, private keys, GitHub and AWS tokens, commit markers; synthetic homes and untracked files pass'

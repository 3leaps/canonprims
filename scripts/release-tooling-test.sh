#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Synthetic release-tooling controls: throwaway keys, local fixtures and mocked
# remote state only, no operator keyring and no credentials. The only network
# access is the crate publication test's Cargo, which reads the public
# crates.io index and dependency sources (unauthenticated) and uploads to a
# local test registry. Needs gpg, minisign, git, jq, cargo with the MSRV
# toolchain, python3 >= 3.11 and decernor >= 0.1.8 (CANONPRIMS_DECERNOR_BIN, or
# decernor on PATH for tests).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# Test imports must not leave bytecode in the source tree.
export PYTHONDONTWRITEBYTECODE=1
cd "$root"
# Every *.test.sh in scripts/ runs, and the set must equal
# config/release/tooling-suites.txt: adding or deleting a suite is a reviewed
# change to that list.
suites=()
while IFS= read -r -d '' file; do suites+=("$file"); done < <(find "$root/scripts" -maxdepth 1 -name '*.test.sh' -print0 | LC_ALL=C sort -z)
found="$(for file in "${suites[@]}"; do basename "$file" .test.sh; done | LC_ALL=C sort)"
[[ "$found" == "$(cat "$root/config/release/tooling-suites.txt")" ]] || {
	echo 'error: release tooling suites differ from config/release/tooling-suites.txt' >&2
	diff <(cat "$root/config/release/tooling-suites.txt") <(printf '%s\n' "$found") >&2 || true
	exit 1
}
for suite in "${suites[@]}"; do
	echo "== $(basename "$suite" .test.sh)"
	"$suite"
done
stray="$(find "$root/scripts" -name __pycache__ -o -name '*.pyc')"
[[ -z "$stray" ]] || {
	echo "error: Python bytecode written into the source tree: $stray" >&2
	exit 1
}
echo '[ok] release tooling controls passed'

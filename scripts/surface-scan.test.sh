#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# surface-scan.sh enforces its gate against a synthetic catalog built here at
# run time (invented terms, not the maintainer's): a term in the tree, a commit
# message, the PR text or the branch name fails; the catalog must block its own
# canary; a scanner error or a bad report fails closed and visibly; the catalog
# path rules hold. Needs limensafe; without it this suite is skipped (the scan
# is a maintainer gate and never runs in CI).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="${CANONPRIMS_LIMENSAFE_BIN:-$(command -v limensafe || true)}"
if [[ -z "$bin" || ! -x "$bin" ]]; then
	echo '[skip] surface-scan controls: limensafe is not installed'
	exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unset LIMENSAFE_CATALOG_PATH CANONPRIMS_SURFACE_PR_TEXT CANONPRIMS_SURFACE_SCAN_REQUIRED CANONPRIMS_SURFACE_SCOPE
# Invented terms, split so this file never holds them whole.
term="zq""lantern" canary="canp-test-canary-""7f3e19a2"
printf '%s==>Codename\n%s==>CanonprimsCanary\n' "$term" "$canary" >"$scratch/terms.txt"
"$bin" catalog build --from-termlist "$scratch/terms.txt" --out "$scratch/catalog.yaml" \
	--catalog-id canonprims-release >/dev/null 2>&1
printf '%s==>Codename\n' "$term" >"$scratch/nocanary.txt"
"$bin" catalog build --from-termlist "$scratch/nocanary.txt" --out "$scratch/nocanary.yaml" \
	--catalog-id canonprims-release >/dev/null 2>&1
printf '%s==>Codename\n%s==>CanonprimsCanary\n' "$term" "$canary" >"$scratch/otherid.txt"
"$bin" catalog build --from-termlist "$scratch/otherid.txt" --out "$scratch/otherid.yaml" \
	--catalog-id some-other-catalog >/dev/null 2>&1

# A small repository carrying the scan scripts, with origin/main as a base.
repo="$scratch/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
mkdir -p "$repo/scripts"
cp "$root/scripts/surface-scan.sh" "$root/scripts/surface-canary.py" "$repo/scripts/"
printf 'clean\n' >"$repo/README"
git -C "$repo" add -A
git -C "$repo" commit -qm 'clean base'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" switch -q -c feature

scan() { (cd "$repo" && env CANONPRIMS_LIMENSAFE_BIN="$bin" "$@" scripts/surface-scan.sh) >"$scratch/out" 2>&1; }
passes() { scan "$@" || { echo "error: refused: $*" >&2; cat "$scratch/out" >&2; exit 1; }; }
refused() {
	local reason="$1"
	shift
	if scan "$@"; then echo "error: accepted, expected: $reason" >&2; cat "$scratch/out" >&2; exit 1; fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason'" >&2; cat "$scratch/out" >&2; exit 1; }
}
cat_ok=(LIMENSAFE_CATALOG_PATH="$scratch/catalog.yaml")

passes "${cat_ok[@]}"
grep -q '\[ok\] catalog blocks its canary' "$scratch/out"
# Unset catalog: skip, unless required.
passes env -u LIMENSAFE_CATALOG_PATH
grep -q '\[skip\] surface scan' "$scratch/out"
refused 'LIMENSAFE_CATALOG_PATH is required' CANONPRIMS_SURFACE_SCAN_REQUIRED=1
# Invalid catalog paths fail hard.
refused 'set but empty' LIMENSAFE_CATALOG_PATH=
refused 'must be an absolute path' LIMENSAFE_CATALOG_PATH=catalog.yaml
refused 'does not name a readable file' LIMENSAFE_CATALOG_PATH="$scratch/absent.yaml"
cp "$scratch/catalog.yaml" "$repo/inside.yaml"
refused 'outside this repository' LIMENSAFE_CATALOG_PATH="$repo/inside.yaml"
ln -s "$repo" "$scratch/repo-link"
refused 'outside this repository' LIMENSAFE_CATALOG_PATH="$scratch/repo-link/inside.yaml"
ln -s "$repo/inside.yaml" "$scratch/outside-link.yaml"
refused 'outside this repository' LIMENSAFE_CATALOG_PATH="$scratch/outside-link.yaml"
rm -f "$repo/inside.yaml"
git -C "$repo" worktree add -q --detach "$scratch/wt" HEAD
cp "$scratch/catalog.yaml" "$scratch/wt/inside.yaml"
refused 'outside this repository' LIMENSAFE_CATALOG_PATH="$scratch/wt/inside.yaml"
git -C "$repo" worktree remove --force "$scratch/wt"
# The catalog must be the right one and block its own canary.
refused 'no usable canary' LIMENSAFE_CATALOG_PATH="$scratch/nocanary.yaml"
refused 'did not load' LIMENSAFE_CATALOG_PATH="$scratch/otherid.yaml"
# Scanner errors fail closed and say so, on stderr that is never hidden.
printf '#!/bin/sh\necho boom >&2\nexit 7\n' >"$scratch/broken"
chmod +x "$scratch/broken"
refused 'limensafe exited 7' "${cat_ok[@]}" CANONPRIMS_LIMENSAFE_BIN="$scratch/broken"
printf '#!/bin/sh\nexit 0\n' >"$scratch/silent"
chmod +x "$scratch/silent"
refused 'report is missing or invalid' "${cat_ok[@]}" CANONPRIMS_LIMENSAFE_BIN="$scratch/silent"
# The canary block must be the canary entity's own: a block under another
# replacement id does not prove the catalog's canary works.
printf '#!/bin/sh\nprintf %%s '"'"'{"scan_metadata":{"catalogs_loaded":[{"catalog_id":"canonprims-release","load_status":"ok"}]},"summary":{"findings_total":1},"findings":[{"decision":"block","replacement_id":"Codename","severity":"high"}]}'"'"'\nexit 1\n' >"$scratch/wrongblock"
chmod +x "$scratch/wrongblock"
refused 'not blocked as CanonprimsCanary' "${cat_ok[@]}" CANONPRIMS_LIMENSAFE_BIN="$scratch/wrongblock"
# A scanner that works for the canary and the tree, then writes nothing for a
# commit message, fails on the empty report rather than passing.
cat >"$scratch/flaky" <<SH
#!/bin/sh
count_file="$scratch/flaky.count"
n=\$(cat "\$count_file" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"\$count_file"
[ "\$n" -le 2 ] && exec "$bin" "\$@"
exit 0
SH
chmod +x "$scratch/flaky"
printf 'more\n' >"$repo/more.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'a clean commit message'
rm -f "$scratch/flaky.count"
refused 'commit .*: limensafe report is missing or invalid' "${cat_ok[@]}" CANONPRIMS_LIMENSAFE_BIN="$scratch/flaky"
git -C "$repo" reset -q --hard HEAD~1
# A scanner that reports clean on a canary it should block is caught.
printf '#!/bin/sh\nprintf %s '"'"'{"scan_metadata":{"catalogs_loaded":[{"catalog_id":"canonprims-release","load_status":"ok"}]},"summary":{"findings_total":0},"findings":[]}'"'"'\nexit 0\n' >"$scratch/blind"
chmod +x "$scratch/blind"
refused 'did not block its canary' "${cat_ok[@]}" CANONPRIMS_LIMENSAFE_BIN="$scratch/blind"
# A term in each surface fails.
printf 'notes %s\n' "$term" >"$repo/notes.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'add notes'
refused '\[block\] tree' "${cat_ok[@]}"
git -C "$repo" reset -q --hard HEAD~1
printf 'more\n' >"$repo/more.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm "mention $term"
refused '\[block\] commit' "${cat_ok[@]}"
git -C "$repo" reset -q --hard HEAD~1
printf 'Title\n\nBody about %s\n' "$term" >"$scratch/pr.md"
refused '\[block\] pr text' "${cat_ok[@]}" CANONPRIMS_SURFACE_PR_TEXT="$scratch/pr.md"
printf 'Title\n\nclean body\n' >"$scratch/pr-clean.md"
passes "${cat_ok[@]}" CANONPRIMS_SURFACE_PR_TEXT="$scratch/pr-clean.md"
grep -q 'pr text' "$scratch/out"
: >"$scratch/pr-empty.md"
refused 'non-empty file' "${cat_ok[@]}" CANONPRIMS_SURFACE_PR_TEXT="$scratch/pr-empty.md"
git -C "$repo" switch -q -c "topic-$term"
refused '\[block\] branch name' "${cat_ok[@]}"
git -C "$repo" switch -q feature
# A missing base is an error, not an empty commit range.
refused 'base no-such-ref not found' "${cat_ok[@]}" CANONPRIMS_SURFACE_BASE=no-such-ref
echo '[ok] surface-scan: catalog rules, canary, scanner errors, and each surface (tree, commits, pr text, branch)'

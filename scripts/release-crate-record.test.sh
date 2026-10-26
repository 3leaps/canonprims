#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The verification record check: a matching record and archive pass; a record
# or archive that is a link or not a regular file is refused, as is any field
# or digest that differs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
printf 'archive bytes' >"$scratch/a.crate"
digest="$(shasum -a 256 "$scratch/a.crate" | cut -c1-64)"
o=1111111111111111111111111111111111111111 c=2222222222222222222222222222222222222222
python3 -I - "$scratch/r.json" "$digest" "$o" "$c" <<'PY'
import json, sys
json.dump({"format": "canonprims-crate-verification/v0", "repository": "3leaps/canonprims", "tag": "v1.2.3",
           "object": sys.argv[3], "commit": sys.argv[4], "crate": "canonprims-core",
           "version": "1.2.3", "cargo": "cargo 1.88.0", "registry": "crates-io", "sha256": sys.argv[2],
           "run_id": "7", "run_attempt": "1"}, open(sys.argv[1], "w"))
PY
check() {
	python3 -I "$root/scripts/release-crate-record.py" check "$1" "$2" --tag v1.2.3 --object "$o" \
		--commit "$c" --crate canonprims-core --version 1.2.3 --registry crates-io >"$scratch/out" 2>&1
}
check "$scratch/r.json" "$scratch/a.crate"
[[ "$(cat "$scratch/out")" == "$digest" ]]
refused() {
	local reason="$1"
	shift
	if check "$@"; then
		echo "error: accepted: $*" >&2
		exit 1
	fi
	grep -q -- "$reason" "$scratch/out" || { echo "error: refused for another reason than '$reason'" >&2; cat "$scratch/out" >&2; exit 1; }
}
ln -s "$scratch/r.json" "$scratch/r-link.json"
ln -s "$scratch/a.crate" "$scratch/a-link.crate"
mkfifo "$scratch/fifo"
refused 'must be regular files, not links' "$scratch/r-link.json" "$scratch/a.crate"
refused 'must be regular files, not links' "$scratch/r.json" "$scratch/a-link.crate"
# Hold the FIFO's write end open and closed at once, so a checker that opened
# it would read end-of-file and fail rather than block.
(exec 3>"$scratch/fifo"; sleep 2) &
writer=$!
refused 'must be regular files, not links' "$scratch/r.json" "$scratch/fifo"
kill "$writer" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
cp "$scratch/a.crate" "$scratch/b.crate"
printf 'x' >>"$scratch/b.crate"
refused 'does not have the recorded digest' "$scratch/r.json" "$scratch/b.crate"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["commit"]="0"*40; json.dump(r,open(sys.argv[2],"w"))' "$scratch/r.json" "$scratch/r2.json"
refused 'commit differs from this release' "$scratch/r2.json" "$scratch/a.crate"
# A record from the two-tag layout (an extra module_object field) is malformed.
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); r["module_object"]=r["object"]; json.dump(r,open(sys.argv[2],"w"))' "$scratch/r.json" "$scratch/r3.json"
refused 'malformed crate verification record' "$scratch/r3.json" "$scratch/a.crate"
echo '[ok] crate verification record: identity, digest, and regular-file inputs'

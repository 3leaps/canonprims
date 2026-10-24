#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The sparse-index reader: listed (0), absent (1), yanked (3), and every other
# outcome, including malformed rows, an error (2) that is never read as absent.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
python3 -u -m http.server -d "$scratch" -b 127.0.0.1 0 >"$scratch/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; rm -rf "$scratch"' EXIT
for _ in $(seq 1 50); do grep -q 'Serving HTTP' "$scratch/server.log" && break; sleep 0.1; done
[[ -n "$(sed -n "s/.*port \([0-9]*\).*/\1/p" "$scratch/server.log")" ]] || { echo "error: test server did not start" >&2; exit 1; }
port="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$scratch/server.log" | head -1)"
base="sparse+http://127.0.0.1:$port/"
mkdir -p "$scratch/ab/cd" "$scratch/3/a" "$scratch/2" "$scratch/1"
expect() {
	local want="$1" name="$2" body="$3" got=0
	printf '%s\n' "$body" >"$scratch/ab/cd/abcdef"
	python3 -I "$root/scripts/release-index-entry.py" "$base" "$name" 1.0.0 >"$scratch/out" 2>/dev/null || got=$?
	[[ "$got" == "$want" ]] || { echo "error: $body -> exit $got, expected $want" >&2; exit 1; }
}
digest="$(printf '%064d' 7)"
expect 0 abcdef "{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$digest\"}"
[[ "$(cat "$scratch/out")" == "$digest" ]]
expect 0 ABCDEF "{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$digest\"}"
expect 1 abcdef "{\"name\":\"abcdef\",\"vers\":\"0.9.0\",\"cksum\":\"$digest\"}"
expect 3 abcdef "{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$digest\",\"yanked\":true}"
expect 1 abcdefg "{}"
# The last line for a version wins, as in Cargo: a later yank or edit applies.
live="{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$digest\"}"
other="$(printf '%064d' 9)"
expect 3 abcdef "$live
{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$digest\",\"yanked\":true}"
expect 0 abcdef "$live
{\"name\":\"abcdef\",\"vers\":\"1.0.0\",\"cksum\":\"$other\"}"
[[ "$(cat "$scratch/out")" == "$other" ]]
for body in '[]' 'null' '7' '{"name":5,"vers":"1.0.0"}' '{"name":"abcdef","vers":1}' \
	'{"name":"abcdef","vers":"1.0.0","cksum":7}' '{"name":"abcdef","vers":"1.0.0"}' 'not json'; do
	expect 2 abcdef "$body"
done
# Short-name index paths.
printf '{"name":"abc","vers":"1.0.0","cksum":"%s"}\n' "$digest" >"$scratch/3/a/abc"
printf '{"name":"ab","vers":"1.0.0","cksum":"%s"}\n' "$digest" >"$scratch/2/ab"
printf '{"name":"a","vers":"1.0.0","cksum":"%s"}\n' "$digest" >"$scratch/1/a"
for name in a ab abc; do
	python3 -I "$root/scripts/release-index-entry.py" "$base" "$name" 1.0.0 >/dev/null
done
# No server: an error, not absent.
rc=0
python3 -I "$root/scripts/release-index-entry.py" "http://127.0.0.1:9/" abcdef 1.0.0 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]]
echo '[ok] sparse-index reader: listed, absent, yanked and malformed rows'

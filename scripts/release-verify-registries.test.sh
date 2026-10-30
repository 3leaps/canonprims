#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Synthetic controls for scripts/release-verify-registries.py and
# scripts/pack-npm-redirector.sh against a loopback HTTP server.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
mkdir -p "$scratch/http" "$scratch/stage"
python3 -u -m http.server -d "$scratch/http" -b 127.0.0.1 0 >"$scratch/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; rm -rf "$scratch"' EXIT
for _ in $(seq 1 50); do grep -q 'Serving HTTP' "$scratch/server.log" && break; sleep 0.1; done
port="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$scratch/server.log" | head -1)"
[[ -n "$port" ]] || { echo "error: test server did not start" >&2; exit 1; }

version="0.1.2"
stage="$scratch/stage"
pypi_base="http://127.0.0.1:$port/pypi"
npm_base="http://127.0.0.1:$port/npm"

python3 -I - "$stage" "$scratch/http" "$version" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
http = pathlib.Path(sys.argv[2])
version = sys.argv[3]

tags = (
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "macosx_11_0_arm64",
    "win_amd64",
    "win_arm64",
)
sha256_lines = []
sha512_lines = []
urls = []
for i, tag in enumerate(tags):
    name = f"canonprims-{version}-cp310-abi3-{tag}.whl"
    data = f"wheel-{i}-{tag}\n".encode("utf-8")
    (stage / name).write_bytes(data)
    d256 = hashlib.sha256(data).hexdigest()
    d512 = hashlib.sha512(data).hexdigest()
    sha256_lines.append(f"{d256}  {name}")
    sha512_lines.append(f"{d512}  {name}")
    urls.append({"filename": name, "yanked": False, "digests": {"sha256": d256}})

tgz_name = f"3leaps-canonprims-{version}.tgz"
tgz_data = b"npm-tarball-bytes\n"
(stage / tgz_name).write_bytes(tgz_data)
sha256_lines.append(f"{hashlib.sha256(tgz_data).hexdigest()}  {tgz_name}")
sha512_lines.append(f"{hashlib.sha512(tgz_data).hexdigest()}  {tgz_name}")

(stage / "SHA256SUMS").write_text("\n".join(sorted(sha256_lines)) + "\n", encoding="utf-8")
(stage / "SHA512SUMS").write_text("\n".join(sorted(sha512_lines)) + "\n", encoding="utf-8")

pypi_ver = http / "pypi" / "canonprims" / version
pypi_ver.mkdir(parents=True, exist_ok=True)
pypi_doc = {
    "info": {"name": "canonprims", "version": version},
    "ownership": {"organization": "3leaps", "roles": []},
    "urls": urls,
}
(pypi_ver / "json").write_text(json.dumps(pypi_doc), encoding="utf-8")
(http / "pypi" / "canonprims" / "json").write_text(json.dumps(pypi_doc), encoding="utf-8")

npm_dir = http / "npm" / "@3leaps" / "canonprims"
npm_dir.mkdir(parents=True, exist_ok=True)
integrity = "sha512-" + base64.b64encode(hashlib.sha512(tgz_data).digest()).decode("ascii")
shasum = hashlib.sha1(tgz_data).hexdigest()
npm_doc = {
    "name": "@3leaps/canonprims",
    "version": version,
    "dist": {"integrity": integrity, "shasum": shasum},
}
(npm_dir / version).write_text(json.dumps(npm_doc), encoding="utf-8")
PY

cp "$scratch/http/pypi/canonprims/$version/json" "$scratch/pypi.pristine.json"
cp "$scratch/http/npm/@3leaps/canonprims/$version" "$scratch/npm.pristine.json"

run_verify() {
	CANONPRIMS_PYPI_API_URL="$pypi_base" \
		CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
		CANONPRIMS_REGISTRY_POLL_ATTEMPTS=2 \
		CANONPRIMS_REGISTRY_POLL_SLEEP=0.05 \
		python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" "${1:-all}" >"$scratch/out" 2>&1
}

refused() {
	local scope="$1" pattern="$2"
	if run_verify "$scope"; then
		echo "error: accepted, expected failure matching '$pattern'" >&2
		cat "$scratch/out" >&2
		exit 1
	fi
	grep -Eq -- "$pattern" "$scratch/out" || {
		echo "error: failed for unexpected reason (want '$pattern')" >&2
		cat "$scratch/out" >&2
		exit 1
	}
}

run_verify all
run_verify pypi
run_verify npm

# Ownership fallback to project-level /pypi/canonprims/json when version JSON is cached with organization=null.
jq '.ownership.organization = null' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
run_verify pypi
jq '.ownership.organization = null' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/json"
refused pypi "ownership organization must be '3leaps'"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/$version/json"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/json"

# Wrong wheel sha256, yanked wheel, missing wheel.
jq '.urls[0].digests.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
	"$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "PyPI sha256 mismatch"
jq '.urls[0].yanked = true' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "is yanked"
jq 'del(.urls[0])' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "PyPI wheel set differs"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/$version/json"

# Wrong npm dist.integrity and dist.shasum.
jq '.dist.integrity = "sha512-AAAA"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm dist.integrity mismatch"
jq '.dist.shasum = "0000000000000000000000000000000000000000"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm dist.shasum mismatch"
cp "$scratch/npm.pristine.json" "$scratch/http/npm/@3leaps/canonprims/$version"

# Bounded retry on HTTP 404 (e.g. npm async processing scan): missing initially, restored while polling.
rm -f "$scratch/http/npm/@3leaps/canonprims/$version"
(sleep 0.15 && cp "$scratch/npm.pristine.json" "$scratch/http/npm/@3leaps/canonprims/$version") &
CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
	CANONPRIMS_REGISTRY_POLL_ATTEMPTS=5 \
	CANONPRIMS_REGISTRY_POLL_SLEEP=0.1 \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" npm >/dev/null

# Under GITHUB_ACTIONS, API URL overrides are refused.
if GITHUB_ACTIONS=true CANONPRIMS_PYPI_API_URL="$pypi_base" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" pypi >"$scratch/out" 2>&1; then
	echo "error: accepted CANONPRIMS_PYPI_API_URL under GITHUB_ACTIONS" >&2
	exit 1
fi
grep -q "CANONPRIMS_PYPI_API_URL is not accepted under GitHub Actions" "$scratch/out"

if command -v npm >/dev/null 2>&1; then
	"$root/scripts/pack-npm-redirector.sh" "$scratch/redirector" "$version" >/dev/null
	[[ -s "$scratch/redirector/canonprims-$version.tgz" ]]
fi

echo '[ok] registry verification and bare-name redirector controls'

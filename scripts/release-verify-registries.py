#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Verify that PyPI and npm serve the exact signed release bytes.

Usage:
  release-verify-registries.py STAGE_DIR VERSION [all|pypi|npm]

STAGE_DIR holds SHA256SUMS, SHA512SUMS, the five cp310-abi3 wheels, and the
npm tarball (3leaps-canonprims-VERSION.tgz) as needed for the selected
registry scope. Both registries are polled with a bounded retry when HTTP 404
is returned immediately after upload (for example, while npm's async package
scan runs).
"""

import base64
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

WHEEL_TAGS = (
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "macosx_11_0_arm64",
    "win_amd64",
    "win_arm64",
)


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def read_manifest(path: pathlib.Path, width: int) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        fail(f"missing or unsafe manifest {path}")
    entries: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, sep, name = line.partition("  ")
        if not sep or not re.fullmatch(f"[0-9a-f]{{{width}}}", digest) or name in entries:
            fail(f"malformed or duplicate entry in {path.name}: {line!r}")
        entries[name] = digest
    return entries


def fetch_json_with_retry(url: str, label: str, attempts: int, sleep_sec: float) -> dict:
    last_err = ""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "canonprims-release-verify"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not isinstance(data, dict):
                    fail(f"{label} returned non-object JSON")
                return data
        except urllib.error.HTTPError as err:
            last_err = f"HTTP {err.code}"
            if err.code == 404 and attempt < attempts:
                time.sleep(sleep_sec)
                continue
            fail(f"{label} unavailable ({last_err}) at {url}")
        except (OSError, ValueError) as err:
            fail(f"{label} request failed at {url}: {err}")
    fail(f"{label} unavailable ({last_err}) at {url}")
    return {}


def verify_pypi(stage: pathlib.Path, version: str, sha256s: dict[str, str], attempts: int, sleep_sec: float) -> None:
    if os.environ.get("GITHUB_ACTIONS") and "CANONPRIMS_PYPI_API_URL" in os.environ:
        fail("CANONPRIMS_PYPI_API_URL is not accepted under GitHub Actions")
    base = os.environ.get("CANONPRIMS_PYPI_API_URL", "https://pypi.org/pypi").rstrip("/")
    if not base.startswith("https://") and not base.startswith("http://127.0.0.1:"):
        fail("PyPI API URL must use https (or loopback in synthetic tests)")

    expected_wheels = {f"canonprims-{version}-cp310-abi3-{tag}.whl" for tag in WHEEL_TAGS}
    for name in sorted(expected_wheels):
        if name not in sha256s:
            fail(f"SHA256SUMS missing {name}")
        wheel = stage / name
        if not wheel.is_file() or wheel.is_symlink():
            fail(f"staged wheel missing: {name}")
        if hashlib.sha256(wheel.read_bytes()).hexdigest() != sha256s[name]:
            fail(f"staged wheel sha256 mismatch for {name}")

    ver_doc = fetch_json_with_retry(f"{base}/canonprims/{version}/json", f"PyPI canonprims=={version}", attempts, sleep_sec)
    info = ver_doc.get("info") or {}
    if info.get("name") != "canonprims" or info.get("version") != version:
        fail(f"PyPI info mismatch: name={info.get('name')!r} version={info.get('version')!r}")

    ownership = ver_doc.get("ownership") or {}
    org = ownership.get("organization")
    if org != "3leaps":
        proj_doc = fetch_json_with_retry(f"{base}/canonprims/json", "PyPI canonprims project", attempts, sleep_sec)
        org = (proj_doc.get("ownership") or {}).get("organization")
    if org != "3leaps":
        fail(f"PyPI project ownership organization must be '3leaps', got {org!r}")

    urls = ver_doc.get("urls")
    if not isinstance(urls, list):
        fail("PyPI response missing urls list")
    published: dict[str, str] = {}
    for entry in urls:
        if not isinstance(entry, dict):
            fail("PyPI urls entry is not an object")
        filename = entry.get("filename")
        if not isinstance(filename, str) or filename in published:
            fail(f"invalid or duplicate PyPI filename {filename!r}")
        if entry.get("yanked"):
            fail(f"PyPI file {filename} is yanked")
        digest = (entry.get("digests") or {}).get("sha256")
        if not isinstance(digest, str):
            fail(f"PyPI file {filename} missing sha256 digest")
        published[filename] = digest

    if set(published) != expected_wheels:
        fail(f"PyPI wheel set differs: expected {sorted(expected_wheels)}, got {sorted(published)}")
    for name in sorted(expected_wheels):
        if published[name] != sha256s[name]:
            fail(f"PyPI sha256 mismatch for {name}: {published[name]} != {sha256s[name]}")
    print(f"[ok] PyPI canonprims=={version}: 5 wheels match signed SHA256SUMS (org: 3leaps)")


def verify_npm(stage: pathlib.Path, version: str, sha256s: dict[str, str], sha512s: dict[str, str], attempts: int, sleep_sec: float) -> None:
    if os.environ.get("GITHUB_ACTIONS") and "CANONPRIMS_NPM_REGISTRY_URL" in os.environ:
        fail("CANONPRIMS_NPM_REGISTRY_URL is not accepted under GitHub Actions")
    base = os.environ.get("CANONPRIMS_NPM_REGISTRY_URL", "https://registry.npmjs.org").rstrip("/")
    if not base.startswith("https://") and not base.startswith("http://127.0.0.1:"):
        fail("npm registry URL must use https (or loopback in synthetic tests)")

    tgz_name = f"3leaps-canonprims-{version}.tgz"
    if tgz_name not in sha256s or tgz_name not in sha512s:
        fail(f"checksum manifests missing {tgz_name}")
    tgz = stage / tgz_name
    if not tgz.is_file() or tgz.is_symlink():
        fail(f"staged npm tarball missing: {tgz_name}")
    raw = tgz.read_bytes()
    if hashlib.sha256(raw).hexdigest() != sha256s[tgz_name]:
        fail(f"staged tarball sha256 mismatch for {tgz_name}")
    if hashlib.sha512(raw).hexdigest() != sha512s[tgz_name]:
        fail(f"staged tarball sha512 mismatch for {tgz_name}")

    want_integrity = "sha512-" + base64.b64encode(hashlib.sha512(raw).digest()).decode("ascii")
    want_shasum = hashlib.sha1(raw).hexdigest()

    doc = fetch_json_with_retry(
        f"{base}/%403leaps%2Fcanonprims/{version}",
        f"npm @3leaps/canonprims@{version}",
        attempts,
        sleep_sec,
    )
    if doc.get("name") != "@3leaps/canonprims" or doc.get("version") != version:
        fail(f"npm metadata mismatch: name={doc.get('name')!r} version={doc.get('version')!r}")
    dist = doc.get("dist") or {}
    if dist.get("integrity") != want_integrity:
        fail(f"npm dist.integrity mismatch: {dist.get('integrity')!r} != {want_integrity!r}")
    if dist.get("shasum") != want_shasum:
        fail(f"npm dist.shasum mismatch: {dist.get('shasum')!r} != {want_shasum!r}")
    print(f"[ok] npm @3leaps/canonprims@{version}: dist.integrity and shasum match signed {tgz_name}")


def main() -> None:
    if len(sys.argv) not in (3, 4):
        fail("usage: release-verify-registries.py STAGE_DIR VERSION [all|pypi|npm]")
    stage = pathlib.Path(sys.argv[1])
    version = sys.argv[2]
    scope = sys.argv[3] if len(sys.argv) == 4 else "all"
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        fail(f"invalid semantic version {version!r}")
    if scope not in ("all", "pypi", "npm"):
        fail(f"unknown registry scope {scope!r} (all, pypi, or npm)")

    attempts = int(os.environ.get("CANONPRIMS_REGISTRY_POLL_ATTEMPTS", "12"))
    sleep_sec = float(os.environ.get("CANONPRIMS_REGISTRY_POLL_SLEEP", "10"))
    if attempts < 1 or sleep_sec < 0:
        fail("invalid poll settings")

    sha256s = read_manifest(stage / "SHA256SUMS", 64)
    sha512s = read_manifest(stage / "SHA512SUMS", 128)
    if scope in ("all", "pypi"):
        verify_pypi(stage, version, sha256s, attempts, sleep_sec)
    if scope in ("all", "npm"):
        verify_npm(stage, version, sha256s, sha512s, attempts, sleep_sec)


if __name__ == "__main__":
    main()

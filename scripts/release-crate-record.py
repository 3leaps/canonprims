#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check a CI crate verification record against the release it is used for.

Usage: release-crate-record.py check RECORD ARCHIVE --tag T --object O
           --module-object M --commit C --crate N --version V --registry R
Prints the verified SHA-256 when the record names this repository, both tag
objects, the commit, the crate, the version and crates.io, and ARCHIVE has
that digest.
"""

import hashlib
import json
import os
import re
import sys

KEYS = {"format", "repository", "tag", "object", "module_object", "commit", "crate", "version",
        "cargo", "registry", "sha256", "run_id", "run_attempt"}


def fail(reason):
    raise ValueError(reason)


def main():
    args = sys.argv[1:]
    if len(args) != 17 or args[0] != "check":
        fail("usage: release-crate-record.py check RECORD ARCHIVE --tag T --object O --module-object M --commit C --crate N --version V --registry R")
    record_path, archive_path = args[1], args[2]
    options = dict(zip(args[3::2], args[4::2]))
    expected = {"tag": options.get("--tag"), "object": options.get("--object"),
                "module_object": options.get("--module-object"), "commit": options.get("--commit"),
                "crate": options.get("--crate"), "version": options.get("--version"),
                "registry": options.get("--registry")}
    if None in expected.values():
        fail("missing expected identity")
    for path in (record_path, archive_path):
        if os.path.islink(path) or not os.path.isfile(path):
            fail("the record and archive must be regular files, not links")
    with open(record_path, encoding="utf-8") as handle:
        record = json.load(handle)
    if not isinstance(record, dict) or set(record) != KEYS:
        fail("malformed crate verification record")
    if record["format"] != "canonprims-crate-verification/v0" or record["repository"] != "3leaps/canonprims":
        fail("crate verification record format or repository mismatch")
    for key, value in expected.items():
        if record[key] != value:
            fail(f"crate verification record {key} differs from this release")
    if not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
        fail("malformed digest")
    with open(archive_path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    if digest != record["sha256"]:
        fail("the downloaded archive does not have the recorded digest")
    print(record["sha256"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError) as error:
        sys.exit(f"error: {error}")

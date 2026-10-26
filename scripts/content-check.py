#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Refuse generic secret and local-path shapes in tracked files.

Usage: content-check.py [ROOT]   (default: the repository root)

Vocabulary-free and safe to run anywhere, including CI: it looks for shapes,
never for names. It refuses a home directory under /Users or /home and a
Windows user profile (except synthetic fixture names), a private-key block,
GitHub and AWS access tokens, and developer "remove before commit" markers.
It reads the tracked files at HEAD only.

The organization's own vocabulary is a separate, maintainer-only scan
(scripts/surface-scan.sh); it never runs in CI.
"""

import re
import subprocess
import sys
from pathlib import Path

# Synthetic home names used by fixtures and CI runners, never real people.
SYNTHETIC = r"(?:someone|user|example|runner|runneradmin|ubuntu)"
SHAPES = {
    "home directory": re.compile(
        r"(?<![A-Za-z0-9_.:/-])/(?:Users|home)/(?!" + SYNTHETIC + r"/)[a-z][a-z0-9._-]{1,31}/"
    ),
    "Windows user profile": re.compile(
        r"\b[A-Za-z]:[\\/]Users[\\/](?!" + SYNTHETIC + r"[\\/])[A-Za-z][A-Za-z0-9._-]{1,31}[\\/]", re.IGNORECASE
    ),
    "private key block": re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    # The markers are joined from fragments so this file never holds one whole.
    "remove-before-commit marker": re.compile(
        r"\b(?:" + "|".join("_".join(parts) for parts in (
            ("DO", "NOT", "COMMIT"),
            ("TODO", "REMOVE", "BEFORE", "PUSH"),
            ("REMOVE", "BEFORE", "COMMIT"),
            ("XXX", "REMOVE", "ME"),
        )) + r")\b"
    ),
}


def tracked(root):
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True
    ).stdout
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
    findings = []
    for rel in tracked(root):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue  # binary
        text = data.decode("utf-8", "replace")
        for number, line in enumerate(text.splitlines(), 1):
            for label, shape in SHAPES.items():
                if shape.search(line):
                    findings.append(f"{rel}:{number}: {label}")
    for finding in findings:
        print(f"error: {finding}", file=sys.stderr)
    if findings:
        sys.exit(f"content-check: {len(findings)} finding(s); this file is public once pushed")
    print("[ok] content-check: no local paths, keys, tokens or commit markers in tracked files")


if __name__ == "__main__":
    main()

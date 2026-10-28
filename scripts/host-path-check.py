#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Fail if a built artifact embeds a build-host path.

Usage: host-path-check.py ARTIFACT PATH...

ARTIFACT is a wheel (every member is read) or any other file. Each PATH is a
build-host directory (the checkout, the Cargo and rustup homes, $HOME). A
match is that directory followed by a separator. A directory of two or more
components (/home/someone, C:\\Users\\someone) matches anywhere. A
single-component directory (a container root such as /src) matches only at
the start of an absolute path, not preceded by a path or name character, so it
does not match the /src/ inside a remapped library path
(library/alloc/src/string.rs). "/" alone is ignored.
"""

import re
import sys
import zipfile

# The start of an absolute path: right after file:// (as in an SBOM's
# path+file:///... URL), or after any byte that is not a path or name
# character (a NUL in a string table, a quote in JSON, a space).
NOT_PRECEDED = rb"(?:(?<=file://)|(?<![A-Za-z0-9._~/\\-]))"
SEPARATOR = rb"[/\\]"


def needles(paths):
    out = []
    for path in paths:
        path = path.rstrip("/\\")
        components = [c for c in re.split(r"[/\\]", path) if c and not c.endswith(":")]
        if not components:
            continue
        prefix = NOT_PRECEDED if len(components) < 2 else b""
        out.append(re.compile(prefix + re.escape(path.encode()) + SEPARATOR))
    return out


def members(artifact):
    if zipfile.is_zipfile(artifact):
        with zipfile.ZipFile(artifact) as z:
            for name in z.namelist():
                yield name, z.read(name)
    else:
        with open(artifact, "rb") as f:
            yield artifact.replace("\\", "/").rsplit("/", 1)[-1], f.read()


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: host-path-check.py ARTIFACT PATH...")
    patterns = needles(argv[2:])
    for name, data in members(argv[1]):
        for pattern in patterns:
            if pattern.search(data):
                sys.exit(f"{name} embeds a build-host path")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

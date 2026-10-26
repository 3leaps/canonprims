#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Refuse a catalog that is, or is the same file as, anything in a repository.

Usage: surface-catalog-path.py CATALOG ROOT [ROOT...]

The catalog must be outside every ROOT (the repository and its worktrees).
Checked by file identity as well as by path, so these are all refused: a path
inside a root as given or after resolving symlinks; the same directory spelled
with different letter case on a case-insensitive volume; and a hard link, any
other name for the catalog's inode, under a root.
"""

import os
import sys


def same_volume_case_insensitive(path):
    """True when the volume holding PATH ignores letter case."""
    probe = os.path.join(os.path.dirname(path), os.path.basename(path).swapcase())
    try:
        return probe != path and os.path.samefile(path, probe)
    except OSError:
        return False


def inside(path, root, fold):
    if fold:
        path, root = path.casefold(), root.casefold()
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: surface-catalog-path.py CATALOG ROOT [ROOT...]")
    catalog = sys.argv[1]
    roots = [os.path.realpath(r) for r in sys.argv[2:]]
    real = os.path.realpath(catalog)
    stat = os.stat(real)
    fold = same_volume_case_insensitive(real)
    for root in roots:
        for candidate in (os.path.abspath(catalog), real):
            if inside(candidate, root, fold):
                sys.exit("error: the catalog must be outside this repository and its worktrees")
    # Another name for the same inode (a hard link) under any root.
    if stat.st_nlink > 1:
        for root in roots:
            for dirpath, dirnames, filenames in os.walk(root):
                for name in filenames:
                    try:
                        other = os.lstat(os.path.join(dirpath, name))
                    except OSError:
                        continue
                    if other.st_ino == stat.st_ino and other.st_dev == stat.st_dev:
                        sys.exit("error: the catalog must be outside this repository and its worktrees (hard link)")


if __name__ == "__main__":
    try:
        main()
    except OSError as error:
        sys.exit(f"error: {error}")

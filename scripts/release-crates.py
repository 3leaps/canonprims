#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Validate the ordered crates.io publication plan against Cargo metadata.

config/release/publishable-crates.txt lists the published library crates in
registry dependency order. Every crate in the list must exist in the workspace,
set publish = true, and follow every workspace crate it depends on (including
dev dependencies); every other workspace crate must stay unpublished.
"""

import json
import os
import shutil
import pathlib
import subprocess
import sys

if sys.version_info < (3, 11):
    sys.exit("error: release crate checks require Python 3.11 or newer")

import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLAN = ROOT / "config/release/publishable-crates.txt"
UNPUBLISHED = ("canonprims-cli",)


def read_plan(path=PLAN):
    names = path.read_text().splitlines()
    if not names or any(not n or n != n.strip() or n.startswith("#") for n in names):
        raise ValueError("crate list must contain one bare name per line")
    if len(names) != len(set(names)) or any(
        not n.startswith("canonprims-") for n in names
    ):
        raise ValueError("invalid or duplicate publishable crate name")
    return names


def validate(packages, names, manifests):
    by_name = {p["name"]: p for p in packages}
    if len(by_name) != len(packages):
        raise ValueError("duplicate workspace package")
    missing = [n for n in names if n not in by_name]
    if missing:
        raise ValueError(f"listed crate(s) not in this workspace: {', '.join(missing)}")
    publishable = {p["name"] for p in packages if p.get("publish") != []}
    extra = sorted(publishable - set(names))
    if extra:
        raise ValueError(
            f"publishable workspace crate(s) missing from the list: {', '.join(extra)}"
        )
    for name in names:
        if manifests[name]["package"].get("publish") is not True:
            raise ValueError(f"{name} must explicitly set publish = true")
        for dependency in by_name[name]["dependencies"]:
            dep = dependency["name"]
            if dep in by_name and dep not in names:
                raise ValueError(f"{name} depends on unpublished workspace crate {dep}")
            if dep in names and names.index(dep) >= names.index(name):
                raise ValueError(
                    f"{name} must follow {dep} (including dev dependencies)"
                )
    for name in UNPUBLISHED:
        if name in by_name and by_name[name].get("publish") != []:
            raise ValueError(f"{name} must remain unpublished")


def main():
    args = sys.argv[1:]
    source_root = ROOT
    if args[:1] == ["--source-root"]:
        if len(args) != 3:
            raise ValueError("expected verified source root and mode")
        source_root = pathlib.Path(args[1]).resolve()
        args = args[2:]
    names = read_plan()
    command = ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"]
    environment = None
    toolchain = os.environ.get("CANONPRIMS_RELEASE_TOOLCHAIN")
    if toolchain:
        # The same cleared environment as release_cargo: a pinned toolchain, so
        # a toolchain selector or flag variable cannot pick what runs.
        cargo = shutil.which("cargo")
        isolated = os.environ.get("CANONPRIMS_RELEASE_CARGO_ISOLATED", "")
        if not cargo or not isolated.startswith("/") or not os.path.isdir(isolated):
            raise ValueError("cargo and an isolated Cargo directory are required")
        command[0] = cargo
        os.makedirs(isolated + "/home", exist_ok=True)
        os.makedirs(isolated + "/cargo", exist_ok=True)
        environment = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": isolated + "/home",
            "CARGO_HOME": isolated + "/cargo",
            "RUSTUP_HOME": os.environ.get("RUSTUP_HOME", os.environ.get("HOME", "") + "/.rustup"),
            "RUSTUP_TOOLCHAIN": toolchain,
        }
    metadata = json.loads(subprocess.check_output(command, cwd=source_root, env=environment))
    packages = metadata["packages"]
    for package in packages:
        if not pathlib.Path(package["manifest_path"]).resolve().is_relative_to(source_root):
            raise ValueError("workspace package escapes verified source")
        for dependency in package["dependencies"]:
            if dependency.get("path") and not pathlib.Path(
                dependency["path"]
            ).resolve().is_relative_to(source_root):
                raise ValueError("path dependency escapes verified source")
    manifests = {
        p["name"]: tomllib.loads(pathlib.Path(p["manifest_path"]).read_text())
        for p in packages
    }
    validate(packages, names, manifests)
    # Every published crate carries exactly the release version of its tree.
    version = (source_root / "VERSION").read_text().strip()
    by_name = {p["name"]: p for p in packages}
    wrong = [n for n in names if by_name[n]["version"] != version]
    if wrong:
        raise ValueError(f"crate version differs from VERSION {version}: {', '.join(wrong)}")
    if args == ["list"]:
        print("\n".join(names))
    elif args != ["check"]:
        raise ValueError("usage: release-crates.py [--source-root DIR] check|list")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(f"error: {error}")

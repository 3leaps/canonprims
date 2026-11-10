#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check the reviewed digests of every workflow.

config/release/release-workflow.sha256 lists every file under
.github/workflows/ and .github/actions/ with its digest (a workflow runs local
actions, so editing one changes what the workflow does). Triggers are not classified: any workflow
can be changed into one that runs on a tag, so all of them are pinned. Every
workflow must also declare top-level `permissions: contents: read` and grant
nothing wider in any job. A changed or unlisted workflow, a listed workflow
that is missing, or an edited pin fails; changing a workflow and its pin
together is a reviewed trust-file change.

Usage:
  release-workflow-pin.py check                 working tree (make check)
  release-workflow-pin.py verify-commit COMMIT  git blobs at COMMIT (ceremony)
"""

import os
import sys

# Import the standard library only: never a module from this script's
# directory or the working directory. YAML is read by the yamlprims CLI through
# scripts/yaml_json.py, loaded by its path (CANONPRIMS_YAMLPRIMS_BIN).
_here = os.path.dirname(os.path.abspath(__file__))
_untrusted = {os.path.realpath(p) for p in (_here, os.getcwd())}
sys.path[:] = [p for p in sys.path if p not in ("", ".") and os.path.realpath(p) not in _untrusted]
sys.dont_write_bytecode = True
import hashlib  # noqa: E402
import importlib.util  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402

_spec = importlib.util.spec_from_file_location("canonprims_yaml_json", os.path.join(_here, "yaml_json.py"))
yaml_json = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yaml_json)

PIN = "config/release/release-workflow.sha256"
WORKFLOWS = ".github/workflows/"
ACTIONS = ".github/actions/"
OIDC_WORKFLOW = ".github/workflows/registry-publish.yml"
OIDC_JOBS = {"publish-pypi": "publish-pypi", "publish-npm": "publish-npm"}


def fail(reason):
    raise ValueError(reason)


def read_only(path, data):
    """Top-level contents: read, and no job grants anything wider (except the
    two environment-gated OIDC publish jobs in registry-publish.yml)."""
    data = yaml_json.load(data, path)
    if not isinstance(data, dict) or data.get("permissions") != {"contents": "read"}:
        fail(f"{path} must declare top-level permissions: contents: read")
    if path == OIDC_WORKFLOW:
        trigger = data.get("on")
        if not isinstance(trigger, dict) or set(trigger) != {"workflow_dispatch"}:
            fail(f"{path} must trigger on workflow_dispatch only")
    for name, job in (data.get("jobs") or {}).items():
        permissions = job.get("permissions") if isinstance(job, dict) else None
        if permissions is None:
            continue
        if (
            path == OIDC_WORKFLOW
            and name in OIDC_JOBS
            and isinstance(job, dict)
            and job.get("environment") == OIDC_JOBS[name]
            and permissions == {"contents": "read", "id-token": "write"}
        ):
            continue
        if not isinstance(permissions, dict) or any(
            str(value).strip().lower() not in ("read", "none") for value in permissions.values()
        ):
            fail(f"{path}: job {name} grants more than read")


def read_pin(text):
    pins = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (\.github/(?:workflows/[A-Za-z0-9._-]+|actions/[A-Za-z0-9._/-]+))", line)
        if not match or match.group(2) in pins:
            fail(f"malformed or duplicate pin line: {line!r}")
        pins[match.group(2)] = match.group(1)
    if not pins:
        fail("the workflow pin lists no workflow")
    return pins


def verify(files, pin_text):
    """files: {path: bytes} for every workflow file."""
    pins = read_pin(pin_text)
    if not files:
        fail("no workflows found")
    for path, data in files.items():
        if path not in pins:
            fail(f"{path} is not pinned in {PIN}")
        if hashlib.sha256(data).hexdigest() != pins[path]:
            fail(f"{path} differs from its reviewed digest in {PIN}")
        if path.startswith(WORKFLOWS):
            read_only(path, data)
    for path in pins:
        if path not in files:
            fail(f"pinned workflow {path} is missing")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def main():
    args = sys.argv[1:]
    if args == ["check"]:
        import pathlib
        files = {p.as_posix(): p.read_bytes() for p in sorted(pathlib.Path(WORKFLOWS).iterdir()) if p.is_file()}
        if pathlib.Path(ACTIONS).is_dir():
            files.update({p.as_posix(): p.read_bytes() for p in sorted(pathlib.Path(ACTIONS).rglob("*")) if p.is_file()})
        verify(files, pathlib.Path(PIN).read_text())
    elif len(args) == 2 and args[0] == "verify-commit":
        commit = args[1]
        names = git("ls-tree", "-r", "--name-only", commit, "--", WORKFLOWS, ACTIONS).decode().splitlines()
        files = {n: git("cat-file", "blob", f"{commit}:{n}") for n in names}
        verify(files, git("cat-file", "blob", f"{commit}:{PIN}").decode())
    else:
        fail("usage: release-workflow-pin.py check | verify-commit COMMIT")
    print("[ok] every workflow matches its reviewed digest and is read-only")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, yaml_json.ReaderError, OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
        detail = str(error) if isinstance(error, (ValueError, yaml_json.ReaderError)) else "unreadable workflow or pin"
        sys.exit("error: " + detail)

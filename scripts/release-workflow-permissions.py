#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check a release workflow's read-only boundary on the parsed YAML.

Every rule applies to decoded values (quoting, escapes, flow style and folded
scalars cannot hide anything), with shell continuations joined and comment
lines removed before commands are matched. Usage:
  release-workflow-permissions.py check FILE
  release-workflow-permissions.py mutations FILE   (each mutation must fail)
FILE is one of the reviewed workflows in PROFILES (by file name); any other
file is refused.
"""

import re
import sys

import os  # noqa: E402

_untrusted = {os.path.realpath(p) for p in (os.path.dirname(os.path.abspath(__file__)), os.getcwd())}
sys.path[:] = [p for p in sys.path if p not in ("", ".") and os.path.realpath(p) not in _untrusted]
import yaml  # noqa: E402

ACTIONS = {"actions/checkout", "actions/upload-artifact", "dtolnay/rust-toolchain"}
RUNNERS = {"ubuntu-24.04", "macos-15", "windows-2025", "ubuntu-latest-arm64-s", "windows-latest-arm64-s"}
SBOM_IMAGE = "ghcr.io/fulmenhq/sbom-tools@sha256:954267f9aca809b89af42bb97471a3c4d7b93c385c5625829b244b17b252fbde"
# PyPA manylinux2014 images (glibc 2.17) for the Linux wheels, tag
# 2026.10.20-1 of each, pinned by digest.
MANYLINUX_AMD64 = "quay.io/pypa/manylinux2014_x86_64@sha256:d6b5342c73e51b8eacd114cb41733798b749494d0a749cef0bd76c99fb47d5c6"
MANYLINUX_ARM64 = "quay.io/pypa/manylinux2014_aarch64@sha256:d41ea3e9c9ad7a47e393673d0e8acba58fa411ceff58bc6b88bca38795ec938e"
# Each must be the start of an executable line in the verify job.
MANDATORY = (
    '(cd "$tool_dir" && sha256sum --check "$GITHUB_WORKSPACE/config/release/decernor-ci-sha256.txt")',
    "./scripts/release-restore-tag-ref.sh",
    "./scripts/release-validate-pin.sh",
    "./scripts/verify-pinned-tag.sh",
    "python3 -I scripts/release-source-check.py",
)
# The release workflow needs no GitHub CLI at all (tags come from git, the
# checker from a pinned download), so any gh invocation is refused rather
# than enumerating which of its subcommands write.
FORBIDDEN_COMMANDS = re.compile(
    # gh as a command however it is spelled: a path, a leading backslash, or
    # quoted (/usr/bin/gh, \gh, $'gh', "gh").
    r"(?i)(^|[\s;&|(`$=])[\\$'\"]*(?:[^\s;&|()`'\"]*/)?['\"]?gh['\"]?(\s|$)"
    r"|\bcargo\b[^\n]*\bpublish\b"
    r"|api/v1/crates|uploads\.github\.com|api\.github\.com/repos/[^\s\"']*/releases"
)
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ARTIFACT_ACTION = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
DOWNLOAD_ARTIFACT_ACTION = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
RUST_TOOLCHAIN_ACTION = "dtolnay/rust-toolchain@6c977a6ca4077a0ceb28ffbe03f59d46e9ac8772"
PYPI_PUBLISH_ACTION = "pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086"
SETUP_NODE_ACTION = "actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1"

ALLOWED_STEP_ENV_KEYS = {
    "ARCHIVE",
    "CANONPRIMS_EXPECTED_TAG_OBJECT",
    "CANONPRIMS_RELEASE_TAG",
    "COMMIT",
    "CRATE",
    "EXPECTED_COMMIT",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "INPUT_TAG",
    "PYTHON",
    "STAGE_COMMIT",
    "STAGE_VERSION",
    "SUFFIX",
    "TARGET",
    "VERSION",
}

VERIFY_OUTPUTS = {
    "version": "${{ steps.identity.outputs.version }}",
    "object": "${{ steps.identity.outputs.object }}",
    "commit": "${{ steps.identity.outputs.commit }}",
}

# What each reviewed workflow must contain beyond the shared rules: its
# trigger definition, workflow-level env, container images, artifact boundary,
# verify job outputs, and complete ordered step structure for verify and OIDC
# publishing jobs.
PROFILES = {
    "release.yml": {
        "trigger": {"push": {"tags": ["v*"]}},
        "workflow_env": {"CARGO_TERM_COLOR": "always", "RUST_TOOLCHAIN": "1.88.0"},
        "verify_outputs": VERIFY_OUTPUTS,
        "images": [MANYLINUX_AMD64, MANYLINUX_ARM64, SBOM_IMAGE],
        "boundary": "release-identity.json",
        "verify_steps": [
            {
                "uses": CHECKOUT_ACTION,
                "with": {"persist-credentials": False, "fetch-depth": 0},
                "env": None,
            },
            {
                "env": None,
                "run": [
                    "set -euo pipefail",
                    "scripts/ci-install-pyyaml.sh python3 --user",
                    'tool_dir="$(mktemp -d "$RUNNER_TEMP/decernor.XXXXXX")"',
                    'name="$(awk \'{print $2}\' config/release/decernor-ci-sha256.txt)"',
                    'version="${name#decernor_}"',
                    'version="${version%%_*}"',
                    'curl --proto \'=https\' --tlsv1.2 --fail --silent --show-error --location --retry 3   "https://github.com/3leaps/decernor/releases/download/v${version}/${name}"   --output "$tool_dir/$name"',
                    '(cd "$tool_dir" && sha256sum --check "$GITHUB_WORKSPACE/config/release/decernor-ci-sha256.txt")',
                    'tar -xzf "$tool_dir/$name" -C "$tool_dir" decernor',
                    'echo "CANONPRIMS_DECERNOR_BIN=$tool_dir/decernor" >> "$GITHUB_ENV"',
                ],
            },
            {
                "env": {
                    "GITHUB_TOKEN": "${{ github.token }}",
                    "CANONPRIMS_RELEASE_TAG": "${{ github.ref_name }}",
                },
                "run": [
                    "set -euo pipefail",
                    "./scripts/release-restore-tag-ref.sh",
                    "source scripts/release-decernor.sh",
                    "resolve_release_decernor",
                    "export RELEASE_DECERNOR_BIN",
                    "./scripts/release-validate-pin.sh",
                    "./scripts/verify-pinned-tag.sh",
                    'python3 -I scripts/release-source-check.py "$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{commit}")"',
                    'version="$(tr -d \'\\r\\n\' < VERSION)"',
                    'object="$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG")"',
                    'commit="$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{}")"',
                    "{",
                    'echo "version=$version"',
                    'echo "object=$object"',
                    'echo "commit=$commit"',
                    '} >> "$GITHUB_OUTPUT"',
                    'printf \'{"tag":"%s","object":"%s","commit":"%s"}\\n\'   "$CANONPRIMS_RELEASE_TAG" "$object" "$commit" > release-identity.json',
                ],
            },
            {
                "uses": UPLOAD_ARTIFACT_ACTION,
                "with": {
                    "name": "release-identity",
                    "if-no-files-found": "error",
                    "retention-days": 30,
                    "path": "release-identity.json\nLICENSE-MIT\nLICENSE-APACHE\n",
                },
                "env": None,
            },
        ],
    },
    "crates-verify.yml": {
        "trigger": {
            "workflow_dispatch": {
                "inputs": {
                    "crate": {
                        "description": "Crate to verify (a later entry of config/release/publishable-crates.txt)",
                        "required": True,
                    }
                }
            }
        },
        "workflow_env": {"CARGO_TERM_COLOR": "always", "RUST_TOOLCHAIN": "1.88.0"},
        "verify_outputs": None,
        "images": [],
        "boundary": "scripts/ci-crate-verify.sh",
        "verify_steps": [
            {
                "uses": CHECKOUT_ACTION,
                "with": {"persist-credentials": False, "fetch-depth": 0},
                "env": None,
            },
            {
                "env": None,
                "run": [
                    "set -euo pipefail",
                    "scripts/ci-install-pyyaml.sh python3 --user",
                    'tool_dir="$(mktemp -d "$RUNNER_TEMP/decernor.XXXXXX")"',
                    'name="$(awk \'{print $2}\' config/release/decernor-ci-sha256.txt)"',
                    'version="${name#decernor_}"',
                    'version="${version%%_*}"',
                    'curl --proto \'=https\' --tlsv1.2 --fail --silent --show-error --location --retry 3   "https://github.com/3leaps/decernor/releases/download/v${version}/${name}"   --output "$tool_dir/$name"',
                    '(cd "$tool_dir" && sha256sum --check "$GITHUB_WORKSPACE/config/release/decernor-ci-sha256.txt")',
                    'tar -xzf "$tool_dir/$name" -C "$tool_dir" decernor',
                    'echo "CANONPRIMS_DECERNOR_BIN=$tool_dir/decernor" >> "$GITHUB_ENV"',
                ],
            },
            {
                "env": {
                    "GITHUB_TOKEN": "${{ github.token }}",
                    "CANONPRIMS_RELEASE_TAG": "${{ github.ref_name }}",
                },
                "run": [
                    "set -euo pipefail",
                    '[[ "$GITHUB_REF" == refs/tags/v* ]] || { echo "dispatch with --ref vX.Y.Z" >&2; exit 1; }',
                    "./scripts/release-restore-tag-ref.sh",
                    "source scripts/release-decernor.sh",
                    "resolve_release_decernor",
                    "export RELEASE_DECERNOR_BIN",
                    "./scripts/release-validate-pin.sh",
                    "./scripts/verify-pinned-tag.sh",
                    'python3 -I scripts/release-source-check.py "$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{commit}")"',
                ],
            },
            {
                "uses": RUST_TOOLCHAIN_ACTION,
                "with": {"toolchain": "${{ env.RUST_TOOLCHAIN }}"},
                "env": None,
            },
            {
                "env": {
                    "CANONPRIMS_RELEASE_TAG": "${{ github.ref_name }}",
                    "CRATE": "${{ inputs.crate }}",
                },
                "run": ['scripts/ci-crate-verify.sh "$CRATE" "$RUNNER_TEMP/crate-verification"'],
            },
            {
                "uses": UPLOAD_ARTIFACT_ACTION,
                "with": {
                    "name": "crate-${{ inputs.crate }}",
                    "if-no-files-found": "error",
                    "retention-days": 30,
                    "path": "${{ runner.temp }}/crate-verification/",
                },
                "env": None,
            },
        ],
    },
    "registry-publish.yml": {
        "trigger": {
            "workflow_dispatch": {
                "inputs": {
                    "tag": {
                        "description": "Published release tag (vX.Y.Z; must match --ref vX.Y.Z)",
                        "required": False,
                        "type": "string",
                    },
                    "registry": {
                        "description": "Registry to publish (all, pypi, or npm)",
                        "required": False,
                        "default": "all",
                        "type": "choice",
                        "options": ["all", "pypi", "npm"],
                    },
                    "dry_run": {
                        "description": "Stage and verify the published GitHub release without uploading to PyPI or npm",
                        "required": False,
                        "default": True,
                        "type": "boolean",
                    },
                }
            }
        },
        "workflow_env": {"NODE_VERSION": "22.23.4"},
        "verify_outputs": VERIFY_OUTPUTS,
        "images": [],
        "boundary": "./scripts/release-stage-published.sh",
        "verify_steps": [
            {
                "uses": CHECKOUT_ACTION,
                "with": {"persist-credentials": False, "fetch-depth": 0},
                "env": None,
            },
            {
                "env": None,
                "run": [
                    "set -euo pipefail",
                    "sudo apt-get update -qq",
                    "sudo apt-get install -y -qq minisign",
                    "scripts/ci-install-pyyaml.sh python3 --user",
                    "minisign -v",
                    'tool_dir="$(mktemp -d "$RUNNER_TEMP/decernor.XXXXXX")"',
                    'name="$(awk \'{print $2}\' config/release/decernor-ci-sha256.txt)"',
                    'version="${name#decernor_}"',
                    'version="${version%%_*}"',
                    'curl --proto \'=https\' --tlsv1.2 --fail --silent --show-error --location --retry 3   "https://github.com/3leaps/decernor/releases/download/v${version}/${name}"   --output "$tool_dir/$name"',
                    '(cd "$tool_dir" && sha256sum --check "$GITHUB_WORKSPACE/config/release/decernor-ci-sha256.txt")',
                    'tar -xzf "$tool_dir/$name" -C "$tool_dir" decernor',
                    'echo "CANONPRIMS_DECERNOR_BIN=$tool_dir/decernor" >> "$GITHUB_ENV"',
                ],
            },
            {
                "env": {
                    "GITHUB_TOKEN": "${{ github.token }}",
                    "GH_TOKEN": "${{ github.token }}",
                    "CANONPRIMS_RELEASE_TAG": "${{ github.ref_name }}",
                    "INPUT_TAG": "${{ inputs.tag }}",
                },
                "run": [
                    "set -euo pipefail",
                    '[[ "$GITHUB_REF" == refs/tags/v* ]] || { echo "dispatch with --ref vX.Y.Z" >&2; exit 1; }',
                    '[[ -z "$INPUT_TAG" || "$INPUT_TAG" == "$CANONPRIMS_RELEASE_TAG" ]] || {',
                    'echo "inputs.tag ($INPUT_TAG) must match --ref ($CANONPRIMS_RELEASE_TAG)" >&2',
                    "exit 1",
                    "}",
                    "./scripts/release-restore-tag-ref.sh",
                    "source scripts/release-decernor.sh",
                    "resolve_release_decernor",
                    "export RELEASE_DECERNOR_BIN",
                    "./scripts/release-validate-pin.sh",
                    "./scripts/verify-pinned-tag.sh",
                    'python3 -I scripts/release-source-check.py "$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{commit}")"',
                    "./scripts/release-github-preflight.sh",
                    './scripts/release-stage-published.sh "$CANONPRIMS_RELEASE_TAG" "$RUNNER_TEMP/registry-stage"',
                    'version="$(tr -d \'\\r\\n\' < VERSION)"',
                    'object="$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG")"',
                    'commit="$(git rev-parse "refs/tags/$CANONPRIMS_RELEASE_TAG^{}")"',
                    "{",
                    'echo "version=$version"',
                    'echo "object=$object"',
                    'echo "commit=$commit"',
                    '} >> "$GITHUB_OUTPUT"',
                ],
            },
            {
                "uses": UPLOAD_ARTIFACT_ACTION,
                "with": {
                    "name": "registry-stage",
                    "if-no-files-found": "error",
                    "retention-days": 5,
                    "path": "${{ runner.temp }}/registry-stage/",
                },
                "env": None,
            },
        ],
        "oidc": {
            "publish-pypi": {
                "environment": "publish-pypi",
                "if": "inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'pypi')",
                "actions": {"actions/checkout", "actions/download-artifact", "pypa/gh-action-pypi-publish"},
                "steps": [
                    {
                        "uses": CHECKOUT_ACTION,
                        "with": {"persist-credentials": False, "fetch-depth": 0},
                        "env": None,
                    },
                    {
                        "uses": DOWNLOAD_ARTIFACT_ACTION,
                        "with": {"name": "registry-stage", "path": "dist/registry-stage"},
                        "env": None,
                    },
                    {
                        "env": {
                            "STAGE_VERSION": "${{ needs.verify.outputs.version }}",
                            "STAGE_COMMIT": "${{ needs.verify.outputs.commit }}",
                        },
                        "run": [
                            "set -euo pipefail",
                            '[[ "$GITHUB_REF" == "refs/tags/v$STAGE_VERSION" && "${GITHUB_REF_TYPE:-tag}" == "tag" ]]',
                            './scripts/ci-prepare-pypi-publish.sh "$STAGE_VERSION" "$STAGE_COMMIT" dist/registry-stage dist/pypi-wheels',
                        ],
                    },
                    {
                        "uses": PYPI_PUBLISH_ACTION,
                        "with": {"packages-dir": "dist/pypi-wheels", "attestations": True},
                        "env": None,
                    },
                    {
                        "env": {"STAGE_VERSION": "${{ needs.verify.outputs.version }}"},
                        "run": [
                            'python3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage "$STAGE_VERSION" pypi'
                        ],
                    },
                ],
            },
            "publish-npm": {
                "environment": "publish-npm",
                "if": "inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'npm')",
                "actions": {"actions/checkout", "actions/setup-node", "actions/download-artifact"},
                "steps": [
                    {
                        "uses": CHECKOUT_ACTION,
                        "with": {"persist-credentials": False, "fetch-depth": 0},
                        "env": None,
                    },
                    {
                        "uses": SETUP_NODE_ACTION,
                        "with": {
                            "node-version": "${{ env.NODE_VERSION }}",
                            "registry-url": "https://registry.npmjs.org",
                        },
                        "env": None,
                    },
                    {
                        "uses": DOWNLOAD_ARTIFACT_ACTION,
                        "with": {"name": "registry-stage", "path": "dist/registry-stage"},
                        "env": None,
                    },
                    {
                        "env": {
                            "STAGE_VERSION": "${{ needs.verify.outputs.version }}",
                            "STAGE_COMMIT": "${{ needs.verify.outputs.commit }}",
                        },
                        "run": [
                            "set -euo pipefail",
                            '[[ "$GITHUB_REF" == "refs/tags/v$STAGE_VERSION" && "${GITHUB_REF_TYPE:-tag}" == "tag" ]]',
                            './scripts/ci-publish-npm-oidc.sh "$STAGE_VERSION" "$STAGE_COMMIT" dist/registry-stage',
                        ],
                    },
                ],
            },
        },
    },
}
SECRET = re.compile(r"(?i)\bsecrets\b|CARGO_REGISTRY_TOKEN|NODE_AUTH_TOKEN")
# The one reviewed way to start a container from a step: the wheel build,
# exactly this command, with the image and target bound to each other. Every
# other step must not name a container runtime in any spelling.
WHEEL_RUN = re.compile(
    r'mkdir -p "(?P<out>\$PWD/dist/wheel|\$RUNNER_TEMP/wheel)"\n'
    r'docker run --rm --user "\$\(id -u\):\$\(id -g\)" -e HOME=/tmp/home '
    r'-v "\$PWD:/src" -v "(?P=out):/out" -w /src '
    r'(?P<image>\S+) '
    r"bash -c 'mkdir -p \"\$HOME\" && git config --global --add safe.directory /src && "
    r"scripts/build-wheel\.sh (?P<target>\S+) /out'\n?"
)
WHEEL_IMAGES = {
    "x86_64-unknown-linux-gnu": MANYLINUX_AMD64,
    "aarch64-unknown-linux-gnu": MANYLINUX_ARM64,
}
# Quotes, backslashes and expansion characters removed, so d'o'cker, \docker
# and /usr/bin/docker all read as docker.
RUNTIME = re.compile(r"(?i)docker|podman|nerdctl|ctr\b|buildah|containerd|runc\b")


def container_run(code):
    """The image a reviewed wheel-build step runs, or None if the step names
    no container runtime; anything else fails."""
    if not RUNTIME.search(re.sub(r"[\\'\"$`{}()]", "", code)):
        return None
    # One command per line, runs of blanks as one space.
    lines = [" ".join(line.split()) for line in code.splitlines() if line.strip()]
    m = WHEEL_RUN.fullmatch("\n".join(lines) + "\n")
    if not m or WHEEL_IMAGES.get(m.group("target")) != m.group("image"):
        fail("a container may start only from the reviewed wheel-build step")
    return m.group("image")


def fail(reason):
    raise ValueError(reason)


def has_forbidden_control_char(text):
    return any(
        (ord(ch) < 0x20 and ch not in ("\n", "\t")) or ord(ch) in (0x7F, 0x85, 0x2028, 0x2029)
        for ch in text
    )


ALLOWED_STEP_ENV_ITEMS = frozenset(
    {
        ("ARCHIVE", "${{ matrix.archive }}"),
        ("CANONPRIMS_EXPECTED_TAG_OBJECT", "${{ needs.verify.outputs.object }}"),
        ("CANONPRIMS_RELEASE_TAG", "${{ github.ref_name }}"),
        ("COMMIT", "${{ needs.verify.outputs.commit }}"),
        ("CRATE", "${{ inputs.crate }}"),
        ("EXPECTED_COMMIT", "${{ needs.verify.outputs.commit }}"),
        ("GITHUB_TOKEN", "${{ github.token }}"),
        ("GH_TOKEN", "${{ github.token }}"),
        ("INPUT_TAG", "${{ inputs.tag }}"),
        ("PYTHON", "${{ matrix.python }}"),
        ("STAGE_COMMIT", "${{ needs.verify.outputs.commit }}"),
        ("STAGE_VERSION", "${{ needs.verify.outputs.version }}"),
        ("SUFFIX", "${{ matrix.artifact_suffix }}"),
        ("TARGET", "${{ matrix.target }}"),
        ("VERSION", "${{ needs.verify.outputs.version }}"),
    }
)


def shell_code(run):
    text = str(run)
    if has_forbidden_control_char(text):
        fail("non-LF control or line-separator character in run step")
    if "${{" in text:
        fail("GitHub expression interpolation in run step is not reviewed")
    out = []
    continued = ""
    for line in text.split("\n"):
        if not continued and line.lstrip(" \t").startswith("#"):
            if line.rstrip(" \t").endswith("\\"):
                fail("comment line ending with backslash is not reviewed")
            continue
        if continued and line.lstrip(" \t").startswith("#"):
            fail("comment line after backslash line continuation is not reviewed")
        if line.endswith("\\"):
            continued += line[:-1]
        else:
            out.append(continued + line)
            continued = ""
    if continued:
        out.append(continued)
    return "\n".join(out)


def stripped_run_lines(run):
    return [ln.strip(" \t") for ln in shell_code(run).split("\n") if ln.strip(" \t")]


def canonical_step(step, job_name):
    if not isinstance(step, dict):
        fail(f"{job_name}: step is not a mapping")
    if not set(step).issubset({"name", "id", "uses", "with", "env", "run", "shell"}):
        fail(f"{job_name}: unreviewed step key")
    if ("uses" in step) == ("run" in step):
        fail(f"{job_name}: step must specify either uses or run")
    if "uses" in step:
        if "shell" in step:
            fail(f"{job_name}: uses step must not specify shell")
        return {
            "uses": step["uses"],
            "with": step.get("with"),
            "env": step.get("env"),
        }
    if "with" in step:
        fail(f"{job_name}: run step must not specify with")
    return {
        "env": step.get("env"),
        "run": stripped_run_lines(step["run"]),
    }


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield str(key)
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)


def check(text, profile):
    data = yaml.safe_load(text)
    if not isinstance(data, dict):
        fail("workflow is not a mapping")
    if not set(data).issubset({"name", "on", True, "permissions", "env", "jobs"}) or ("on" in data) == (True in data):
        fail("workflow has unreviewed top-level keys")
    if data.get("permissions") != {"contents": "read"}:
        fail("workflow permissions must be exactly contents: read")
    if "defaults" in data:
        fail("workflow-level defaults are not reviewed")
    if data.get("env") != profile["workflow_env"]:
        fail("workflow-level env differs from reviewed profile")
    trigger = data.get("on") if "on" in data else data.get(True)
    if trigger != profile["trigger"]:
        fail("workflow trigger differs from reviewed profile")
    jobs = data.get("jobs")
    if not isinstance(jobs, dict) or "verify" not in jobs:
        fail("workflow jobs are missing")
    oidc_specs = profile.get("oidc") or {}
    if oidc_specs:
        if set(jobs) != {"verify"} | set(oidc_specs):
            fail("OIDC workflow job set differs from reviewed profile")
    for value in strings(data):
        if has_forbidden_control_char(value):
            fail("non-LF control or line-separator character in workflow")
        if SECRET.search(value):
            fail("workflow registry or secret access")
    images = []
    for name, job in jobs.items():
        if not isinstance(job, dict):
            fail(f"{name}: job is not a mapping")
        if "env" in job:
            fail(f"{name}: job-level env is not reviewed")
        if name == "verify":
            if job.get("outputs") != profile["verify_outputs"]:
                fail("verify: job outputs differ from reviewed profile")
        elif "outputs" in job:
            fail(f"{name}: job outputs are not reviewed")
        if job.get("defaults") != {"run": {"shell": "bash"}}:
            fail(f"{name}: job defaults must be exactly run.shell=bash")
        oidc_spec = oidc_specs.get(name)
        permissions = job.get("permissions")
        if oidc_spec is not None:
            if permissions != {"contents": "read", "id-token": "write"}:
                fail(f"{name}: OIDC job permissions must be contents: read and id-token: write")
            if job.get("environment") != oidc_spec["environment"]:
                fail(f"{name}: OIDC job must require environment {oidc_spec['environment']}")
            if job.get("if") != oidc_spec["if"]:
                fail(f"{name}: OIDC job condition differs from reviewed dry_run/registry guard")
        elif permissions is not None and (
            not isinstance(permissions, dict)
            or any(str(v).strip().lower() not in ("read", "none") for v in permissions.values())
        ):
            fail(f"{name}: workflow write permission")
        label = job.get("runs-on")
        if label == "${{ matrix.runner }}":
            include = ((job.get("strategy") or {}).get("matrix") or {}).get("include") or []
            labels = [entry.get("runner") for entry in include if isinstance(entry, dict)]
            if not labels or len(labels) != len(include) or any(l not in RUNNERS for l in labels):
                fail(f"{name}: moving or unreviewed runner image")
        elif label not in RUNNERS:
            fail(f"{name}: moving or unreviewed runner image")
        if "services" in job or "continue-on-error" in job or (oidc_spec is None and "if" in job):
            fail(f"{name}: services, continue-on-error and job conditions are not reviewed")
        matrix = (job.get("strategy") or {}).get("matrix")
        if matrix is not None and (not isinstance(matrix, dict) or set(matrix) != {"include"}):
            fail(f"{name}: only an explicit matrix include list is reviewed")
        container = job.get("container")
        if container is not None:
            images.append(container.get("image") if isinstance(container, dict) else container)
        if name != "verify":
            needs = job.get("needs")
            needs = [needs] if isinstance(needs, str) else needs or []
            if "verify" not in needs:
                fail(f"{name}: must need verify")
        steps = [{"uses": job["uses"]}] if "uses" in job else []
        steps += [s for s in job.get("steps") or [] if isinstance(s, dict)]
        if len(steps) != len(job.get("steps") or []) + (1 if "uses" in job else 0):
            fail(f"{name}: malformed step")
        allowed_actions = oidc_spec["actions"] if oidc_spec is not None else ACTIONS
        checkout_count = 0
        for step_index, step in enumerate(steps):
            if "if" in step or "continue-on-error" in step or "working-directory" in step:
                fail(f"{name}: step conditions, continue-on-error and working-directory are not reviewed")
            expected_id = "identity" if (name == "verify" and step_index == 2 and profile["verify_outputs"] is not None) else None
            if step.get("id") != expected_id:
                fail(f"{name}: step id differs from reviewed profile")
            if "shell" in step and step.get("shell") != "bash":
                fail(f"{name}: step shell must be bash")
            canonical_step(step, name)
            step_env = step.get("env")
            if step_env is not None:
                if (
                    not isinstance(step_env, dict)
                    or not step_env
                    or any(not isinstance(k, str) or not isinstance(v, str) for k, v in step_env.items())
                    or not set(step_env.items()).issubset(ALLOWED_STEP_ENV_ITEMS)
                ):
                    fail(f"{name}: unreviewed step env mapping")
            if re.search(r"\|\|\s*(true|:)|<<-?\s*['\"]?\w|\bset\s+\+e\b", shell_code(step.get("run", ""))):
                fail(f"{name}: ignored failures and heredocs are not reviewed")
            action = step.get("uses")
            if action is not None:
                if step_env is not None:
                    fail(f"{name}: uses step must not specify env")
                repo, sep, ref = str(action).partition("@")
                if not sep or repo not in allowed_actions or not re.fullmatch(r"[0-9a-f]{40}", ref):
                    fail("unreviewed release action")
                if repo == "actions/checkout":
                    checkout_count += 1
                    expected_checkout_with = (
                        {"persist-credentials": False, "fetch-depth": 0}
                        if name in ("verify", "publish-pypi", "publish-npm")
                        else {"persist-credentials": False, "ref": "${{ needs.verify.outputs.commit }}"}
                    )
                    if step_index != 0 or checkout_count != 1 or step.get("with") != expected_checkout_with:
                        fail(f"{name}: checkout step must be first with reviewed with mapping")
            if FORBIDDEN_COMMANDS.search(shell_code(step.get("run", ""))):
                fail("workflow release creation or publication")
            image = container_run(shell_code(step.get("run", "")))
            if image is not None:
                images.append(image)
            for value in strings({k: v for k, v in step.items() if k != "run"}):
                if RUNTIME.search(re.sub(r"[\\'\"$`{}()]", "", value)):
                    fail("a container may start only from the reviewed wheel-build step")
        if checkout_count != 1:
            fail(f"{name}: job must have exactly one checkout step")
    # A crate verification job uploads exactly the directory the verifier
    # creates outside the checkout, so the artifact holds nothing else.
    for name, job in jobs.items():
        steps = [s for s in job.get("steps") or [] if isinstance(s, dict)]
        runs = [shell_code(s.get("run", "")) for s in steps]
        if not any("scripts/ci-crate-verify.sh" in r for r in runs):
            continue
        if not all(re.search(r'scripts/ci-crate-verify\.sh\s+\S+\s+"\$RUNNER_TEMP/crate-verification"\s*$', r, re.M)
                   for r in runs if "scripts/ci-crate-verify.sh" in r):
            fail(f"{name}: crate verification must write to $RUNNER_TEMP/crate-verification")
        uploads = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
        if len(uploads) != 1 or (uploads[0].get("with") or {}).get("path") != "${{ runner.temp }}/crate-verification/":
            fail(f"{name}: crate verification must upload exactly its output directory")
    if images != profile["images"]:
        fail("unreviewed container image")
    actual_verify_steps = [canonical_step(s, "verify") for s in (jobs["verify"].get("steps") or [])]
    if actual_verify_steps != profile["verify_steps"]:
        fail("verify: verification steps differ from reviewed profile")
    code = "\n".join(shell_code(s.get("run", "")) for s in jobs["verify"].get("steps") or [] if isinstance(s, dict))
    for command in MANDATORY:
        if not re.search(r"(?m)^\s*" + re.escape(command), code):
            fail("missing tag-set or anchor verification")
    if profile["boundary"] not in code:
        fail("missing artifact boundary")
    if oidc_specs:
        for oidc_job_name, oidc_spec in oidc_specs.items():
            actual_oidc_steps = [
                canonical_step(s, oidc_job_name)
                for s in (jobs[oidc_job_name].get("steps") or [])
            ]
            if actual_oidc_steps != oidc_spec["steps"]:
                fail(f"{oidc_job_name}: OIDC job steps differ from reviewed profile")
        uploads = [s for s in (jobs["verify"].get("steps") or []) if isinstance(s, dict) and str(s.get("uses", "")).startswith("actions/upload-artifact@")]
        if len(uploads) != 1 or (uploads[0].get("with") or {}).get("path") != "${{ runner.temp }}/registry-stage/":
            fail("verify: registry-publish must upload exactly $RUNNER_TEMP/registry-stage")


def shared_mutations(text):
    """Mutations whose anchors every reviewed workflow has."""
    def sub(old, new):
        if old not in text:
            fail(f"mutation anchor not found: {old!r}")
        return text.replace(old, new, 1)

    run = "          set -euo pipefail\n"
    checkout = "      - name: Checkout\n"
    first_runs_on = "    runs-on: ubuntu-24.04\n"
    return [
        sub("permissions:\n  contents: read", "permissions:\n  contents: write"),
        sub("permissions:\n  contents: read", "permissions: write-all"),
        sub("permissions:\n  contents: read", "permissions:\n  contents: read\ndefaults:\n  run:\n    shell: true {0}"),
        sub("env:\n", "env:\n  BASH_ENV: /tmp/evil.sh\n"),
        sub("env:\n", "env:\n  BASH_FUNC_python3%%: '() { return 0; }'\n"),
        sub(first_runs_on, first_runs_on + "    env:\n      BASH_ENV: /tmp/evil.sh\n"),
        sub("        env:\n", "        env:\n          BASH_ENV: /tmp/evil.sh\n"),
        sub("        env:\n", "        env:\n          BASH_FUNC_python3%%: '() { return 0; }'\n"),
        sub("        shell: bash\n", "        shell: true {0}\n"),
        sub("        shell: bash\n", "        shell: bash\n        working-directory: /tmp\n"),
        sub(run, "        shell: bash -c true {0}\n" + run),
        sub(run, "        shell: bash -n {0}\n" + run),
        sub(run, run + "          # comment \\\n          exit 0\n"),
        sub(run, run + "          true \\\n          # comment\n"),
        sub(run, run + "          # ${{ fromJSON('\"\\nexit 0\\n#\"') }}\n"),
        sub(first_runs_on, first_runs_on + "    permissions: {contents: read, packages: write}\n"),
        sub(first_runs_on, "    runs-on: ubuntu-latest\n"),
        sub(checkout, "      - uses: unknown-org/action@main\n" + checkout),
        sub(
            "          persist-credentials: false\n          fetch-depth: 0\n",
            "          persist-credentials: false\n          fetch-depth: 0\n          repository: attacker/example\n",
        ),
        sub(
            "          persist-credentials: false\n          fetch-depth: 0\n",
            "          persist-credentials: false\n          fetch-depth: 0\n          ref: main\n",
        ),
        sub(
            "          persist-credentials: false\n          fetch-depth: 0\n",
            "          persist-credentials: false\n          fetch-depth: 0\n          path: sub\n",
        ),
        sub(run, run + "          gh release create v1.2.3\n"),
        sub(run, run + "          cargo publish -p canonprims-core\n"),
        sub(run, run + "          echo \"${{ secrets['CARGO_REGISTRY_TOKEN'] }}\"\n"),
        sub(first_runs_on, first_runs_on + "    container: {image: docker.io/evil/builder:latest}\n"),
        sub(first_runs_on, first_runs_on + "    continue-on-error: true\n"),
        sub(checkout, "      - if: false\n        run: true\n" + checkout),
        sub(run, run + "          set +e\n"),
        text.replace("decernor-ci-sha256.txt", "x.txt"),
        sub("          ./scripts/verify-pinned-tag.sh\n", "          # ./scripts/verify-pinned-tag.sh\n"),
        sub("          ./scripts/release-validate-pin.sh\n", "          echo ./scripts/release-validate-pin.sh\n"),
        sub("          python3 -I scripts/release-source-check.py", "          : python3 -I scripts/release-source-check.py"),
    ]


def crates_verify_mutations(text):
    def sub(old, new):
        if old not in text:
            fail(f"mutation anchor not found: {old!r}")
        return text.replace(old, new, 1)

    return shared_mutations(text) + [
        # The package step is the workflow's boundary.
        sub("scripts/ci-crate-verify.sh", "scripts/other.sh"),
        sub('"$CRATE" "$RUNNER_TEMP/crate-verification"', '"$CRATE" crates'),
        sub("path: ${{ runner.temp }}/crate-verification/", "path: crates/"),
    ]


def registry_publish_mutations(text):
    def sub(old, new):
        if old not in text:
            fail(f"mutation anchor not found: {old!r}")
        return text.replace(old, new, 1)

    def preflight_sep_mutation(sep_char):
        doc = yaml.safe_load(text)
        step = doc["jobs"]["verify"]["steps"][2]
        step["run"] = step["run"].replace(
            "\n./scripts/release-github-preflight.sh\n",
            f"\n# skipped{sep_char}./scripts/release-github-preflight.sh\n",
            1,
        )
        return yaml.safe_dump(doc, sort_keys=False)

    def reorder_pypi_publish_before_verify():
        doc = yaml.safe_load(text)
        steps = doc["jobs"]["publish-pypi"]["steps"]
        steps[2], steps[3] = steps[3], steps[2]
        return yaml.safe_dump(doc, sort_keys=False)

    def drop_pypi_publish_step():
        doc = yaml.safe_load(text)
        del doc["jobs"]["publish-pypi"]["steps"][3]
        return yaml.safe_dump(doc, sort_keys=False)

    def drop_dry_run_input():
        doc = yaml.safe_load(text)
        trig = doc.get("on") if "on" in doc else doc.get(True)
        del trig["workflow_dispatch"]["inputs"]["dry_run"]
        return yaml.safe_dump(doc, sort_keys=False)

    first_runs_on = "    runs-on: ubuntu-24.04\n"
    return shared_mutations(text) + [
        preflight_sep_mutation("\r"),
        preflight_sep_mutation("\x0b"),
        reorder_pypi_publish_before_verify(),
        drop_pypi_publish_step(),
        drop_dry_run_input(),
        sub("        default: true\n", "        default: false\n"),
        sub("        default: true\n        type: boolean\n", "        default: 'true'\n        type: string\n"),
        sub("        options:\n          - all\n          - pypi\n          - npm\n", "        options:\n          - all\n"),
        sub("      version: ${{ steps.identity.outputs.version }}\n", "      version: 0.0.0\n"),
        sub("on:\n  workflow_dispatch:\n", "on:\n  push:\n    tags: ['v*']\n  workflow_dispatch:\n"),
        sub(first_runs_on, first_runs_on + "    permissions:\n      contents: read\n      id-token: write\n"),
        sub("    environment: publish-pypi\n", ""),
        sub("    environment: publish-npm\n", "    environment: publish-pypi\n"),
        sub("      id-token: write\n", "      id-token: write\n      contents: write\n"),
        sub("    if: inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'pypi')\n", ""),
        sub("    if: inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'npm')\n", "    if: true\n"),
        sub("    needs: verify\n", ""),
        sub("          ./scripts/release-github-preflight.sh\n", "          # ./scripts/release-github-preflight.sh\n"),
        sub(
            "        run: python3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \"$STAGE_VERSION\" pypi\n",
            "        run: |\n          # ${{ fromJSON('\"\\nexit 0\\n#\"') }}\n          python3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \"$STAGE_VERSION\" pypi\n",
        ),
        sub(
            "        run: python3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \"$STAGE_VERSION\" pypi\n",
            "        run: \"# skipped\\rpython3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \\\"$STAGE_VERSION\\\" pypi\"\n",
        ),
        sub(
            "        run: python3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \"$STAGE_VERSION\" pypi\n",
            "        run: \"# skipped\\x0bpython3 -I -B scripts/release-verify-registries.py --expect-provenance dist/registry-stage \\\"$STAGE_VERSION\\\" pypi\"\n",
        ),
        sub(
            "      - name: Verify PyPI serves the signed wheel bytes and PEP 740 provenance\n",
            "      - name: Verify PyPI serves the signed wheel bytes and PEP 740 provenance\n        shell: bash -c true {0}\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          if false; then\n            ./scripts/release-github-preflight.sh\n          fi\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          if false; then ./scripts/release-github-preflight.sh; fi\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          false &&\n          ./scripts/release-github-preflight.sh\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          true ||\n          ./scripts/release-github-preflight.sh\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          function skip_preflight {\n            ./scripts/release-github-preflight.sh\n          }\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          select x in; do\n            ./scripts/release-github-preflight.sh\n          done\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            '          : "\n          ./scripts/release-github-preflight.sh\n          "\n',
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          {\n            ./scripts/release-github-preflight.sh\n          } || echo ignored\n",
        ),
        sub(
            "          ./scripts/release-github-preflight.sh\n",
            "          {\n            ./scripts/release-github-preflight.sh\n          } &\n",
        ),
        sub('./scripts/release-stage-published.sh "$CANONPRIMS_RELEASE_TAG" "$RUNNER_TEMP/registry-stage"', "./scripts/other.sh"),
        sub('"$CANONPRIMS_RELEASE_TAG" "$RUNNER_TEMP/registry-stage"', '"$CANONPRIMS_RELEASE_TAG" dist/published'),
        sub("path: ${{ runner.temp }}/registry-stage/", "path: dist/"),
        sub("pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086", "pypa/gh-action-pypi-publish@release/v1"),
        sub(
            "          packages-dir: dist/pypi-wheels\n          attestations: true\n",
            "          packages-dir: dist/pypi-wheels\n          attestations: false\n",
        ),
        sub(
            "          packages-dir: dist/pypi-wheels\n          attestations: true\n",
            "          packages-dir: dist/unverified\n          attestations: true\n",
        ),
        sub(
            "          name: registry-stage\n          path: dist/registry-stage\n",
            "          name: registry-stage\n          path: dist/registry-stage\n          run-id: 12345\n",
        ),
    ]


def mutations(text):
    """Each entry changes the workflow in a way check() must refuse."""
    def sub(old, new):
        if old not in text:
            fail(f"mutation anchor not found: {old!r}")
        return text.replace(old, new, 1)

    run = "          set -euo pipefail\n"
    checkout = "      - name: Checkout\n"
    first_runs_on = "    runs-on: ubuntu-24.04\n"
    return [
        sub("permissions:\n  contents: read", "permissions:\n  contents: write"),
        sub("permissions:\n  contents: read", "permissions: write-all"),
        sub("permissions:\n  contents: read", "permissions: read-all"),
        sub("permissions:\n  contents: read", 'permissions:\n  contents: "wri\\u0074e"'),
        sub("permissions:\n  contents: read", "permissions:\n  contents: >-\n    write"),
        sub(first_runs_on, first_runs_on + '    permissions: {contents: "wri\\u0074e"}\n'),
        sub(first_runs_on, first_runs_on + "    permissions: {contents: read, packages: write}\n"),
        sub(first_runs_on, "    runs-on: ubuntu-latest\n"),
        sub(first_runs_on, "    runs-on: ${{ 'ubuntu-latest' }}\n"),
        sub("runner: macos-15", "runner: macos-latest"),
        sub(checkout, "      - uses: unknown-org/action@main\n" + checkout),
        sub(checkout, "      - {uses: actions/checkout@v4}\n" + checkout),
        sub(checkout, "      - uses: softprops/action-gh-release@v2\n" + checkout),
        sub(checkout, "      - uses: ./.github/actions/make-check\n" + checkout),
        sub(run, run + "          gh release create v1.2.3\n"),
        sub(run, run + "          gh \\\n            release create v1\n"),
        sub(run, run + "          gh api --method POST repos/3leaps/canonprims/releases -f tag_name=v1\n"),
        sub(run, run + "          gh api repos/3leaps/canonprims/releases -X POST\n"),
        sub(run, run + "          curl -X POST https://api.github.com/repos/x/y/releases\n"),
        sub(run, run + "          cargo publish -p canonprims-core\n"),
        sub(run, run + "          c\\\n          argo publish\n"),
        sub(run, run + "          echo \"${{ secrets['CARGO_REGISTRY_TOKEN'] }}\"\n"),
        sub(run, run + '          echo "${{ secr\\u0065ts.X }}"\n'.replace("\\u0065", "e")),
        sub("    runs-on: ubuntu-24.04\n", "    runs-on: ubuntu-24.04\n    env:\n      T: \"${{ secr\\u0065ts.X }}\"\n"),
        text.replace("decernor-ci-sha256.txt", "x.txt"),
        sub("          ./scripts/verify-pinned-tag.sh\n", "          # ./scripts/verify-pinned-tag.sh\n"),
        sub("          ./scripts/verify-pinned-tag.sh\n", "          ./scripts/other.sh\n"),
        sub("          ./scripts/release-validate-pin.sh\n", "          echo ./scripts/release-validate-pin.sh\n"),
        sub("          python3 -I scripts/release-source-check.py", "          : python3 -I scripts/release-source-check.py"),
        sub("    needs: verify\n", ""),
        sub("sbom-tools@sha256:954267", "sbom-tools@sha256:000000"),
        sub(SBOM_IMAGE, "ghcr.io/fulmenhq/sbom-tools:latest"),
        # Each wheel image: another digest, a moving tag, or the two swapped.
        sub("manylinux2014_x86_64@sha256:d6b534", "manylinux2014_x86_64@sha256:000000"),
        sub(MANYLINUX_AMD64, "quay.io/pypa/manylinux2014_x86_64:latest"),
        sub("manylinux2014_aarch64@sha256:d41ea3", "manylinux2014_aarch64@sha256:000000"),
        sub(MANYLINUX_ARM64, "quay.io/pypa/manylinux2014_aarch64:latest"),
        # A container only from the reviewed wheel-build step, its image the
        # operand docker runs and bound to the target (RELB-DV-04 shapes).
        sub(MANYLINUX_AMD64 + " \\", MANYLINUX_AMD64 + " && docker pull docker.io/evil/builder:latest \\"),
        sub(MANYLINUX_AMD64 + " \\", "evil-builder \\"),
        sub(MANYLINUX_AMD64 + " \\", "alpine:latest echo " + MANYLINUX_AMD64 + " \\"),
        sub(MANYLINUX_AMD64 + " \\", MANYLINUX_ARM64 + " \\"),
        sub("scripts/build-wheel.sh x86_64-unknown-linux-gnu /out", "scripts/build-wheel.sh aarch64-unknown-linux-gnu /out"),
        sub('docker run --rm --user', 'docker run --rm --privileged --user'),
        sub('-v "$PWD:/src"', '-v "/:/src"'),
        sub(run, run + "          docker exec x sh\n"),
        sub(run, run + "          /usr/bin/docker pull ghcr.io/example/builder:latest\n"),
        sub(run, run + "          /usr/bin/docker run --rm docker.io/evil/builder:latest\n"),
        sub(run, run + "          \\docker run --rm alpine\n"),
        sub(run, run + "          d'o'cker run --rm alpine\n"),
        sub(run, run + "          podman run --rm alpine\n"),
        sub(run, run + "          \"$(command -v docker)\" run --rm alpine\n"),
        sub(checkout, "      - run: /usr/bin/docker run alpine\n" + checkout),
        # Decoded escapes, flow-style container, other gh writes.
        sub(first_runs_on, first_runs_on + '    env:\n      "CARGO_REGISTRY_TO\\u004bEN": "${{ secrets[\'X\'] }}"\n'),
        sub(run, run + '          "cargo\\u0020publish --no-verify -p canonprims-core"\n'.replace("\\u0020", " ").replace('"', "")),
        sub(checkout, '      - run: "cargo\\u0020publish --no-verify -p canonprims-core"\n' + checkout),
        sub(first_runs_on, first_runs_on + "    container: {image: docker.io/evil/builder:latest}\n"),
        sub(run, run + "          gh api graphql -f query='mutation{createRelease}'\n"),
        sub(run, run + "          gh api -f sha=abc repos/x/y/git/refs\n"),
        sub(run, run + "          gh api -X DELETE repos/x/y/git/refs/tags/v1\n"),
        sub(run, run + "          (gh workflow run x)\n"),
        sub(run, run + "          /usr/bin/gh release create v1\n"),
        sub(run, run + "          \\gh release create v1\n"),
        sub(run, run + "          $'gh' release create v1\n"),
        sub(run, run + "          GH_TOKEN=x /usr/bin/gh release create v1\n"),
        # Step conditions, ignored failures, heredocs, secrets, services.
        sub(checkout, "      - if: false\n        run: true\n" + checkout),
        sub("          ./scripts/verify-pinned-tag.sh\n", "          ./scripts/verify-pinned-tag.sh || true\n"),
        sub(run, run + "          cat <<'EOF'\n          ./scripts/verify-pinned-tag.sh\n          EOF\n"),
        sub(run, run + "          echo '${{ toJSON(secrets) }}'\n"),
        sub(first_runs_on, first_runs_on + "    services:\n      db:\n        image: postgres:latest\n"),
        sub(first_runs_on, first_runs_on + "    continue-on-error: true\n"),
        sub("      matrix:\n        include:\n", "      matrix:\n        os: [self-hosted]\n        include:\n"),
        sub(run, run + "          set +e\n"),
        # The crate verification artifact is exactly the verifier's output.
        sub('canonprims-core "$RUNNER_TEMP/crate-verification"', 'canonprims-core crates'),
        sub("path: ${{ runner.temp }}/crate-verification/", "path: crates/"),
    ]


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("check", "mutations"):
        fail("usage: release-workflow-permissions.py check|mutations FILE")
    name = os.path.basename(sys.argv[2])
    if name not in PROFILES:
        fail(f"{name} is not a reviewed release workflow")
    profile = PROFILES[name]
    text = open(sys.argv[2], encoding="utf-8").read()
    check(text, profile)
    if sys.argv[1] == "mutations":
        if name == "release.yml":
            cases = mutations(text)
        elif name == "crates-verify.yml":
            cases = crates_verify_mutations(text)
        else:
            cases = registry_publish_mutations(text)
        for index, mutated in enumerate(cases):
            try:
                check(mutated, profile)
            except ValueError:
                continue
            fail(f"mutation {index} was accepted")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, yaml.YAMLError) as error:
        sys.exit(f"error: {error}")

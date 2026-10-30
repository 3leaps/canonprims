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
# What each reviewed workflow must contain beyond the shared rules: its
# container images, exactly, and the artifact boundary its verify job writes.
PROFILES = {
    "release.yml": {"images": [MANYLINUX_AMD64, MANYLINUX_ARM64, SBOM_IMAGE], "boundary": "release-identity.json"},
    "crates-verify.yml": {"images": [], "boundary": "scripts/ci-crate-verify.sh"},
    "registry-publish.yml": {
        "images": [],
        "boundary": "./scripts/release-stage-published.sh",
        "oidc": {
            "publish-pypi": {
                "environment": "publish-pypi",
                "if": "inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'pypi')",
                "actions": {"actions/checkout", "actions/download-artifact", "pypa/gh-action-pypi-publish"},
            },
            "publish-npm": {
                "environment": "publish-npm",
                "if": "inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'npm')",
                "actions": {"actions/checkout", "actions/setup-node", "actions/download-artifact"},
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


def shell_code(run):
    # A backslash-newline disappears in the shell, joining the two lines.
    joined = re.sub(r"\\\n", "", str(run))
    return "\n".join(line for line in joined.splitlines() if not line.lstrip().startswith("#"))


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
    if data.get("permissions") != {"contents": "read"}:
        fail("workflow permissions must be exactly contents: read")
    jobs = data.get("jobs")
    if not isinstance(jobs, dict) or "verify" not in jobs:
        fail("workflow jobs are missing")
    oidc_specs = profile.get("oidc") or {}
    if oidc_specs:
        trigger = data.get("on") if "on" in data else data.get(True)
        if not isinstance(trigger, dict) or set(trigger) != {"workflow_dispatch"}:
            fail("OIDC workflow must trigger on workflow_dispatch only")
        if set(jobs) != {"verify"} | set(oidc_specs):
            fail("OIDC workflow job set differs from reviewed profile")
    for value in strings(data):
        if SECRET.search(value):
            fail("workflow registry or secret access")
    images = []
    for name, job in jobs.items():
        if not isinstance(job, dict):
            fail(f"{name}: job is not a mapping")
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
        for step in steps:
            if "if" in step or "continue-on-error" in step:
                fail(f"{name}: step conditions and continue-on-error are not reviewed")
            if re.search(r"\|\|\s*(true|:)|<<-?\s*['\"]?\w|\bset\s+\+e\b", shell_code(step.get("run", ""))):
                fail(f"{name}: ignored failures and heredocs are not reviewed")
            action = step.get("uses")
            if action is not None:
                repo, sep, ref = str(action).partition("@")
                if not sep or repo not in allowed_actions or not re.fullmatch(r"[0-9a-f]{40}", ref):
                    fail("unreviewed release action")
            if FORBIDDEN_COMMANDS.search(shell_code(step.get("run", ""))):
                fail("workflow release creation or publication")
            image = container_run(shell_code(step.get("run", "")))
            if image is not None:
                images.append(image)
            for value in strings({k: v for k, v in step.items() if k != "run"}):
                if RUNTIME.search(re.sub(r"[\\'\"$`{}()]", "", value)):
                    fail("a container may start only from the reviewed wheel-build step")
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
    code = "\n".join(shell_code(s.get("run", "")) for s in jobs["verify"].get("steps") or [] if isinstance(s, dict))
    for command in MANDATORY:
        if not re.search(r"(?m)^\s*" + re.escape(command), code):
            fail("missing tag-set or anchor verification")
    if profile["boundary"] not in code:
        fail("missing artifact boundary")
    if oidc_specs:
        if not re.search(r'(?m)^\s*\./scripts/release-stage-published\.sh\s+"\$CANONPRIMS_RELEASE_TAG"\s+"\$RUNNER_TEMP/registry-stage"\s*$', code):
            fail("verify: published release staging must write to $RUNNER_TEMP/registry-stage")
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
        sub(first_runs_on, first_runs_on + "    permissions: {contents: read, packages: write}\n"),
        sub(first_runs_on, "    runs-on: ubuntu-latest\n"),
        sub(checkout, "      - uses: unknown-org/action@main\n" + checkout),
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

    first_runs_on = "    runs-on: ubuntu-24.04\n"
    return shared_mutations(text) + [
        sub("on:\n  workflow_dispatch:\n", "on:\n  push:\n    tags: ['v*']\n  workflow_dispatch:\n"),
        sub(first_runs_on, first_runs_on + "    permissions:\n      contents: read\n      id-token: write\n"),
        sub("    environment: publish-pypi\n", ""),
        sub("    environment: publish-npm\n", "    environment: publish-pypi\n"),
        sub("      id-token: write\n", "      id-token: write\n      contents: write\n"),
        sub("    if: inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'pypi')\n", ""),
        sub("    if: inputs.dry_run != true && (inputs.registry == 'all' || inputs.registry == 'npm')\n", "    if: true\n"),
        sub("    needs: verify\n", ""),
        sub('./scripts/release-stage-published.sh "$CANONPRIMS_RELEASE_TAG" "$RUNNER_TEMP/registry-stage"', "./scripts/other.sh"),
        sub('"$CANONPRIMS_RELEASE_TAG" "$RUNNER_TEMP/registry-stage"', '"$CANONPRIMS_RELEASE_TAG" dist/published'),
        sub("path: ${{ runner.temp }}/registry-stage/", "path: dist/"),
        sub("pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086", "pypa/gh-action-pypi-publish@release/v1"),
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

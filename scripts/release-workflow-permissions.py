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
    "release.yml": {"images": [SBOM_IMAGE], "boundary": "release-identity.json"},
    "crates-verify.yml": {"images": [], "boundary": "scripts/ci-crate-verify.sh"},
}
SECRET = re.compile(r"(?i)\bsecrets\b|CARGO_REGISTRY_TOKEN|NODE_AUTH_TOKEN")


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
    for value in strings(data):
        if SECRET.search(value):
            fail("workflow registry or secret access")
    images = []
    for name, job in jobs.items():
        if not isinstance(job, dict):
            fail(f"{name}: job is not a mapping")
        permissions = job.get("permissions")
        if permissions is not None and (
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
        if "services" in job or "continue-on-error" in job or "if" in job:
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
        for step in steps:
            if "if" in step or "continue-on-error" in step:
                fail(f"{name}: step conditions and continue-on-error are not reviewed")
            if re.search(r"\|\|\s*(true|:)|<<-?\s*['\"]?\w|\bset\s+\+e\b", shell_code(step.get("run", ""))):
                fail(f"{name}: ignored failures and heredocs are not reviewed")
            action = step.get("uses")
            if action is not None:
                repo, sep, ref = str(action).partition("@")
                if not sep or repo not in ACTIONS or not re.fullmatch(r"[0-9a-f]{40}", ref):
                    fail("unreviewed release action")
            if FORBIDDEN_COMMANDS.search(shell_code(step.get("run", ""))):
                fail("workflow release creation or publication")
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
        cases = mutations(text) if name == "release.yml" else crates_verify_mutations(text)
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

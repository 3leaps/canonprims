#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Manifest signing selectors bind to the verified released public material.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
directory="${1:-$root/dist/release}"
"$root/scripts/verify-staged-public.sh" "$directory"
approved="${CANONPRIMS_GPG_SIGNING_FINGERPRINT:-}"
selector="${CANONPRIMS_PGP_KEY_ID:-}"
[[ "$approved" =~ ^[0-9A-F]{40}$ && "$selector" =~ ^[0-9A-F]{40}!$ ]] || {
    echo 'error: approved primary and exact subkey required' >&2
    exit 1
}
[[ "$(awk '$1=="gpg" {print $2}' "$directory/expected-fingerprints.txt")" == "$approved" ]] || {
    echo 'error: released anchor differs from approved primary' >&2
    exit 1
}
home="${CANONPRIMS_GPG_HOMEDIR:-}"
[[ ( "$home" == /* || "$home" == [A-Za-z]:/* || "$home" == [A-Za-z]:\\* || "$home" == \\\\* ) && -d "$home" && ! -L "$home" ]] || {
    echo 'error: external signing home required' >&2
    exit 1
}
home="$(
    python3 -I - "$home" "$root" "${HOME:-}" <<'PY'
import os
import pathlib
import subprocess
import sys

probe = os.fsencode(sys.argv[1])
seps = (b"/", b"\\") if os.name == "nt" else (b"/",)
dot_seps = (b"/.", b"\\.") if os.name == "nt" else (b"/.",)
dotdot_seps = (b"/..", b"\\..") if os.name == "nt" else (b"/..",)
while True:
    if len(probe) > 1 and probe.endswith(seps):
        probe = probe[:-1]
    elif probe.endswith(dot_seps):
        probe = probe[:-2] or b"/"
    else:
        break
if probe.endswith(dotdot_seps) or os.path.islink(probe):
    print("error: external signing home required", file=sys.stderr)
    sys.exit(1)

def is_win_style(raw: str) -> bool:
    return (
        os.name == "nt"
        or os.path.sep == "\\"
        or raw.startswith("\\\\")
        or (len(raw) >= 3 and raw[0].isalpha() and raw[1:3] in (":/", ":\\"))
    )


def resolve_path(raw: bytes) -> str:
    s = os.fsdecode(raw)
    if os.name != "nt" and is_win_style(s):
        return s
    return os.fsdecode(os.path.realpath(raw))


home = pathlib.Path(resolve_path(os.fsencode(sys.argv[1])))
repo_root = pathlib.Path(resolve_path(os.fsencode(sys.argv[2])))
env_home = sys.argv[3]


def strip_line_terminator(raw: bytes) -> bytes:
    if (os.name == "nt" or os.path.sep == "\\") and raw.endswith(b"\r\n"):
        return raw[:-2]
    if raw.endswith(b"\r\n") and is_win_style(os.fsdecode(raw[:-2])):
        return raw[:-2]
    if raw.endswith(b"\n"):
        return raw[:-1]
    return raw


def same_or_within(path: pathlib.Path, target: pathlib.Path) -> bool:
    p_str = str(path)
    t_str = str(target)
    if is_win_style(p_str) or is_win_style(t_str):
        p_low = p_str.replace("\\", "/").lower().rstrip("/")
        t_low = t_str.replace("\\", "/").lower().rstrip("/")
    else:
        p_low = p_str.lower().rstrip("/")
        t_low = t_str.lower().rstrip("/")
    if p_low == t_low or p_low.startswith(t_low + "/"):
        return True
    for cur in (path, *path.parents):
        try:
            if target.exists() and cur.exists() and os.path.samefile(cur, target):
                return True
            if (
                cur.parent.exists()
                and target.parent.exists()
                and os.path.samefile(cur.parent, target.parent)
                and cur.name.lower() == target.name.lower()
            ):
                return True
        except OSError:
            continue
    return False


repo_roots = {repo_root}
try:
    wt_records = subprocess.run(
        ["git", "-C", str(repo_root), "worktree", "list", "--porcelain", "-z"],
        check=True,
        capture_output=True,
    ).stdout.split(b"\0")
except (OSError, subprocess.CalledProcessError):
    print("error: failed to enumerate repository worktrees", file=sys.stderr)
    sys.exit(1)
found_worktree = False
for rec in wt_records:
    if rec.startswith(b"worktree "):
        wt_bytes = rec[len(b"worktree ") :]
        if not wt_bytes:
            print("error: empty worktree path from git worktree list", file=sys.stderr)
            sys.exit(1)
        found_worktree = True
        repo_roots.add(pathlib.Path(os.fsdecode(os.path.realpath(wt_bytes))))
if not found_worktree:
    print("error: no repository worktrees reported by git worktree list", file=sys.stderr)
    sys.exit(1)
for git_flag in ("--git-dir", "--git-common-dir"):
    try:
        git_dir_raw = strip_line_terminator(
            subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "--path-format=absolute", git_flag],
                check=True,
                capture_output=True,
            ).stdout
        )
    except (OSError, subprocess.CalledProcessError):
        print(f"error: failed to resolve repository {git_flag}", file=sys.stderr)
        sys.exit(1)
    if not git_dir_raw:
        print(f"error: empty repository {git_flag}", file=sys.stderr)
        sys.exit(1)
    repo_roots.add(pathlib.Path(os.fsdecode(os.path.realpath(git_dir_raw))))

for r_root in repo_roots:
    if same_or_within(home, r_root):
        print("error: signing home must be outside trusted checkout", file=sys.stderr)
        sys.exit(1)

candidates = set()
for home_candidate in (
    env_home,
    os.environ.get("USERPROFILE", ""),
    (os.environ.get("HOMEDRIVE", "") + os.environ.get("HOMEPATH", "")) if os.environ.get("HOMEDRIVE") and os.environ.get("HOMEPATH") else "",
    os.path.expanduser("~"),
):
    if home_candidate and home_candidate != "~":
        candidates.add(pathlib.Path(os.path.realpath(os.path.expanduser(home_candidate))) / ".gnupg")
for appdata_candidate in (os.environ.get("APPDATA", ""), os.environ.get("LOCALAPPDATA", "")):
    if appdata_candidate:
        candidates.add(pathlib.Path(os.path.realpath(os.path.expanduser(appdata_candidate))) / "gnupg")
try:
    import pwd

    acct = pathlib.Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    candidates.add(acct / ".gnupg")
except (ImportError, AttributeError, KeyError, OSError):
    pass
env = {k: v for k, v in os.environ.items() if k != "GNUPGHOME"}
try:
    out = strip_line_terminator(
        subprocess.run(
            ["gpgconf", "--list-dirs", "homedir"],
            env=env,
            check=True,
            capture_output=True,
        ).stdout
    )
    out_str = os.fsdecode(out)
    if is_win_style(out_str) or out.startswith(b"/") or os.path.isabs(out_str):
        candidates.add(pathlib.Path(resolve_path(out)))
        candidates.add(pathlib.Path(out_str))
except (OSError, subprocess.CalledProcessError):
    pass

for cand in candidates:
    if same_or_within(home, cand):
        print("error: the default GPG home is not approved for release signing", file=sys.stderr)
        sys.exit(1)

sys.stdout.write(str(home) + "x")
PY
)"
home="${home%x}"
keyring="$(mktemp -d)"
trap 'gpgconf --homedir "$keyring" --kill all >/dev/null 2>&1 || true; rm -rf "$keyring"' EXIT
chmod 700 "$keyring"
pin_listing="$(gpg --homedir "$keyring" --batch --with-colons --with-subkey-fingerprint --show-keys "$directory/canonprims-release-signing-key.asc" 2>/dev/null)"
permitted="$(awk -F: '$1=="sub" {s=1;cap=$12;next} s && $1=="fpr" {if(cap ~ /s/) print $10; s=0}' <<<"$pin_listing")"
[[ "$permitted!" == "$selector" ]] || {
    echo 'error: selector differs from released signing subkey' >&2
    exit 1
}
listing="$(gpg --homedir "$home" --batch --with-colons --fingerprint --with-subkey-fingerprint --list-keys "${selector%!}" 2>/dev/null)"
primary="$(awk -F: '$1=="pub" {p=1;next} p && $1=="fpr" {print $10;exit}' <<<"$listing")"
subkey="$(awk -F: -v wanted="${selector%!}" '$1=="sub" {s=1;cap=$12;valid=$2;next} s && $1=="fpr" {if($10==wanted && cap ~ /s/ && valid !~ /[redi]/) print $10; s=0}' <<<"$listing")"
[[ "$primary" == "$approved" && "$subkey!" == "$selector" ]] || {
    echo 'error: configured home lacks the approved released signing subkey' >&2
    exit 1
}
echo '[ok] post-tag selector uses the approved released pin'

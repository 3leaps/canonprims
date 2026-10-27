# SPDX-License-Identifier: MIT OR Apache-2.0
"""Differential driver (docs/spec/jcs-rfc8785.md, "Conformance harness
protocol"): one hex-encoded input per stdin line, one result per stdout line,
default limits."""

import sys

import canonprims


def main() -> int:
    limits = canonprims.Limits()
    out = sys.stdout.buffer
    for raw in sys.stdin.buffer:
        # LF-terminated only: a CR is not hex and is refused, as in Rust and Go.
        line = raw[:-1] if raw.endswith(b"\n") else raw
        try:
            text = line.decode("ascii")
            if len(text) % 2 or any(c not in "0123456789abcdef" for c in text):
                raise ValueError
            data = bytes.fromhex(text)
        except ValueError:
            print("canon-diff: line is not hex", file=sys.stderr)
            return 2
        try:
            out.write(b"ok " + canonprims.canonicalize(data, limits).hex().encode() + b"\n")
        except canonprims.Refusal as r:
            out.write(r.code.encode() + b"\n")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

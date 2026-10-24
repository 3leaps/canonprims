#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate differential inputs for scripts/crosscheck.sh.

Writes one hex-encoded input per line. Inputs mix well-formed documents,
hostile numbers and strings, and byte-level mutations of both, so the two
implementations are compared on refusals as well as on output.

Usage: crosscheck-gen.py <seed> <count>
"""

from __future__ import annotations

import random
import sys

NUMBERS = [
    "0", "-0", "1", "-1", "0.1", "1e21", "1e20", "1e-6", "1e-7", "5e-324", "2.4703282292062328e-324",
    "1.7976931348623157e308", "1.7976931348623159e308", "1e400", "9007199254740992", "9007199254740993",
    "18446744073709551616", "18446744073709552000", "18446744073709552001", "295147905179352830000",
    "0.30000000000000004", "123456789012345678901234567890", "1E+2", "4.50", "-0.0e-0", "01", "1.", ".5",
    "-", "1e", "333333333.33333329", "1424953923781206.25", "9.999999999999999e22",
]
STRINGS = [
    "", "a", "\\u0000", "\\u001f", "\\u007f", "\\u2028", "\\ud83d\\ude00", "\\ud800", "\\udc00",
    "\\uD800\\u0041", "\\/", "\\\"", "\\\\", "\\b\\f\\n\\r\\t", "é", "\U0001f600", "￿", "\\x",
    "\\u12", "דּ", "€", "\r",
]


def rand_number(r: random.Random) -> str:
    pick = r.random()
    if pick < 0.4:
        return r.choice(NUMBERS)
    if pick < 0.6:
        return repr(r.uniform(-1e30, 1e30))
    if pick < 0.75:
        return f"{r.randint(-10**20, 10**20)}"
    if pick < 0.9:
        return f"{r.randint(1, 9)}.{r.randint(0, 10**17)}e{r.randint(-330, 330)}"
    return str(2 ** r.randint(50, 1030) * r.choice([1, -1]))


def rand_string(r: random.Random) -> str:
    return '"' + "".join(r.choice(STRINGS) for _ in range(r.randint(0, 4))) + '"'


def rand_value(r: random.Random, depth: int) -> str:
    pick = r.random()
    if depth > 5 or pick < 0.3:
        return r.choice(["null", "true", "false", rand_number(r), rand_string(r)])
    if pick < 0.6:
        return "[" + ",".join(rand_value(r, depth + 1) for _ in range(r.randint(0, 4))) + "]"
    names = [rand_string(r) for _ in range(r.randint(0, 5))]
    if names and r.random() < 0.05:
        names.append(r.choice(names))
    ws = r.choice(["", " ", "\n  "])
    return "{" + ",".join(f"{ws}{n}{ws}:{ws}{rand_value(r, depth + 1)}" for n in names) + "}"


def mutate(r: random.Random, data: bytes) -> bytes:
    b = bytearray(data)
    for _ in range(r.randint(1, 3)):
        op = r.random()
        if op < 0.4 and b:
            b[r.randrange(len(b))] = r.randrange(256)
        elif op < 0.7:
            b.insert(r.randint(0, len(b)), r.choice(b'[]{}",:\\0e.-u ' + bytes([0xff, 0xc0, 0xed])))
        elif b:
            del b[r.randrange(len(b))]
    return bytes(b)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(__doc__ or "")
        return 2
    r = random.Random(int(argv[1]))
    # Binary stdout: the protocol is LF-terminated lines, and text mode would
    # write CRLF on Windows.
    out = sys.stdout.buffer
    for _ in range(int(argv[2])):
        doc = rand_value(r, 0).encode("utf-8")
        if r.random() < 0.3:
            doc = mutate(r, doc)
        out.write(doc.hex().encode("ascii") + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

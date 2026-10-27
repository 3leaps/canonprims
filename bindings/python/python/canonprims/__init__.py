# SPDX-License-Identifier: MIT OR Apache-2.0
"""RFC 8785 JSON canonicalization over a strict I-JSON loader.

A thin binding over the Rust ``canonprims-json`` crate. The same four verbs as
the Rust crate and the Go package: :func:`canonicalize`, :func:`check`,
:func:`digest` and :func:`scheme_info`. Input is bytes from any object that
exports a buffer (its raw bytes, in C order); a ``str`` is encoded as UTF-8 and
nothing else. An input with no canonical form
raises :class:`Refusal` carrying one normative code; nothing is repaired.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final, Union

from . import _canonprims as _native

__all__ = [
    "CODES",
    "Limits",
    "Refusal",
    "SchemeInfo",
    "canonicalize",
    "check",
    "digest",
    "scheme_info",
]

__version__: Final[str] = _native.VERSION

Input = Union[bytes, bytearray, memoryview, str]  # or any buffer exporter

#: Every refusal code, in spec order. ``not_canonical`` comes only from check.
CODES: Final = (
    "too_large",
    "invalid_utf8",
    "invalid_json",
    "lone_surrogate",
    "noncharacter",
    "duplicate_member",
    "non_finite_number",
    "integer_outside_binary64",
    "too_deep",
    "not_canonical",
)


class Refusal(ValueError):
    """The input has no canonical form (or, from :func:`check`, is not in it).

    ``code`` is normative and identical across languages; ``offset`` is the
    informative byte offset in the input where the defect was found.
    """

    def __init__(self, code: str, offset: int) -> None:
        super().__init__(f"{code} at byte {offset}")
        self.code = code
        self.offset = offset


@dataclass(frozen=True)
class Limits:
    """Explicit resource limits; every verb takes one.

    Exceeding a limit is a ``too_large`` or ``too_deep`` refusal. A limit of 0
    allows none of that thing; a negative limit behaves as 0 (Python ints are
    signed), and a limit above the platform's ``usize`` range behaves as that
    maximum. Each limit must be an ``int`` (not ``bool``). The defaults match
    every other canonprims implementation.
    """

    max_bytes: int = _native.DEFAULT_MAX_BYTES
    max_depth: int = _native.DEFAULT_MAX_DEPTH
    max_object_members: int = _native.DEFAULT_MAX_OBJECT_MEMBERS
    max_string_bytes: int = _native.DEFAULT_MAX_STRING_BYTES

    def __post_init__(self) -> None:
        for name in ("max_bytes", "max_depth", "max_object_members", "max_string_bytes"):
            value = getattr(self, name)
            if type(value) is not int:
                raise TypeError(f"Limits.{name} must be an int, got {value!r}")

    def _args(self) -> tuple[int, int, int, int]:
        def clamp(value: int) -> int:
            return min(max(value, 0), _native.MAX_LIMIT)

        return (
            clamp(self.max_bytes),
            clamp(self.max_depth),
            clamp(self.max_object_members),
            clamp(self.max_string_bytes),
        )


@dataclass(frozen=True)
class SchemeInfo:
    """What the scheme is and which corpus gated this build."""

    scheme: str
    spec: str
    corpus: str
    corpus_digest: str


def _bytes(data: Input) -> bytes:
    if isinstance(data, str):
        return data.encode("utf-8")
    try:
        view = memoryview(data)
    except TypeError:
        raise TypeError(f"input must be bytes-like or str, not {type(data).__name__}") from None
    with view:
        return view.tobytes()


def _limits(limits: Limits) -> tuple[int, int, int, int]:
    if not isinstance(limits, Limits):
        raise TypeError(f"limits must be canonprims.Limits, not {type(limits).__name__}")
    return limits._args()


def canonicalize(data: Input, limits: Limits) -> bytes:
    """Return the RFC 8785 canonical form of a strict I-JSON text."""
    args = _limits(limits)
    try:
        return _native.canonicalize(_bytes(data), *args)
    except _native.RawRefusal as e:
        raise Refusal(*e.args) from None


def check(data: Input, limits: Limits) -> None:
    """Return if the input is already canonical; raise :class:`Refusal` if not.

    An input in the domain but not byte-identical to its canonical form is
    refused with ``not_canonical``.
    """
    args = _limits(limits)
    try:
        _native.check(_bytes(data), *args)
    except _native.RawRefusal as e:
        raise Refusal(*e.args) from None


def digest(data: Input, limits: Limits, alg: str = "sha256") -> str:
    """Hash the canonical form, written ``<alg>:<lowercase hex>``."""
    args = _limits(limits)
    try:
        return _native.digest(_bytes(data), *args, alg)
    except _native.RawRefusal as e:
        raise Refusal(*e.args) from None


def scheme_info() -> SchemeInfo:
    """The scheme, its specification, and the corpus this build was gated on."""
    return SchemeInfo(*_native.scheme_info())

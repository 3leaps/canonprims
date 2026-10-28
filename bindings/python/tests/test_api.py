# SPDX-License-Identifier: MIT OR Apache-2.0
"""The Python surface: types, the str convenience, limits and refusals."""

import array
import mmap
import tempfile
import unittest

import canonprims
from canonprims import Limits, Refusal

L = Limits()


class Api(unittest.TestCase):
    def test_bytes_and_buffers(self):
        text = b'{"b":1,"a":2}'
        with tempfile.TemporaryFile() as f:
            f.write(text)
            f.flush()
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                for data in (
                    text,
                    bytearray(text),
                    memoryview(text),
                    memoryview(b"xx" + text)[2:],
                    array.array("B", text),
                    mapped,
                ):
                    self.assertEqual(canonprims.canonicalize(data, L), b'{"a":2,"b":1}')
                    self.assertIsNone(canonprims.check(b'{"a":2,"b":1}', L))
                    self.assertTrue(canonprims.digest(data, L).startswith("sha256:"))

    def test_wide_buffer_is_its_raw_bytes(self):
        # A multi-byte item buffer contributes its bytes in C order, as bytes() would.
        wide = array.array("H", [0x2231])  # b"1\"" on little-endian, b"\"1" on big-endian
        raw = wide.tobytes()
        try:
            want = canonprims.canonicalize(raw, L)
        except Refusal as r:
            with self.assertRaises(Refusal) as cm:
                canonprims.canonicalize(wide, L)
            self.assertEqual(cm.exception.code, r.code)
        else:
            self.assertEqual(canonprims.canonicalize(wide, L), want)

    def test_str_is_utf8_only(self):
        self.assertEqual(canonprims.canonicalize('"é"', L), '"é"'.encode())
        # A lone surrogate cannot be UTF-8; it is not smuggled in as an escape.
        with self.assertRaises(UnicodeEncodeError):
            canonprims.canonicalize('"\ud800"', L)

    def test_other_input_types_are_rejected(self):
        for bad in (None, 1, ["{}"], {"a": 1}):
            with self.assertRaises(TypeError):
                canonprims.canonicalize(bad, L)

    def test_limits_are_required_and_typed(self):
        with self.assertRaises(TypeError):
            canonprims.canonicalize(b"1")  # type: ignore[call-arg]
        with self.assertRaises(TypeError):
            canonprims.canonicalize(b"1", {"max_depth": 1})  # type: ignore[arg-type]
        for bad in (1.0, True, False, "1", None):
            with self.assertRaises(TypeError):
                Limits(max_depth=bad)  # type: ignore[arg-type]

    def test_negative_limits_behave_as_zero(self):
        # docs/spec/jcs-rfc8785.md: in a signed limit type, negative behaves as 0.
        cases = (
            ("max_bytes", b"1"),  # too_large at 0
            ("max_depth", b"1"),  # a scalar is fine at 0
            ("max_depth", b"[]"),  # too_deep at 0
            ("max_object_members", b"{}"),  # admitted at 0: no member started
            ("max_object_members", b'{"a":1}'),  # too_large at 0
            ("max_string_bytes", b'""'),  # admitted at 0
            ("max_string_bytes", b'"a"'),  # too_large at 0
        )
        for field, data in cases:
            want = self.outcome(data, Limits(**{field: 0}))
            for value in (-1, -(2**70)):
                with self.subTest(field=field, data=data, value=value):
                    self.assertEqual(self.outcome(data, Limits(**{field: value})), want)
        self.assertEqual(self.outcome(b"{}", Limits(max_object_members=-1)), b"{}")
        self.assertEqual(self.outcome(b"[]", Limits(max_depth=-1)), "too_deep")

    def outcome(self, data, limits):
        try:
            return canonprims.canonicalize(data, limits)
        except Refusal as r:
            return r.code

    def test_huge_limits_behave_as_the_maximum(self):
        self.assertEqual(canonprims.canonicalize(b"[1]", Limits(max_depth=2**70, max_bytes=2**200)), b"[1]")


    def test_defaults(self):
        self.assertEqual(
            (L.max_bytes, L.max_depth, L.max_object_members, L.max_string_bytes),
            (16 * 1024 * 1024, 128, 1024 * 1024, 16 * 1024 * 1024),
        )

    def test_refusal_is_typed(self):
        with self.assertRaises(Refusal) as cm:
            canonprims.canonicalize(b'{"a":1,"a":2}', L)
        self.assertIsInstance(cm.exception, ValueError)
        self.assertEqual(cm.exception.code, "duplicate_member")
        self.assertIn(cm.exception.code, canonprims.CODES)
        self.assertIsInstance(cm.exception.offset, int)
        self.assertEqual(str(cm.exception), f"duplicate_member at byte {cm.exception.offset}")

    def test_limits_refuse(self):
        with self.assertRaises(Refusal) as cm:
            canonprims.canonicalize(b"[[1]]", Limits(max_depth=1))
        self.assertEqual(cm.exception.code, "too_deep")
        with self.assertRaises(Refusal) as cm:
            canonprims.canonicalize(b"12345", Limits(max_bytes=4))
        self.assertEqual(cm.exception.code, "too_large")

    def test_check(self):
        self.assertIsNone(canonprims.check(b'{"a":1}', L))
        with self.assertRaises(Refusal) as cm:
            canonprims.check(b'{ "a":1}', L)
        self.assertEqual(cm.exception.code, "not_canonical")

    def test_digest(self):
        self.assertEqual(
            canonprims.digest(b"1", L),
            "sha256:6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b",
        )
        with self.assertRaises(ValueError) as cm:
            canonprims.digest(b"1", L, "md5")
        self.assertNotIsInstance(cm.exception, Refusal)

    def test_scheme_info(self):
        info = canonprims.scheme_info()
        self.assertEqual((info.scheme, info.spec, info.corpus), ("jcs/rfc8785", "RFC 8785", "canonical-json/v0"))
        self.assertTrue(info.corpus_digest.startswith("sha256:"))

    def test_internal_exception_does_not_escape(self):
        try:
            canonprims.canonicalize(b"[", L)
        except Refusal as r:
            self.assertIsNone(r.__cause__)
            self.assertTrue(r.__suppress_context__)


if __name__ == "__main__":
    unittest.main()

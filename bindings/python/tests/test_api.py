# SPDX-License-Identifier: MIT OR Apache-2.0
"""The Python surface: types, the str convenience, limits and refusals."""

import unittest

import canonprims
from canonprims import Limits, Refusal

L = Limits()


class Api(unittest.TestCase):
    def test_bytes_and_buffers(self):
        for data in (b'{"b":1,"a":2}', bytearray(b'{"b":1,"a":2}'), memoryview(b'{"b":1,"a":2}')):
            self.assertEqual(canonprims.canonicalize(data, L), b'{"a":2,"b":1}')

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
        for bad in (-1, 1.0, True, "1", 2**64):
            with self.assertRaises((ValueError, OverflowError)):
                canonprims.canonicalize(b"1", Limits(max_depth=bad))

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

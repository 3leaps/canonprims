#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Verify that PyPI and npm serve the exact signed release bytes and OIDC provenance.

Usage:
  release-verify-registries.py [--expect-provenance | --bootstrap-no-provenance] STAGE_DIR VERSION [all|pypi|npm]

STAGE_DIR holds SHA256SUMS, SHA512SUMS, the five cp310-abi3 wheels, and the
npm tarball (3leaps-canonprims-VERSION.tgz) as needed for the selected
registry scope. Both registries are polled with a bounded retry when HTTP 404
is returned immediately after upload (for example, while npm's async package
scan runs). By default (--expect-provenance), PyPI PEP 740 provenance
attestations (/integrity/canonprims/VERSION/WHEEL/provenance) and npm Sigstore
provenance attestations (dist.attestations) are fetched and cryptographically
verified against the pinned Sigstore production trust root:
  - Fulcio Intermediate CA (ECDSA P-384 SHA-384) signature over the leaf X.509
    certificate, certificate validity window against Rekor integratedTime, and
    parsed ASN.1 DER X.509 v3 extensions (SubjectAltName URI exact match and
    Fulcio OIDC issuer/workflow OIDs),
  - Leaf ECDSA P-256 SHA-256 signature over the DSSE PAE framing,
  - Rekor v1 transparency log entry schema binding (intoto / dsse), logId,
    signedEntryTimestamp (ECDSA P-256 SHA-256), and RFC 6962 Merkle inclusion
    proof + signed checkpoint note verification,
  - in-toto Statement v1 subject digest and SLSA workflow identity.
Pass --bootstrap-no-provenance only for a first-time manual bootstrap upload
before Trusted Publishing is configured (refused in CI).
"""

import base64
import calendar
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WHEEL_TAGS = (
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "macosx_11_0_arm64",
    "win_amd64",
    "win_arm64",
)

EXPECTED_REPO = "3leaps/canonprims"
EXPECTED_WORKFLOW_PATH = ".github/workflows/registry-publish.yml"
EXPECTED_OIDC_ISSUER = b"https://token.actions.githubusercontent.com"
SLSA_PREDICATE_V1 = "https://slsa.dev/provenance/v1"
PYPI_PUBLISH_PREDICATE_V1 = "https://docs.pypi.org/attestations/publish/v1"
INTOTO_STATEMENT_V1 = "https://in-toto.io/Statement/v1"
DSSE_PAYLOAD_TYPE = "application/vnd.in-toto+json"

# NIST P-256 (secp256r1 / prime256v1) domain parameters (leaf certs + Rekor v1 log).
P256_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
P256_A = P256_P - 3
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
P256_G = (
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
)

# NIST P-384 (secp384r1) domain parameters (Fulcio Intermediate CA).
P384_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF
P384_A = P384_P - 3
P384_B = 0xB3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF
P384_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973
P384_G = (
    0xAA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7,
    0x3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F,
)

# ASN.1 DER prefixes and OIDs.
SPKI_P256_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
SPKI_P384_PREFIX = bytes.fromhex("3076301006072a8648ce3d020106052b8104002203620004")
ALG_ECDSA_SHA256 = bytes.fromhex("06082a8648ce3d040302")
ALG_ECDSA_SHA384 = bytes.fromhex("06082a8648ce3d040303")
OID_EXT_KEY_USAGE = bytes.fromhex("551d0f")  # 2.5.29.15
OID_EXT_BASIC_CONSTRAINTS = bytes.fromhex("551d13")  # 2.5.29.19
OID_EXT_SAN = bytes.fromhex("551d11")  # 2.5.29.17
OID_EXT_EKU = bytes.fromhex("551d25")  # 2.5.29.37
OID_FULCIO_ISSUER_V1 = bytes.fromhex("2b0601040183bf300101")  # 1.3.6.1.4.1.57264.1.1
OID_FULCIO_WORKFLOW_REPO = bytes.fromhex("2b0601040183bf300105")  # 1.3.6.1.4.1.57264.1.5
OID_FULCIO_WORKFLOW_REF = bytes.fromhex("2b0601040183bf300106")  # 1.3.6.1.4.1.57264.1.6
OID_FULCIO_ISSUER_V2 = bytes.fromhex("2b0601040183bf300108")  # 1.3.6.1.4.1.57264.1.8
OID_FULCIO_BUILD_SIGNER_URI = bytes.fromhex("2b0601040183bf300109")  # 1.3.6.1.4.1.57264.1.9
OID_FULCIO_SOURCE_REPO_URI = bytes.fromhex("2b0601040183bf30010c")  # 1.3.6.1.4.1.57264.1.12
OID_FULCIO_SOURCE_REPO_REF = bytes.fromhex("2b0601040183bf30010e")  # 1.3.6.1.4.1.57264.1.14


@dataclasses.dataclass(frozen=True)
class TrustRoot:
    fulcio_issuer_der: bytes
    fulcio_p384_pub: tuple[int, int]
    rekor_log_id_hex: str
    rekor_log_id_b64: str
    rekor_p256_pub: tuple[int, int]


# Pinned Sigstore Public Good Production Trust Root (Fulcio Intermediate CA + Rekor v1 log).
DEFAULT_TRUST_ROOT = TrustRoot(
    fulcio_issuer_der=bytes.fromhex(
        "303731153013060355040a130c73696773746f72652e646576311e301c0603550403131573696773746f72652d696e7465726d656469617465"
    ),
    fulcio_p384_pub=(
        0xF11552FF2B07F8D3AFB836723C866D8A581417D3656AB62901DF473F5BC1047D54E4257BECB492EECD19887E2713B1EF,
        0xEE9B52E8BBEF47F49393BF7C2D580CCCB949E077887C5DED1D269EC4B718A52012AF5912D0DFD1801273FFD8D60A25E7,
    ),
    rekor_log_id_hex="c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d",
    rekor_log_id_b64="wNI9atQGlz+VWfO6LRygH4QUfY/8W4RFwiT5i5WRgB0=",
    rekor_p256_pub=(
        0xD86D98FB6B5A6DD4D5E41706881231D1AF5F005C2B9016E62D21AD92CE0BDEA5,
        0xFAC98634CEE7C19E10BC52BFE2CB9E468563FFF40FDB6362E10B7D0CF7E458B7,
    ),
)


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def ec_on_curve(pt: tuple[int, int] | None, p: int, a: int, b: int) -> bool:
    if pt is None:
        return False
    x, y = pt
    return 0 <= x < p and 0 <= y < p and (y * y - (x * x * x + a * x + b)) % p == 0


def ec_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None, p: int, a: int) -> tuple[int, int] | None:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2:
        if (y1 + y2) % p == 0:
            return None
        lam = ((3 * x1 * x1 + a) * pow(2 * y1, -1, p)) % p
    else:
        lam = ((y2 - y1) * pow((x2 - x1) % p, -1, p)) % p
    x3 = (lam * lam - x1 - x2) % p
    y3 = (lam * (x1 - x3) - y1) % p
    return (x3, y3)


def ec_mul(k: int, pt: tuple[int, int] | None, p: int, a: int) -> tuple[int, int] | None:
    res: tuple[int, int] | None = None
    addend = pt
    while k > 0:
        if k & 1:
            res = ec_add(res, addend, p, a)
        addend = ec_add(addend, addend, p, a)
        k >>= 1
    return res


def p256_on_curve(pt: tuple[int, int] | None) -> bool:
    return ec_on_curve(pt, P256_P, P256_A, P256_B)


def p256_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None) -> tuple[int, int] | None:
    return ec_add(p1, p2, P256_P, P256_A)


def p256_mul(k: int, pt: tuple[int, int] | None) -> tuple[int, int] | None:
    return ec_mul(k, pt, P256_P, P256_A)


def p384_on_curve(pt: tuple[int, int] | None) -> bool:
    return ec_on_curve(pt, P384_P, P384_A, P384_B)


def p384_add(p1: tuple[int, int] | None, p2: tuple[int, int] | None) -> tuple[int, int] | None:
    return ec_add(p1, p2, P384_P, P384_A)


def p384_mul(k: int, pt: tuple[int, int] | None) -> tuple[int, int] | None:
    return ec_mul(k, pt, P384_P, P384_A)


def der_read_tlv_with_raw(buf: bytes, offset: int) -> tuple[int, bytes, bytes, int]:
    if offset + 2 > len(buf):
        fail("truncated DER structure")
    tag = buf[offset]
    length = buf[offset + 1]
    pos = offset + 2
    if length & 0x80:
        nbytes = length & 0x7F
        if nbytes == 0 or nbytes > 4 or pos + nbytes > len(buf):
            fail("invalid DER length encoding")
        length = int.from_bytes(buf[pos : pos + nbytes], "big")
        if length < 128 or (buf[pos] == 0):
            fail("non-minimal DER length encoding")
        pos += nbytes
    end = pos + length
    if end > len(buf):
        fail("DER value exceeds buffer")
    return tag, buf[pos:end], buf[offset:end], end


def der_read_tlv(buf: bytes, offset: int) -> tuple[int, bytes, int]:
    tag, body, _, end = der_read_tlv_with_raw(buf, offset)
    return tag, body, end


def parse_ecdsa_der_sig(sig: bytes, order_n: int, label: str = "ECDSA") -> tuple[int, int]:
    tag, seq, end = der_read_tlv(sig, 0)
    if tag != 0x30 or end != len(sig):
        fail(f"{label}: invalid DER ECDSA signature outer SEQUENCE")
    t1, r_bytes, p1 = der_read_tlv(seq, 0)
    t2, s_bytes, p2 = der_read_tlv(seq, p1)
    if t1 != 0x02 or t2 != 0x02 or p2 != len(seq) or not r_bytes or not s_bytes:
        fail(f"{label}: invalid DER ECDSA signature INTEGER elements")
    if (r_bytes[0] & 0x80) or (len(r_bytes) > 1 and r_bytes[0] == 0 and not (r_bytes[1] & 0x80)):
        fail(f"{label}: non-canonical DER ECDSA r integer")
    if (s_bytes[0] & 0x80) or (len(s_bytes) > 1 and s_bytes[0] == 0 and not (s_bytes[1] & 0x80)):
        fail(f"{label}: non-canonical DER ECDSA s integer")
    r = int.from_bytes(r_bytes, "big")
    s = int.from_bytes(s_bytes, "big")
    if not (1 <= r < order_n and 1 <= s < order_n):
        fail(f"{label}: ECDSA signature (r, s) out of curve order range")
    return r, s


def verify_ecdsa_digest(
    pub: tuple[int, int],
    digest: bytes,
    sig_der: bytes,
    p: int,
    a: int,
    b: int,
    n: int,
    g: tuple[int, int],
    label: str,
) -> None:
    if not ec_on_curve(pub, p, a, b):
        fail(f"{label}: public key is not on expected curve")
    r, s = parse_ecdsa_der_sig(sig_der, n, label)
    e = int.from_bytes(digest, "big")
    n_bits = n.bit_length()
    d_bits = len(digest) * 8
    if d_bits > n_bits:
        e >>= d_bits - n_bits
    e %= n
    w = pow(s, -1, n)
    u1 = (e * w) % n
    u2 = (r * w) % n
    pt = ec_add(ec_mul(u1, g, p, a), ec_mul(u2, pub, p, a), p, a)
    if pt is None or (pt[0] % n) != r:
        fail(f"{label}: cryptographic ECDSA signature verification failed")


def parse_asn1_time(tag: int, body: bytes, label: str) -> int:
    try:
        text = body.decode("ascii", errors="strict")
    except UnicodeDecodeError as err:
        fail(f"{label}: non-ASCII ASN.1 time: {err}")
    if tag == 0x17:  # UTCTime: YYMMDDHHMMSSZ
        if not re.fullmatch(r"[0-9]{12}Z", text):
            fail(f"{label}: invalid ASN.1 UTCTime {text!r}")
        yy = int(text[0:2])
        year = (2000 + yy) if yy < 50 else (1900 + yy)
        rest = text[2:12]
    elif tag == 0x18:  # GeneralizedTime: YYYYMMDDHHMMSSZ
        if not re.fullmatch(r"[0-9]{14}Z", text):
            fail(f"{label}: invalid ASN.1 GeneralizedTime {text!r}")
        year = int(text[0:4])
        rest = text[4:14]
    else:
        fail(f"{label}: unexpected ASN.1 time tag 0x{tag:02x}")
        return 0
    month = int(rest[0:2])
    day = int(rest[2:4])
    hour = int(rest[4:6])
    minute = int(rest[6:8])
    second = int(rest[8:10])
    try:
        return int(calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0)))
    except ValueError as err:
        fail(f"{label}: out-of-range ASN.1 time {text!r}: {err}")
        return 0


def decode_cert_bytes(cert_b64: str, label: str) -> bytes:
    try:
        raw = base64.b64decode(cert_b64, validate=True)
    except Exception as err:
        fail(f"{label}: invalid base64 certificate: {err}")
    if b"-----BEGIN CERTIFICATE-----" in raw:
        try:
            text = raw.decode("ascii", errors="strict")
        except UnicodeDecodeError as err:
            fail(f"{label}: non-ASCII PEM certificate: {err}")
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        if len(lines) < 3 or lines[0] != "-----BEGIN CERTIFICATE-----" or lines[-1] != "-----END CERTIFICATE-----":
            fail(f"{label}: malformed PEM certificate framing")
        body_lines = lines[1:-1]
        if any(ln.startswith("-----") for ln in body_lines):
            fail(f"{label}: multiple or nested PEM blocks are not allowed")
        try:
            return base64.b64decode("".join(body_lines), validate=True)
        except Exception as err:
            fail(f"{label}: invalid PEM certificate body: {err}")
    return raw


def verify_intermediate_cert_matches_trust_root(cert_b64: str, trust_root: TrustRoot, label: str) -> None:
    cert_der = decode_cert_bytes(cert_b64, f"{label} intermediate")
    tag, cert_seq, end = der_read_tlv(cert_der, 0)
    if tag != 0x30 or end != len(cert_der):
        fail(f"{label}: intermediate certificate is not a valid DER SEQUENCE")
    tbs_tag, tbs_body, p1 = der_read_tlv(cert_seq, 0)
    alg_tag, _, p2 = der_read_tlv(cert_seq, p1)
    sig_tag, _, p3 = der_read_tlv(cert_seq, p2)
    if tbs_tag != 0x30 or alg_tag != 0x30 or sig_tag != 0x03 or p3 != len(cert_seq):
        fail(f"{label}: malformed intermediate certificate structure")
    pos = 0
    v_tag, _, pos = der_read_tlv(tbs_body, pos)
    if v_tag != 0xA0:
        fail(f"{label}: intermediate certificate missing v3 version")
    _, _, pos = der_read_tlv(tbs_body, pos)  # serialNumber
    _, _, pos = der_read_tlv(tbs_body, pos)  # signature
    _, _, pos = der_read_tlv(tbs_body, pos)  # issuer
    _, _, pos = der_read_tlv(tbs_body, pos)  # validity
    _, _, subj_raw, pos = der_read_tlv_with_raw(tbs_body, pos)  # subject
    _, _, spki_raw, pos = der_read_tlv_with_raw(tbs_body, pos)  # subjectPublicKeyInfo
    if subj_raw != trust_root.fulcio_issuer_der:
        fail(f"{label}: intermediate certificate subject does not match trusted Fulcio CA")
    expected_spki = (
        SPKI_P384_PREFIX
        + trust_root.fulcio_p384_pub[0].to_bytes(48, "big")
        + trust_root.fulcio_p384_pub[1].to_bytes(48, "big")
    )
    if spki_raw != expected_spki:
        fail(f"{label}: intermediate certificate public key does not match trusted Fulcio CA")


def verify_x509_and_extract_p256_pubkey(
    cert_b64: str,
    version: str,
    trust_root: TrustRoot,
    label: str,
) -> tuple[tuple[int, int], bytes, int, int]:
    cert_der = decode_cert_bytes(cert_b64, label)

    tag, cert_seq, end = der_read_tlv(cert_der, 0)
    if tag != 0x30 or end != len(cert_der):
        fail(f"{label}: certificate is not a valid DER SEQUENCE")
    tbs_tag, tbs_body, tbs_raw, p1 = der_read_tlv_with_raw(cert_seq, 0)
    alg_tag, alg_body, p2 = der_read_tlv(cert_seq, p1)
    sig_tag, sig_body, p3 = der_read_tlv(cert_seq, p2)
    if tbs_tag != 0x30 or alg_tag != 0x30 or sig_tag != 0x03 or p3 != len(cert_seq):
        fail(f"{label}: malformed X.509 certificate structure")
    if alg_body != ALG_ECDSA_SHA384:
        fail(f"{label}: leaf certificate signatureAlgorithm must be ecdsa-with-SHA384")
    if len(sig_body) < 2 or sig_body[0] != 0x00:
        fail(f"{label}: invalid BIT STRING padding in certificate signatureValue")

    # 1. Parse tbsCertificate fields in exact RFC 5280 sequence.
    pos = 0
    v_tag, v_body, pos = der_read_tlv(tbs_body, pos)
    if v_tag != 0xA0 or v_body != b"\x02\x01\x02":
        fail(f"{label}: certificate must be X.509 v3")
    ser_tag, ser_body, pos = der_read_tlv(tbs_body, pos)
    if ser_tag != 0x02 or not ser_body:
        fail(f"{label}: invalid certificate serialNumber")
    inner_alg_tag, inner_alg_body, pos = der_read_tlv(tbs_body, pos)
    if inner_alg_tag != 0x30 or inner_alg_body != alg_body:
        fail(f"{label}: tbsCertificate.signature does not match outer signatureAlgorithm")
    iss_tag, _, iss_raw, pos = der_read_tlv_with_raw(tbs_body, pos)
    if iss_tag != 0x30 or iss_raw != trust_root.fulcio_issuer_der:
        fail(f"{label}: certificate issuer does not match trusted Fulcio Intermediate CA")

    val_tag, val_body, pos = der_read_tlv(tbs_body, pos)
    if val_tag != 0x30:
        fail(f"{label}: malformed certificate Validity")
    nb_tag, nb_body, vp1 = der_read_tlv(val_body, 0)
    na_tag, na_body, vp2 = der_read_tlv(val_body, vp1)
    if vp2 != len(val_body):
        fail(f"{label}: trailing bytes in certificate Validity")
    not_before = parse_asn1_time(nb_tag, nb_body, f"{label} notBefore")
    not_after = parse_asn1_time(na_tag, na_body, f"{label} notAfter")
    if not_before > not_after:
        fail(f"{label}: certificate notBefore ({not_before}) > notAfter ({not_after})")

    subj_tag, _, pos = der_read_tlv(tbs_body, pos)
    if subj_tag != 0x30:
        fail(f"{label}: invalid certificate subject Name")

    spki_tag, _, spki_raw, pos = der_read_tlv_with_raw(tbs_body, pos)
    if (
        spki_tag != 0x30
        or not spki_raw.startswith(SPKI_P256_PREFIX)
        or len(spki_raw) != len(SPKI_P256_PREFIX) + 64
    ):
        fail(f"{label}: certificate SubjectPublicKeyInfo must be uncompressed NIST P-256")
    key_bytes = spki_raw[len(SPKI_P256_PREFIX) :]
    qx = int.from_bytes(key_bytes[:32], "big")
    qy = int.from_bytes(key_bytes[32:], "big")
    pub = (qx, qy)
    if not p256_on_curve(pub):
        fail(f"{label}: certificate public key is not a valid point on P-256")
    if pub == trust_root.rekor_p256_pub:
        fail(f"{label}: leaf certificate public key must be distinct from Rekor log key")

    # Skip optional issuerUniqueID [1] / subjectUniqueID [2] if present before extensions [3].
    while pos < len(tbs_body) and tbs_body[pos] in (0x81, 0x82):
        _, _, pos = der_read_tlv(tbs_body, pos)
    if pos >= len(tbs_body):
        fail(f"{label}: X.509 v3 certificate missing extensions [3]")
    ext_wrap_tag, ext_wrap_body, pos = der_read_tlv(tbs_body, pos)
    if ext_wrap_tag != 0xA3 or pos != len(tbs_body):
        fail(f"{label}: malformed tbsCertificate extensions [3] wrapper")
    exts_tag, exts_seq, exts_end = der_read_tlv(ext_wrap_body, 0)
    if exts_tag != 0x30 or exts_end != len(ext_wrap_body):
        fail(f"{label}: malformed Extensions SEQUENCE")

    # 2. Cryptographically verify Fulcio Intermediate CA (P-384 / SHA-384) signature over tbsCertificate.
    verify_ecdsa_digest(
        trust_root.fulcio_p384_pub,
        hashlib.sha384(tbs_raw).digest(),
        sig_body[1:],
        P384_P,
        P384_A,
        P384_B,
        P384_N,
        P384_G,
        f"{label} Fulcio CA certificate signature",
    )

    # 3. Parse X.509 v3 extensions and enforce SAN + Fulcio OIDC OIDs.
    seen_oids: set[bytes] = set()
    san_uris: list[str] = []
    issuer_v1: bytes | None = None
    issuer_v2: bytes | None = None
    epos = 0
    while epos < len(exts_seq):
        etag, ebody, epos = der_read_tlv(exts_seq, epos)
        if etag != 0x30:
            fail(f"{label}: X.509 extension is not a SEQUENCE")
        oid_tag, oid_bytes, ep1 = der_read_tlv(ebody, 0)
        if oid_tag != 0x06 or not oid_bytes:
            fail(f"{label}: X.509 extension missing OID")
        if oid_bytes in seen_oids:
            fail(f"{label}: duplicate X.509 extension OID {oid_bytes.hex()}")
        seen_oids.add(oid_bytes)
        next_tag, next_body, ep2 = der_read_tlv(ebody, ep1)
        critical = False
        if next_tag == 0x01:
            if next_body not in (b"\x00", b"\xff"):
                fail(f"{label}: non-canonical DER BOOLEAN in extension criticality")
            critical = next_body == b"\xff"
            val_tag_ext, ext_val, ep3 = der_read_tlv(ebody, ep2)
        else:
            val_tag_ext, ext_val, ep3 = next_tag, next_body, ep2
        if val_tag_ext != 0x04 or ep3 != len(ebody):
            fail(f"{label}: malformed X.509 extension value OCTET STRING")

        if critical and oid_bytes not in (
            OID_EXT_KEY_USAGE,
            OID_EXT_BASIC_CONSTRAINTS,
            OID_EXT_SAN,
            OID_EXT_EKU,
        ):
            fail(f"{label}: unhandled critical X.509 extension OID {oid_bytes.hex()}")

        if oid_bytes == OID_EXT_BASIC_CONSTRAINTS:
            bc_tag, bc_body, bc_end = der_read_tlv(ext_val, 0)
            if bc_tag != 0x30 or bc_end != len(ext_val):
                fail(f"{label}: invalid BasicConstraints extension")
            if bc_body:
                ca_tag, ca_val, _ = der_read_tlv(bc_body, 0)
                if ca_tag == 0x01 and ca_val != b"\x00":
                    fail(f"{label}: leaf certificate must not have BasicConstraints CA=TRUE")
        elif oid_bytes == OID_EXT_SAN:
            gn_tag, gn_body, gn_end = der_read_tlv(ext_val, 0)
            if gn_tag != 0x30 or gn_end != len(ext_val) or not gn_body:
                fail(f"{label}: invalid SubjectAltName GeneralNames")
            gpos = 0
            while gpos < len(gn_body):
                name_tag, name_bytes, gpos = der_read_tlv(gn_body, gpos)
                if name_tag != 0x86:  # [6] uniformResourceIdentifier (IA5String)
                    fail(f"{label}: unexpected SubjectAltName entry tag 0x{name_tag:02x}")
                try:
                    san_uris.append(name_bytes.decode("ascii", errors="strict"))
                except UnicodeDecodeError as err:
                    fail(f"{label}: non-ASCII SAN URI: {err}")
        elif oid_bytes == OID_FULCIO_ISSUER_V1:
            issuer_v1 = ext_val
        elif oid_bytes == OID_FULCIO_ISSUER_V2:
            s_tag, s_body, s_end = der_read_tlv(ext_val, 0)
            if s_tag != 0x0C or s_end != len(ext_val):
                fail(f"{label}: invalid Fulcio Issuer V2 UTF8String")
            issuer_v2 = s_body
        elif oid_bytes == OID_FULCIO_WORKFLOW_REPO:
            if ext_val != EXPECTED_REPO.encode("ascii"):
                fail(f"{label}: Fulcio repository extension mismatch: {ext_val!r}")
        elif oid_bytes == OID_FULCIO_WORKFLOW_REF:
            if ext_val != f"refs/tags/v{version}".encode("ascii"):
                fail(f"{label}: Fulcio workflow ref extension mismatch: {ext_val!r}")
        elif oid_bytes == OID_FULCIO_BUILD_SIGNER_URI:
            s_tag, s_body, s_end = der_read_tlv(ext_val, 0)
            want_uri = f"https://github.com/{EXPECTED_REPO}/{EXPECTED_WORKFLOW_PATH}@refs/tags/v{version}".encode(
                "ascii"
            )
            if s_tag != 0x0C or s_end != len(ext_val) or s_body != want_uri:
                fail(f"{label}: Fulcio build signer URI extension mismatch: {s_body!r}")
        elif oid_bytes == OID_FULCIO_SOURCE_REPO_URI:
            s_tag, s_body, s_end = der_read_tlv(ext_val, 0)
            if s_tag != 0x0C or s_end != len(ext_val) or s_body != f"https://github.com/{EXPECTED_REPO}".encode("ascii"):
                fail(f"{label}: Fulcio source repository URI extension mismatch: {s_body!r}")
        elif oid_bytes == OID_FULCIO_SOURCE_REPO_REF:
            s_tag, s_body, s_end = der_read_tlv(ext_val, 0)
            if s_tag != 0x0C or s_end != len(ext_val) or s_body != f"refs/tags/v{version}".encode("ascii"):
                fail(f"{label}: Fulcio source repository ref extension mismatch: {s_body!r}")

    expected_san_uri = f"https://github.com/{EXPECTED_REPO}/{EXPECTED_WORKFLOW_PATH}@refs/tags/v{version}"
    if san_uris != [expected_san_uri]:
        fail(f"{label}: certificate missing expected workflow SAN URI {expected_san_uri} (got {san_uris!r})")

    if issuer_v1 is None and issuer_v2 is None:
        fail(f"{label}: certificate missing Fulcio GitHub OIDC issuer extension")
    if issuer_v1 is not None and issuer_v1 != EXPECTED_OIDC_ISSUER:
        fail(f"{label}: Fulcio OIDC issuer v1 mismatch: {issuer_v1!r}")
    if issuer_v2 is not None and issuer_v2 != EXPECTED_OIDC_ISSUER:
        fail(f"{label}: Fulcio OIDC issuer v2 mismatch: {issuer_v2!r}")

    return pub, cert_der, not_before, not_after


def verify_ecdsa_p256_dsse(pub: tuple[int, int], payload_bytes: bytes, sig_b64: str, label: str) -> bytes:
    try:
        sig_der = base64.b64decode(sig_b64, validate=True)
    except Exception as err:
        fail(f"{label}: invalid base64 DSSE signature: {err}")
    pae = (
        f"DSSEv1 {len(DSSE_PAYLOAD_TYPE)} {DSSE_PAYLOAD_TYPE} {len(payload_bytes)} ".encode("ascii")
        + payload_bytes
    )
    verify_ecdsa_digest(
        pub,
        hashlib.sha256(pae).digest(),
        sig_der,
        P256_P,
        P256_A,
        P256_B,
        P256_N,
        P256_G,
        f"{label} DSSE",
    )
    return sig_der


def decode_rekor_sig_field(val: object, expected_sig_der: bytes) -> bytes | None:
    if not isinstance(val, str) or not val:
        return None
    try:
        raw = base64.b64decode(val, validate=True)
    except Exception:
        return None
    if raw == expected_sig_der:
        return raw
    # Rekor's intoto v0.0.2 canonicalizedBody sometimes double-base64-encodes envelope.signatures[].sig.
    try:
        inner = base64.b64decode(raw, validate=True)
        if inner == expected_sig_der:
            return inner
    except Exception:
        pass
    return None


def decode_rekor_cert_field(val: object, label: str) -> bytes | None:
    if not isinstance(val, str) or not val:
        return None
    try:
        return decode_cert_bytes(val, label)
    except SystemExit:
        return None


def decode_merkle_hash(val: object, field_name: str, label: str) -> bytes:
    if not isinstance(val, str) or not val:
        fail(f"{label}: invalid inclusionProof {field_name}")
    try:
        raw = base64.b64decode(val, validate=True)
    except Exception as err:
        fail(f"{label}: invalid inclusionProof {field_name} base64: {err}")
    if len(raw) != 32:
        fail(f"{label}: inclusionProof {field_name} must decode to 32 bytes (got {len(raw)})")
    return raw


def verify_rekor_inclusion_proof(
    proof: dict,
    idx_val: int,
    body_bytes: bytes,
    trust_root: TrustRoot,
    label: str,
) -> None:
    proof_idx = proof.get("logIndex")
    tree_size = proof.get("treeSize")
    root_hash_b64 = proof.get("rootHash")
    hashes = proof.get("hashes")
    checkpoint = proof.get("checkpoint")
    if (
        isinstance(proof_idx, bool)
        or isinstance(tree_size, bool)
        or not isinstance(proof_idx, (int, str))
        or not isinstance(tree_size, (int, str))
        or not str(proof_idx).isdigit()
        or not str(tree_size).isdigit()
    ):
        fail(f"{label}: invalid inclusionProof logIndex or treeSize")
    p_idx = int(proof_idx)
    t_size = int(tree_size)
    # In Rekor's sharded transparency log, entry.logIndex (idx_val, authenticated by
    # the SET) is the global virtual index (sum of prior shard sizes + shard-local
    # leaf index), while inclusionProof.logIndex (p_idx) is the shard-local leaf
    # index within the current shard tree of size t_size. Thus 0 <= p_idx <= idx_val
    # and p_idx < t_size must hold, and the RFC 6962 Merkle path is evaluated at p_idx.
    if p_idx < 0 or p_idx > idx_val or t_size <= p_idx:
        fail(f"{label}: inclusionProof logIndex/treeSize mismatch ({p_idx} vs {idx_val}, treeSize={t_size})")
    root_bytes = decode_merkle_hash(root_hash_b64, "rootHash", label)
    if not isinstance(hashes, list):
        fail(f"{label}: invalid inclusionProof hashes list")
    peer_hashes = [decode_merkle_hash(h, "hashes entry", label) for h in hashes]

    # RFC 6962 §2.1.1 Merkle inclusion path verification.
    fn = p_idx
    sn = t_size - 1
    r_hash = hashlib.sha256(b"\x00" + body_bytes).digest()
    for p_hash in peer_hashes:
        if sn == 0:
            fail(f"{label}: inclusionProof path longer than tree height")
        if (fn & 1) == 1 or fn == sn:
            r_hash = hashlib.sha256(b"\x01" + p_hash + r_hash).digest()
            while (fn & 1) == 0 and fn != 0:
                fn >>= 1
                sn >>= 1
        else:
            r_hash = hashlib.sha256(b"\x01" + r_hash + p_hash).digest()
        fn >>= 1
        sn >>= 1
    if sn != 0 or r_hash != root_bytes:
        fail(f"{label}: inclusionProof Merkle root mismatch")

    if not isinstance(checkpoint, dict) or not isinstance(checkpoint.get("envelope"), str):
        fail(f"{label}: inclusionProof missing checkpoint.envelope")
    envelope = checkpoint["envelope"]
    note_body, sep, sig_section = envelope.partition("\n\n")
    if not sep or not sig_section.strip():
        fail(f"{label}: malformed Rekor checkpoint signed note")
    note_lines = note_body.split("\n")
    if len(note_lines) < 3 or not note_lines[0]:
        fail(f"{label}: truncated Rekor checkpoint note body")
    if note_lines[1] != str(t_size):
        fail(f"{label}: checkpoint treeSize {note_lines[1]!r} != {t_size}")
    try:
        cp_root = base64.b64decode(note_lines[2], validate=True)
    except Exception as err:
        fail(f"{label}: invalid checkpoint root hash base64: {err}")
    if cp_root != root_bytes:
        fail(f"{label}: checkpoint root hash does not match inclusionProof rootHash")

    expected_key_hint = bytes.fromhex(trust_root.rekor_log_id_hex[:8])
    signed_note_bytes = (note_body + "\n").encode("utf-8")
    note_digest = hashlib.sha256(signed_note_bytes).digest()
    sig_verified = False
    for raw_line in sig_section.strip().splitlines():
        line = raw_line.strip()
        if line.startswith("\u2014 "):
            line = line[2:]
        elif line.startswith("-- "):
            line = line[3:]
        else:
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        try:
            sig_raw = base64.b64decode(parts[1], validate=True)
        except Exception:
            continue
        if len(sig_raw) <= 4 or sig_raw[:4] != expected_key_hint:
            continue
        verify_ecdsa_digest(
            trust_root.rekor_p256_pub,
            note_digest,
            sig_raw[4:],
            P256_P,
            P256_A,
            P256_B,
            P256_N,
            P256_G,
            f"{label} Rekor checkpoint",
        )
        sig_verified = True
    if not sig_verified:
        fail(f"{label}: Rekor checkpoint signature missing or not signed by trusted Rekor log key")


def verify_transparency_entries(
    entries: object,
    cert_der: bytes,
    sig_der: bytes,
    payload_bytes: bytes,
    not_before: int,
    not_after: int,
    trust_root: TrustRoot,
    label: str,
) -> None:
    if not isinstance(entries, list) or not entries:
        fail(f"{label}: missing Rekor transparency log entries")
    payload_sha256 = hashlib.sha256(payload_bytes).hexdigest()

    for entry in entries:
        if not isinstance(entry, dict):
            fail(f"{label}: transparency entry is not an object")
        log_index = entry.get("logIndex")
        integrated_time = entry.get("integratedTime")
        if (
            isinstance(log_index, bool)
            or isinstance(integrated_time, bool)
            or not isinstance(log_index, (int, str))
            or not isinstance(integrated_time, (int, str))
            or not str(log_index).isdigit()
            or not str(integrated_time).isdigit()
        ):
            fail(f"{label}: transparency entry has invalid logIndex or integratedTime")
        idx_val = int(log_index)
        time_val = int(integrated_time)
        if idx_val < 0 or time_val <= 0:
            fail(f"{label}: transparency entry has invalid logIndex or integratedTime")

        # Enforce Fulcio leaf certificate validity window at Rekor integration time.
        if not (not_before <= time_val <= not_after):
            fail(
                f"{label}: Rekor integratedTime {time_val} outside certificate validity "
                f"[{not_before}, {not_after}]"
            )

        log_id_obj = entry.get("logId")
        key_id = log_id_obj.get("keyId") if isinstance(log_id_obj, dict) else None
        if key_id not in (trust_root.rekor_log_id_b64, trust_root.rekor_log_id_hex):
            fail(f"{label}: untrusted or missing Rekor logId.keyId {key_id!r}")

        canon_b64 = entry.get("canonicalizedBody")
        if not isinstance(canon_b64, str) or not canon_b64:
            fail(f"{label}: transparency entry missing canonicalizedBody")
        try:
            body_bytes = base64.b64decode(canon_b64, validate=True)
            body_doc = json.loads(body_bytes.decode("utf-8"))
        except Exception as err:
            fail(f"{label}: invalid transparency canonicalizedBody: {err}")
        if not isinstance(body_doc, dict):
            fail(f"{label}: canonicalizedBody is not a JSON object")

        kind = body_doc.get("kind")
        spec = body_doc.get("spec")
        if not isinstance(spec, dict) or kind not in ("dsse", "intoto"):
            fail(f"{label}: unexpected Rekor entry kind {kind!r}")

        if kind == "dsse":
            ph = spec.get("payloadHash")
            if (
                not isinstance(ph, dict)
                or ph.get("algorithm") != "sha256"
                or not isinstance(ph.get("value"), str)
                or ph["value"].lower() != payload_sha256
            ):
                fail(f"{label}: Rekor dsse entry payloadHash mismatch")
            sigs = spec.get("signatures")
            if not isinstance(sigs, list) or not sigs:
                fail(f"{label}: Rekor dsse entry missing spec.signatures")
            bound = any(
                isinstance(s, dict)
                and decode_rekor_sig_field(s.get("signature"), sig_der) == sig_der
                and decode_rekor_cert_field(s.get("verifier"), label) == cert_der
                for s in sigs
            )
            if not bound:
                fail(f"{label}: Rekor dsse entry does not bind leaf certificate and DSSE signature")
        else:  # kind == "intoto"
            content = spec.get("content")
            if not isinstance(content, dict):
                fail(f"{label}: Rekor intoto entry missing spec.content")
            ph = content.get("payloadHash")
            if (
                not isinstance(ph, dict)
                or ph.get("algorithm") != "sha256"
                or not isinstance(ph.get("value"), str)
                or ph["value"].lower() != payload_sha256
            ):
                fail(f"{label}: Rekor intoto entry payloadHash mismatch")
            env = content.get("envelope")
            if not isinstance(env, dict) or env.get("payloadType") != DSSE_PAYLOAD_TYPE:
                fail(f"{label}: Rekor intoto entry invalid content.envelope")
            sigs = env.get("signatures")
            if not isinstance(sigs, list) or not sigs:
                fail(f"{label}: Rekor intoto entry missing content.envelope.signatures")
            bound = any(
                isinstance(s, dict)
                and decode_rekor_sig_field(s.get("sig"), sig_der) == sig_der
                and decode_rekor_cert_field(s.get("publicKey"), label) == cert_der
                for s in sigs
            )
            if not bound:
                fail(f"{label}: Rekor intoto entry does not bind leaf certificate and DSSE signature")

        # Require an authenticated Rekor signedEntryTimestamp (SET) on every entry so
        # integratedTime is cryptographically bound by the Rekor log key before relying
        # on the leaf certificate validity check above.
        promise = entry.get("inclusionPromise")
        if (
            not isinstance(promise, dict)
            or not isinstance(promise.get("signedEntryTimestamp"), str)
            or not promise["signedEntryTimestamp"]
        ):
            fail(f"{label}: transparency entry has missing or invalid inclusionPromise")
        try:
            set_sig_der = base64.b64decode(promise["signedEntryTimestamp"], validate=True)
        except Exception as err:
            fail(f"{label}: invalid base64 signedEntryTimestamp: {err}")
        set_payload = json.dumps(
            {
                "body": canon_b64,
                "integratedTime": time_val,
                "logID": trust_root.rekor_log_id_hex,
                "logIndex": idx_val,
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        verify_ecdsa_digest(
            trust_root.rekor_p256_pub,
            hashlib.sha256(set_payload).digest(),
            set_sig_der,
            P256_P,
            P256_A,
            P256_B,
            P256_N,
            P256_G,
            f"{label} Rekor SET",
        )

        proof = entry.get("inclusionProof")
        if proof is not None:
            if not isinstance(proof, dict):
                fail(f"{label}: transparency entry has invalid inclusionProof")
            verify_rekor_inclusion_proof(proof, idx_val, body_bytes, trust_root, label)


def verify_intoto_statement(
    payload_bytes: bytes,
    version: str,
    expected_subject_names: tuple[str, ...],
    expected_digest_alg: str,
    expected_digest_hex: str,
    allowed_predicates: tuple[str, ...],
    label: str,
) -> None:
    try:
        stmt = json.loads(payload_bytes.decode("utf-8"))
    except Exception as err:
        fail(f"{label}: invalid in-toto statement JSON: {err}")
    if not isinstance(stmt, dict) or stmt.get("_type") != INTOTO_STATEMENT_V1:
        fail(f"{label}: statement _type must be {INTOTO_STATEMENT_V1!r}")
    pred_type = stmt.get("predicateType")
    if not isinstance(pred_type, str) or pred_type not in allowed_predicates:
        fail(f"{label}: unexpected statement predicateType {pred_type!r}")
    subjects = stmt.get("subject")
    if not isinstance(subjects, list) or not subjects:
        fail(f"{label}: statement missing subject list")
    subject_matched = False
    for subj in subjects:
        if not isinstance(subj, dict):
            fail(f"{label}: statement subject entry is not an object")
        name = subj.get("name")
        digests = subj.get("digest")
        if (
            isinstance(name, str)
            and name in expected_subject_names
            and isinstance(digests, dict)
            and isinstance(digests.get(expected_digest_alg), str)
            and digests[expected_digest_alg].lower() == expected_digest_hex.lower()
        ):
            subject_matched = True
    if not subject_matched:
        fail(
            f"{label}: statement subject mismatch (expected {expected_subject_names} "
            f"with {expected_digest_alg}={expected_digest_hex})"
        )

    predicate = stmt.get("predicate")
    if pred_type == PYPI_PUBLISH_PREDICATE_V1:
        if predicate is not None and predicate != {}:
            fail(f"{label}: PyPI Publish v1 statement predicate must be null or empty object")
    elif pred_type == SLSA_PREDICATE_V1:
        if not isinstance(predicate, dict):
            fail(f"{label}: statement predicate must be an object")
        build_def = predicate.get("buildDefinition")
        ext_params = build_def.get("externalParameters") if isinstance(build_def, dict) else None
        workflow = ext_params.get("workflow") if isinstance(ext_params, dict) else None
        if not isinstance(workflow, dict):
            fail(f"{label}: SLSA provenance predicate missing buildDefinition.externalParameters.workflow")
        if (
            workflow.get("repository") != f"https://github.com/{EXPECTED_REPO}"
            or workflow.get("path") != EXPECTED_WORKFLOW_PATH
            or workflow.get("ref") != f"refs/tags/v{version}"
        ):
            fail(
                f"{label}: SLSA provenance workflow mismatch: {workflow!r} "
                f"(expected https://github.com/{EXPECTED_REPO} {EXPECTED_WORKFLOW_PATH} refs/tags/v{version})"
            )
    else:
        fail(f"{label}: unsupported statement predicateType {pred_type!r}")


def read_manifest(path: pathlib.Path, width: int) -> dict[str, str]:
    if not path.is_file() or path.is_symlink():
        fail(f"missing or unsafe manifest {path}")
    entries: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, sep, name = line.partition("  ")
        if not sep or not re.fullmatch(f"[0-9a-f]{{{width}}}", digest) or name in entries:
            fail(f"malformed or duplicate entry in {path.name}: {line!r}")
        entries[name] = digest
    return entries


def fetch_json_with_retry(
    url: str,
    label: str,
    attempts: int,
    sleep_sec: float,
    accept: str = "application/json",
) -> dict:
    last_err = ""
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(
            url,
            headers={"Accept": accept, "User-Agent": "canonprims-release-verify"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not isinstance(data, dict):
                    fail(f"{label} returned non-object JSON")
                return data
        except urllib.error.HTTPError as err:
            last_err = f"HTTP {err.code}"
            if err.code == 404 and attempt < attempts:
                time.sleep(sleep_sec)
                continue
            fail(f"{label} unavailable ({last_err}) at {url}")
        except (OSError, ValueError) as err:
            fail(f"{label} request failed at {url}: {err}")
    fail(f"{label} unavailable ({last_err}) at {url}")
    return {}


def is_ci_env() -> bool:
    for key in ("GITHUB_ACTIONS", "CI"):
        val = os.environ.get(key, "").strip().lower()
        if val not in ("", "0", "false"):
            return True
    return False


def validate_registry_base_url(url: str, label: str) -> urllib.parse.SplitResult:
    try:
        parsed = urllib.parse.urlsplit(url)
    except Exception as err:
        fail(f"{label} invalid URL {url!r}: {err}")
    if (
        parsed.username is not None
        or parsed.password is not None
        or "@" in parsed.netloc
        or parsed.query
        or parsed.fragment
        or not parsed.hostname
    ):
        fail(f"{label} must not contain userinfo, query, or fragment: {url!r}")
    if parsed.scheme == "https":
        if parsed.hostname in ("127.0.0.1", "localhost", "::1"):
            fail(f"{label} https URL must not target loopback: {url!r}")
        try:
            _ = parsed.port
        except ValueError as err:
            fail(f"{label} invalid port in {url!r}: {err}")
        return parsed
    if parsed.scheme == "http":
        try:
            port = parsed.port
        except ValueError as err:
            fail(f"{label} invalid port in {url!r}: {err}")
        if (
            is_ci_env()
            or parsed.hostname != "127.0.0.1"
            or port is None
            or f"127.0.0.1:{port}" != parsed.netloc
        ):
            fail(f"{label} must use https (or loopback in synthetic tests)")
        return parsed
    fail(f"{label} must use https (or loopback in synthetic tests)")
    return parsed


def load_trust_root(api_base: str) -> TrustRoot:
    override_path = os.environ.get("CANONPRIMS_SIGSTORE_TEST_ROOT")
    if not override_path:
        return DEFAULT_TRUST_ROOT
    if is_ci_env():
        fail("CANONPRIMS_SIGSTORE_TEST_ROOT is not accepted under GitHub Actions or CI")
    parsed = validate_registry_base_url(api_base, "CANONPRIMS_SIGSTORE_TEST_ROOT API base")
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port is None:
        fail("CANONPRIMS_SIGSTORE_TEST_ROOT is only accepted with a loopback API URL")
    try:
        doc = json.loads(pathlib.Path(override_path).read_text(encoding="utf-8"))
        root = TrustRoot(
            fulcio_issuer_der=bytes.fromhex(doc["fulcio_issuer_der_hex"]),
            fulcio_p384_pub=(int(doc["fulcio_p384_qx"], 16), int(doc["fulcio_p384_qy"], 16)),
            rekor_log_id_hex=str(doc["rekor_log_id_hex"]).lower(),
            rekor_log_id_b64=str(doc["rekor_log_id_b64"]),
            rekor_p256_pub=(int(doc["rekor_p256_qx"], 16), int(doc["rekor_p256_qy"], 16)),
        )
    except Exception as err:
        fail(f"invalid CANONPRIMS_SIGSTORE_TEST_ROOT {override_path}: {err}")
    if not p384_on_curve(root.fulcio_p384_pub) or not p256_on_curve(root.rekor_p256_pub):
        fail("CANONPRIMS_SIGSTORE_TEST_ROOT contains invalid curve points")
    return root


def verify_pypi_provenance(
    integrity_base: str,
    version: str,
    wheel_name: str,
    wheel_sha256: str,
    attempts: int,
    sleep_sec: float,
    trust_root: TrustRoot,
) -> None:
    label = f"PyPI PEP 740 provenance for {wheel_name}"
    prov_doc = fetch_json_with_retry(
        f"{integrity_base}/canonprims/{version}/{wheel_name}/provenance",
        label,
        attempts,
        sleep_sec,
        accept="application/vnd.pypi.integrity.v1+json, application/json",
    )
    bundles = prov_doc.get("attestation_bundles")
    if not isinstance(bundles, list) or not bundles:
        fail(f"PyPI PEP 740 provenance missing attestation_bundles for {wheel_name}")
    verified = False
    for bundle in bundles:
        if not isinstance(bundle, dict):
            fail(f"PyPI PEP 740 attestation bundle is not an object for {wheel_name}")
        publisher = bundle.get("publisher") or {}
        attestations = bundle.get("attestations")
        if not isinstance(attestations, list) or not attestations or not all(isinstance(a, dict) for a in attestations):
            fail(f"PyPI PEP 740 bundle has empty or invalid attestations for {wheel_name}")
        if not (
            publisher.get("kind") == "GitHub"
            and publisher.get("repository") == EXPECTED_REPO
            and publisher.get("workflow") == "registry-publish.yml"
            and publisher.get("environment") == "publish-pypi"
        ):
            continue
        for att in attestations:
            if att.get("version") != 1:
                fail(f"{label}: unsupported PEP 740 attestation version {att.get('version')!r}")
            vm = att.get("verification_material")
            env = att.get("envelope")
            if not isinstance(vm, dict) or not isinstance(env, dict):
                fail(f"{label}: missing verification_material or envelope")
            cert_b64 = vm.get("certificate")
            stmt_b64 = env.get("statement")
            sig_b64 = env.get("signature")
            if not isinstance(cert_b64, str) or not isinstance(stmt_b64, str) or not isinstance(sig_b64, str):
                fail(f"{label}: missing certificate, statement, or signature strings")
            try:
                payload_bytes = base64.b64decode(stmt_b64, validate=True)
            except Exception as err:
                fail(f"{label}: invalid base64 statement: {err}")
            pub, cert_der, not_before, not_after = verify_x509_and_extract_p256_pubkey(
                cert_b64, version, trust_root, label
            )
            sig_der = verify_ecdsa_p256_dsse(pub, payload_bytes, sig_b64, label)
            verify_transparency_entries(
                vm.get("transparency_entries"),
                cert_der,
                sig_der,
                payload_bytes,
                not_before,
                not_after,
                trust_root,
                label,
            )
            verify_intoto_statement(
                payload_bytes,
                version,
                (wheel_name,),
                "sha256",
                wheel_sha256,
                (SLSA_PREDICATE_V1, PYPI_PUBLISH_PREDICATE_V1),
                label,
            )
            verified = True
    if not verified:
        fail(
            f"PyPI PEP 740 provenance publisher mismatch for {wheel_name} "
            "(expected GitHub 3leaps/canonprims registry-publish.yml publish-pypi)"
        )


def verify_npm_provenance(
    base: str,
    version: str,
    attestations: object,
    tgz_sha512: str,
    attempts: int,
    sleep_sec: float,
    trust_root: TrustRoot,
) -> None:
    label = f"npm Sigstore provenance for @3leaps/canonprims@{version}"
    if not isinstance(attestations, dict):
        fail(f"npm Sigstore provenance missing dist.attestations for @3leaps/canonprims@{version}")
    att_url = attestations.get("url")
    provenance = attestations.get("provenance")
    predicate = provenance.get("predicateType") if isinstance(provenance, dict) else None
    expected_prefix = f"{base}/-/npm/v1/attestations/"
    if (
        not isinstance(att_url, str)
        or not att_url.startswith(expected_prefix)
        or urllib.parse.unquote(att_url[len(expected_prefix) :]) != f"@3leaps/canonprims@{version}"
        or predicate != SLSA_PREDICATE_V1
    ):
        fail(
            f"npm Sigstore provenance attestation invalid for @3leaps/canonprims@{version}: "
            f"attestations={attestations!r}"
        )

    att_doc = fetch_json_with_retry(att_url, label, attempts, sleep_sec)
    att_list = att_doc.get("attestations")
    if not isinstance(att_list, list) or not att_list:
        fail(f"{label}: attestation endpoint returned no attestations")
    slsa_bundles = [
        entry.get("bundle")
        for entry in att_list
        if isinstance(entry, dict) and entry.get("predicateType") == SLSA_PREDICATE_V1
    ]
    if not slsa_bundles:
        fail(f"{label}: attestation bundle missing {SLSA_PREDICATE_V1}")

    for bundle in slsa_bundles:
        if not isinstance(bundle, dict):
            fail(f"{label}: Sigstore bundle is not an object")
        media_type = bundle.get("mediaType")
        if not isinstance(media_type, str) or not media_type.startswith("application/vnd.dev.sigstore.bundle"):
            fail(f"{label}: invalid Sigstore bundle mediaType {media_type!r}")
        vm = bundle.get("verificationMaterial")
        dsse = bundle.get("dsseEnvelope")
        if not isinstance(vm, dict) or not isinstance(dsse, dict):
            fail(f"{label}: Sigstore bundle missing verificationMaterial or dsseEnvelope")
        cert_b64 = None
        if isinstance(vm.get("certificate"), dict):
            cert_b64 = vm["certificate"].get("rawBytes")
        elif isinstance(vm.get("x509CertificateChain"), dict):
            certs = vm["x509CertificateChain"].get("certificates")
            if isinstance(certs, list) and certs and all(isinstance(c, dict) for c in certs):
                cert_b64 = certs[0].get("rawBytes")
                for extra_cert in certs[1:]:
                    raw_extra = extra_cert.get("rawBytes")
                    if not isinstance(raw_extra, str) or not raw_extra:
                        fail(f"{label}: invalid intermediate certificate entry in x509CertificateChain")
                    verify_intermediate_cert_matches_trust_root(raw_extra, trust_root, label)
        if not isinstance(cert_b64, str) or not cert_b64:
            fail(f"{label}: Sigstore bundle missing certificate rawBytes")

        if dsse.get("payloadType") != DSSE_PAYLOAD_TYPE:
            fail(f"{label}: DSSE payloadType must be {DSSE_PAYLOAD_TYPE!r}")
        payload_b64 = dsse.get("payload")
        sigs = dsse.get("signatures")
        if (
            not isinstance(payload_b64, str)
            or not isinstance(sigs, list)
            or len(sigs) != 1
            or not isinstance(sigs[0], dict)
            or not isinstance(sigs[0].get("sig"), str)
        ):
            fail(f"{label}: invalid DSSE payload or signatures")
        try:
            payload_bytes = base64.b64decode(payload_b64, validate=True)
        except Exception as err:
            fail(f"{label}: invalid base64 DSSE payload: {err}")

        pub, cert_der, not_before, not_after = verify_x509_and_extract_p256_pubkey(
            cert_b64, version, trust_root, label
        )
        sig_der = verify_ecdsa_p256_dsse(pub, payload_bytes, sigs[0]["sig"], label)
        verify_transparency_entries(
            vm.get("tlogEntries"),
            cert_der,
            sig_der,
            payload_bytes,
            not_before,
            not_after,
            trust_root,
            label,
        )
        verify_intoto_statement(
            payload_bytes,
            version,
            (
                f"pkg:npm/%403leaps/canonprims@{version}",
                f"pkg:npm/@3leaps/canonprims@{version}",
            ),
            "sha512",
            tgz_sha512,
            (SLSA_PREDICATE_V1,),
            label,
        )


def verify_pypi(
    stage: pathlib.Path,
    version: str,
    sha256s: dict[str, str],
    attempts: int,
    sleep_sec: float,
    expect_provenance: bool,
) -> None:
    if is_ci_env() and "CANONPRIMS_PYPI_API_URL" in os.environ:
        fail("CANONPRIMS_PYPI_API_URL is not accepted under GitHub Actions")
    base = os.environ.get("CANONPRIMS_PYPI_API_URL", "https://pypi.org/pypi").rstrip("/")
    validate_registry_base_url(base, "PyPI API URL")
    integrity_base = (base[:-5] if base.endswith("/pypi") else base) + "/integrity"
    trust_root = load_trust_root(base)

    expected_wheels = {f"canonprims-{version}-cp310-abi3-{tag}.whl" for tag in WHEEL_TAGS}
    for name in sorted(expected_wheels):
        if name not in sha256s:
            fail(f"SHA256SUMS missing {name}")
        wheel = stage / name
        if not wheel.is_file() or wheel.is_symlink():
            fail(f"staged wheel missing: {name}")
        if hashlib.sha256(wheel.read_bytes()).hexdigest() != sha256s[name]:
            fail(f"staged wheel sha256 mismatch for {name}")

    ver_doc = fetch_json_with_retry(
        f"{base}/canonprims/{version}/json", f"PyPI canonprims=={version}", attempts, sleep_sec
    )
    info = ver_doc.get("info") or {}
    if info.get("name") != "canonprims" or info.get("version") != version:
        fail(f"PyPI info mismatch: name={info.get('name')!r} version={info.get('version')!r}")

    ownership = ver_doc.get("ownership") or {}
    org = ownership.get("organization")
    if org != "3leaps":
        proj_doc = fetch_json_with_retry(f"{base}/canonprims/json", "PyPI canonprims project", attempts, sleep_sec)
        org = (proj_doc.get("ownership") or {}).get("organization")
    if org != "3leaps":
        fail(f"PyPI project ownership organization must be '3leaps', got {org!r}")

    urls = ver_doc.get("urls")
    if not isinstance(urls, list):
        fail("PyPI response missing urls list")
    published: dict[str, str] = {}
    for entry in urls:
        if not isinstance(entry, dict):
            fail("PyPI urls entry is not an object")
        filename = entry.get("filename")
        if not isinstance(filename, str) or filename in published:
            fail(f"invalid or duplicate PyPI filename {filename!r}")
        if entry.get("yanked"):
            fail(f"PyPI file {filename} is yanked")
        digest = (entry.get("digests") or {}).get("sha256")
        if not isinstance(digest, str):
            fail(f"PyPI file {filename} missing sha256 digest")
        published[filename] = digest

    if set(published) != expected_wheels:
        fail(f"PyPI wheel set differs: expected {sorted(expected_wheels)}, got {sorted(published)}")
    for name in sorted(expected_wheels):
        if published[name] != sha256s[name]:
            fail(f"PyPI sha256 mismatch for {name}: {published[name]} != {sha256s[name]}")
        if expect_provenance:
            verify_pypi_provenance(integrity_base, version, name, sha256s[name], attempts, sleep_sec, trust_root)
    prov_note = ", PEP 740 provenance verified" if expect_provenance else ", bootstrap (no provenance)"
    print(f"[ok] PyPI canonprims=={version}: 5 wheels match signed SHA256SUMS (org: 3leaps{prov_note})")


def verify_npm(
    stage: pathlib.Path,
    version: str,
    sha256s: dict[str, str],
    sha512s: dict[str, str],
    attempts: int,
    sleep_sec: float,
    expect_provenance: bool,
) -> None:
    if is_ci_env() and "CANONPRIMS_NPM_REGISTRY_URL" in os.environ:
        fail("CANONPRIMS_NPM_REGISTRY_URL is not accepted under GitHub Actions")
    base = os.environ.get("CANONPRIMS_NPM_REGISTRY_URL", "https://registry.npmjs.org").rstrip("/")
    validate_registry_base_url(base, "npm registry URL")
    trust_root = load_trust_root(base)

    tgz_name = f"3leaps-canonprims-{version}.tgz"
    if tgz_name not in sha256s or tgz_name not in sha512s:
        fail(f"checksum manifests missing {tgz_name}")
    tgz = stage / tgz_name
    if not tgz.is_file() or tgz.is_symlink():
        fail(f"staged npm tarball missing: {tgz_name}")
    raw = tgz.read_bytes()
    if hashlib.sha256(raw).hexdigest() != sha256s[tgz_name]:
        fail(f"staged tarball sha256 mismatch for {tgz_name}")
    if hashlib.sha512(raw).hexdigest() != sha512s[tgz_name]:
        fail(f"staged tarball sha512 mismatch for {tgz_name}")

    want_integrity = "sha512-" + base64.b64encode(hashlib.sha512(raw).digest()).decode("ascii")
    want_shasum = hashlib.sha1(raw).hexdigest()

    doc = fetch_json_with_retry(
        f"{base}/%403leaps%2Fcanonprims/{version}",
        f"npm @3leaps/canonprims@{version}",
        attempts,
        sleep_sec,
    )
    if doc.get("name") != "@3leaps/canonprims" or doc.get("version") != version:
        fail(f"npm metadata mismatch: name={doc.get('name')!r} version={doc.get('version')!r}")
    dist = doc.get("dist") or {}
    if dist.get("integrity") != want_integrity:
        fail(f"npm dist.integrity mismatch: {dist.get('integrity')!r} != {want_integrity!r}")
    if dist.get("shasum") != want_shasum:
        fail(f"npm dist.shasum mismatch: {dist.get('shasum')!r} != {want_shasum!r}")
    if expect_provenance:
        verify_npm_provenance(base, version, dist.get("attestations"), sha512s[tgz_name], attempts, sleep_sec, trust_root)
    prov_note = ", Sigstore provenance verified" if expect_provenance else ", bootstrap (no provenance)"
    print(f"[ok] npm @3leaps/canonprims@{version}: dist.integrity and shasum match signed {tgz_name}{prov_note}")


def main() -> None:
    expect_flag = False
    bootstrap_flag = False
    positional: list[str] = []
    for arg in sys.argv[1:]:
        if arg == "--expect-provenance":
            expect_flag = True
        elif arg == "--bootstrap-no-provenance":
            bootstrap_flag = True
        elif arg.startswith("-"):
            fail(f"unknown option {arg!r}")
        else:
            positional.append(arg)
    if expect_flag and bootstrap_flag:
        fail("cannot combine --expect-provenance and --bootstrap-no-provenance")
    if bootstrap_flag and is_ci_env():
        fail("--bootstrap-no-provenance is not accepted under GitHub Actions or CI")
    expect_provenance = not bootstrap_flag

    if len(positional) not in (2, 3):
        fail(
            "usage: release-verify-registries.py [--expect-provenance | --bootstrap-no-provenance] "
            "STAGE_DIR VERSION [all|pypi|npm]"
        )
    stage = pathlib.Path(positional[0])
    version = positional[1]
    scope = positional[2] if len(positional) == 3 else "all"
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        fail(f"invalid semantic version {version!r}")
    if scope not in ("all", "pypi", "npm"):
        fail(f"unknown registry scope {scope!r} (all, pypi, or npm)")

    attempts = int(os.environ.get("CANONPRIMS_REGISTRY_POLL_ATTEMPTS", "12"))
    sleep_sec = float(os.environ.get("CANONPRIMS_REGISTRY_POLL_SLEEP", "10"))
    if attempts < 1 or sleep_sec < 0:
        fail("invalid poll settings")

    sha256s = read_manifest(stage / "SHA256SUMS", 64)
    sha512s = read_manifest(stage / "SHA512SUMS", 128)
    if scope in ("all", "pypi"):
        verify_pypi(stage, version, sha256s, attempts, sleep_sec, expect_provenance)
    if scope in ("all", "npm"):
        verify_npm(stage, version, sha256s, sha512s, attempts, sleep_sec, expect_provenance)


if __name__ == "__main__":
    main()

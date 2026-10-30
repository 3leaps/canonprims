#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Synthetic controls for scripts/release-verify-registries.py and
# scripts/pack-npm-redirector.sh against a loopback HTTP server.
set -euo pipefail
unset GITHUB_ACTIONS CI CANONPRIMS_PYPI_API_URL CANONPRIMS_NPM_REGISTRY_URL CANONPRIMS_SIGSTORE_TEST_ROOT

root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch="$(mktemp -d)"
mkdir -p "$scratch/http" "$scratch/stage"
python3 -u -m http.server -d "$scratch/http" -b 127.0.0.1 0 >"$scratch/server.log" 2>&1 &
server=$!
trap 'rc=$?; kill "$server" 2>/dev/null || true; rm -rf "$scratch"; exit "$rc"' EXIT
for _ in $(seq 1 50); do grep -q 'Serving HTTP' "$scratch/server.log" && break; sleep 0.1; done
port="$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$scratch/server.log" | head -1)"
[[ -n "$port" ]] || { echo "error: test server did not start" >&2; exit 1; }

version="0.1.2"
stage="$scratch/stage"
pypi_base="http://127.0.0.1:$port/pypi"
npm_base="http://127.0.0.1:$port/npm"
test_root_file="$scratch/test-trust-root.json"

python3 -I -B - "$stage" "$scratch/http" "$version" "$npm_base" "$root/scripts/release-verify-registries.py" "$test_root_file" <<'PY'
import base64
import hashlib
import importlib.util
import json
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
http = pathlib.Path(sys.argv[2])
version = sys.argv[3]
npm_base = sys.argv[4]
mod_path = sys.argv[5]
test_root_path = pathlib.Path(sys.argv[6])

spec = importlib.util.spec_from_file_location("rvr", mod_path)
rvr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rvr)


def der_tlv(tag: int, body: bytes) -> bytes:
    n = len(body)
    if n < 128:
        hdr = bytes([tag, n])
    else:
        len_bytes = n.to_bytes((n.bit_length() + 7) // 8, "big")
        hdr = bytes([tag, 0x80 | len(len_bytes)]) + len_bytes
    return hdr + body


def der_int(val: int) -> bytes:
    raw = val.to_bytes(max(1, (val.bit_length() + 7) // 8), "big")
    if raw[0] & 0x80:
        raw = b"\x00" + raw
    return der_tlv(0x02, raw)


def ecdsa_sign(priv_d: int, digest: bytes, n: int, g: tuple[int, int], p: int, a: int, k: int = 11) -> bytes:
    e = int.from_bytes(digest, "big")
    n_bits = n.bit_length()
    d_bits = len(digest) * 8
    if d_bits > n_bits:
        e >>= d_bits - n_bits
    e %= n
    r_pt = rvr.ec_mul(k, g, p, a)
    assert r_pt is not None
    r = r_pt[0] % n
    s = (pow(k, -1, n) * (e + r * priv_d)) % n
    return der_tlv(0x30, der_int(r) + der_int(s))


# 1. Deterministic test Fulcio Intermediate CA (P-384), Rekor v1 log (P-256), and leaf (P-256) keys.
ca_priv_d = 13
ca_pub = rvr.p384_mul(ca_priv_d, rvr.P384_G)
assert ca_pub is not None

rekor_priv_d = 19
rekor_pub = rvr.p256_mul(rekor_priv_d, rvr.P256_G)
assert rekor_pub is not None
rekor_spki = (
    rvr.SPKI_P256_PREFIX
    + rekor_pub[0].to_bytes(32, "big")
    + rekor_pub[1].to_bytes(32, "big")
)
rekor_log_id_bytes = hashlib.sha256(rekor_spki).digest()
rekor_log_id_hex = rekor_log_id_bytes.hex()
rekor_log_id_b64 = base64.b64encode(rekor_log_id_bytes).decode("ascii")

leaf_priv_d = 7
leaf_pub = rvr.p256_mul(leaf_priv_d, rvr.P256_G)
assert leaf_pub is not None
leaf_spki = (
    rvr.SPKI_P256_PREFIX
    + leaf_pub[0].to_bytes(32, "big")
    + leaf_pub[1].to_bytes(32, "big")
)

issuer_der = rvr.DEFAULT_TRUST_ROOT.fulcio_issuer_der

test_root_path.write_text(
    json.dumps(
        {
            "fulcio_issuer_der_hex": issuer_der.hex(),
            "fulcio_p384_qx": hex(ca_pub[0]),
            "fulcio_p384_qy": hex(ca_pub[1]),
            "rekor_log_id_hex": rekor_log_id_hex,
            "rekor_log_id_b64": rekor_log_id_b64,
            "rekor_p256_qx": hex(rekor_pub[0]),
            "rekor_p256_qy": hex(rekor_pub[1]),
        }
    ),
    encoding="utf-8",
)


def make_ext(oid: bytes, val_bytes: bytes, critical: bool = False) -> bytes:
    body = der_tlv(0x06, oid)
    if critical:
        body += der_tlv(0x01, b"\xff")
    body += der_tlv(0x04, val_bytes)
    return der_tlv(0x30, body)


def make_test_cert_b64(
    ver: str,
    repo: str = "3leaps/canonprims",
    signer_d: int = ca_priv_d,
    subject_cn: bytes = b"sigstore-leaf",
    include_workflow_oids: bool = True,
) -> tuple[str, bytes]:
    san_uri = f"https://github.com/{repo}/.github/workflows/registry-publish.yml@refs/tags/v{ver}".encode("ascii")
    san_ext_val = der_tlv(0x30, der_tlv(0x86, san_uri))
    bc_ext_val = der_tlv(0x30, b"")
    exts_list = [
        make_ext(rvr.OID_EXT_BASIC_CONSTRAINTS, bc_ext_val, critical=True),
        make_ext(rvr.OID_EXT_SAN, san_ext_val, critical=True),
        make_ext(rvr.OID_FULCIO_ISSUER_V1, rvr.EXPECTED_OIDC_ISSUER),
        make_ext(rvr.OID_FULCIO_ISSUER_V2, der_tlv(0x0C, rvr.EXPECTED_OIDC_ISSUER)),
    ]
    if include_workflow_oids:
        exts_list.extend(
            [
                make_ext(rvr.OID_FULCIO_WORKFLOW_REPO, repo.encode("ascii")),
                make_ext(rvr.OID_FULCIO_WORKFLOW_REF, f"refs/tags/v{ver}".encode("ascii")),
                make_ext(rvr.OID_FULCIO_BUILD_SIGNER_URI, der_tlv(0x0C, san_uri)),
                make_ext(rvr.OID_FULCIO_SOURCE_REPO_URI, der_tlv(0x0C, f"https://github.com/{repo}".encode("ascii"))),
                make_ext(rvr.OID_FULCIO_SOURCE_REPO_REF, der_tlv(0x0C, f"refs/tags/v{ver}".encode("ascii"))),
            ]
        )
    exts = der_tlv(0xA3, der_tlv(0x30, b"".join(exts_list)))
    alg = der_tlv(0x30, rvr.ALG_ECDSA_SHA384)
    # 1700000000 == 2023-11-14T22:13:20Z -> validity [231114221000Z, 231114222000Z]
    validity = der_tlv(0x30, der_tlv(0x17, b"231114221000Z") + der_tlv(0x17, b"231114222000Z"))
    subj = der_tlv(
        0x30,
        der_tlv(0x31, der_tlv(0x30, der_tlv(0x06, bytes.fromhex("550403")) + der_tlv(0x0C, subject_cn))),
    )
    tbs = der_tlv(
        0x30,
        der_tlv(0xA0, b"\x02\x01\x02")
        + der_int(1001)
        + alg
        + issuer_der
        + validity
        + subj
        + leaf_spki
        + exts,
    )
    ca_sig = ecdsa_sign(
        signer_d,
        hashlib.sha384(tbs).digest(),
        rvr.P384_N,
        rvr.P384_G,
        rvr.P384_P,
        rvr.P384_A,
    )
    cert_der = der_tlv(0x30, tbs + alg + der_tlv(0x03, b"\x00" + ca_sig))
    return base64.b64encode(cert_der).decode("ascii"), cert_der


def sign_dsse_pae(payload_bytes: bytes) -> tuple[str, bytes]:
    pae = (
        f"DSSEv1 {len(rvr.DSSE_PAYLOAD_TYPE)} {rvr.DSSE_PAYLOAD_TYPE} {len(payload_bytes)} ".encode("ascii")
        + payload_bytes
    )
    sig_der = ecdsa_sign(
        leaf_priv_d,
        hashlib.sha256(pae).digest(),
        rvr.P256_N,
        rvr.P256_G,
        rvr.P256_P,
        rvr.P256_A,
    )
    return base64.b64encode(sig_der).decode("ascii"), sig_der


def make_tlog_entry(
    cert_der: bytes,
    sig_der: bytes,
    payload_bytes: bytes,
    kind: str = "dsse",
    integrated_time: int = 1700000000,
    shard_offset: int = 0,
) -> dict:
    payload_sha256 = hashlib.sha256(payload_bytes).hexdigest()
    cert_b64_der = base64.b64encode(cert_der).decode("ascii")
    pem_block = (
        "-----BEGIN CERTIFICATE-----\n"
        + "\n".join(cert_b64_der[i : i + 64] for i in range(0, len(cert_b64_der), 64))
        + "\n-----END CERTIFICATE-----\n"
    ).encode("ascii")
    cert_b64_pem = base64.b64encode(pem_block).decode("ascii")
    sig_b64 = base64.b64encode(sig_der).decode("ascii")

    if kind == "dsse":
        body = {
            "apiVersion": "0.0.1",
            "kind": "dsse",
            "spec": {
                "payloadHash": {"algorithm": "sha256", "value": payload_sha256},
                "signatures": [{"signature": sig_b64, "verifier": cert_b64_pem}],
            },
        }
    else:
        body = {
            "apiVersion": "0.0.2",
            "kind": "intoto",
            "spec": {
                "content": {
                    "envelope": {
                        "payloadType": rvr.DSSE_PAYLOAD_TYPE,
                        "signatures": [
                            {
                                "publicKey": cert_b64_pem,
                                "sig": base64.b64encode(sig_b64.encode("ascii")).decode("ascii"),
                            }
                        ],
                    },
                    "payloadHash": {"algorithm": "sha256", "value": payload_sha256},
                }
            },
        }

    body_bytes = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
    canon_b64 = base64.b64encode(body_bytes).decode("ascii")
    proof_idx = 1
    idx_val = shard_offset + proof_idx

    # 1. Sign Rekor inclusionPromise (signedEntryTimestamp) over global virtual logIndex.
    set_payload = json.dumps(
        {
            "body": canon_b64,
            "integratedTime": integrated_time,
            "logID": rekor_log_id_hex,
            "logIndex": idx_val,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    set_sig_der = ecdsa_sign(
        rekor_priv_d,
        hashlib.sha256(set_payload).digest(),
        rvr.P256_N,
        rvr.P256_G,
        rvr.P256_P,
        rvr.P256_A,
    )

    # 2. Build RFC 6962 2-leaf Merkle tree (leaf 0 = sibling, leaf 1 = body_bytes) and sign checkpoint note.
    sibling_hash = hashlib.sha256(b"\x00sibling-leaf").digest()
    leaf_hash = hashlib.sha256(b"\x00" + body_bytes).digest()
    root_bytes = hashlib.sha256(b"\x01" + sibling_hash + leaf_hash).digest()
    tree_size = 2
    note_body = f"rekor.sigstore.dev - 1\n{tree_size}\n{base64.b64encode(root_bytes).decode('ascii')}"
    cp_sig_der = ecdsa_sign(
        rekor_priv_d,
        hashlib.sha256((note_body + "\n").encode("utf-8")).digest(),
        rvr.P256_N,
        rvr.P256_G,
        rvr.P256_P,
        rvr.P256_A,
    )
    key_hint = rekor_log_id_bytes[:4]
    cp_sig_b64 = base64.b64encode(key_hint + cp_sig_der).decode("ascii")
    envelope = f"{note_body}\n\n\u2014 rekor.sigstore.dev {cp_sig_b64}\n"

    return {
        "logIndex": idx_val,
        "logId": {"keyId": rekor_log_id_b64},
        "integratedTime": integrated_time,
        "inclusionPromise": {"signedEntryTimestamp": base64.b64encode(set_sig_der).decode("ascii")},
        "inclusionProof": {
            "logIndex": proof_idx,
            "rootHash": base64.b64encode(root_bytes).decode("ascii"),
            "treeSize": tree_size,
            "hashes": [base64.b64encode(sibling_hash).decode("ascii")],
            "checkpoint": {"envelope": envelope},
        },
        "canonicalizedBody": canon_b64,
    }


def make_slsa_statement(subj_name: str, alg: str, digest_hex: str, ver: str) -> bytes:
    stmt = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": subj_name, "digest": {alg: digest_hex}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "externalParameters": {
                    "workflow": {
                        "repository": "https://github.com/3leaps/canonprims",
                        "path": ".github/workflows/registry-publish.yml",
                        "ref": f"refs/tags/v{ver}",
                    }
                }
            }
        },
    }
    return json.dumps(stmt, separators=(",", ":")).encode("utf-8")


def make_pypi_publish_statement(subject_name: str, digest_hex: str, predicate_mode: str = "null") -> bytes:
    stmt: dict = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": subject_name, "digest": {"sha256": digest_hex}}],
        "predicateType": "https://docs.pypi.org/attestations/publish/v1",
    }
    if predicate_mode == "null":
        stmt["predicate"] = None
    elif predicate_mode == "empty":
        stmt["predicate"] = {}
    elif predicate_mode != "absent":
        stmt["predicate"] = {"unexpected": predicate_mode}
    return json.dumps(stmt, separators=(",", ":")).encode("utf-8")


cert_b64, cert_der = make_test_cert_b64(version)

tags = (
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "macosx_11_0_arm64",
    "win_amd64",
    "win_arm64",
)
sha256_lines = []
sha512_lines = []
urls = []
for i, tag in enumerate(tags):
    name = f"canonprims-{version}-cp310-abi3-{tag}.whl"
    data = f"wheel-{i}-{tag}\n".encode("utf-8")
    (stage / name).write_bytes(data)
    d256 = hashlib.sha256(data).hexdigest()
    d512 = hashlib.sha512(data).hexdigest()
    sha256_lines.append(f"{d256}  {name}")
    sha512_lines.append(f"{d512}  {name}")
    urls.append({"filename": name, "yanked": False, "digests": {"sha256": d256}})
    prov_dir = http / "integrity" / "canonprims" / version / name
    prov_dir.mkdir(parents=True, exist_ok=True)
    if i == 0:
        stmt_bytes = make_pypi_publish_statement(name, d256, "null")
    elif i == 1:
        stmt_bytes = make_pypi_publish_statement(name, d256, "absent")
    elif i == 2:
        stmt_bytes = make_pypi_publish_statement(name, d256, "empty")
    else:
        stmt_bytes = make_slsa_statement(name, "sha256", d256, version)
    sig_b64, sig_der = sign_dsse_pae(stmt_bytes)
    prov_doc = {
        "version": 1,
        "attestation_bundles": [
            {
                "publisher": {
                    "kind": "GitHub",
                    "repository": "3leaps/canonprims",
                    "workflow": "registry-publish.yml",
                    "environment": "publish-pypi",
                },
                "attestations": [
                    {
                        "version": 1,
                        "verification_material": {
                            "certificate": cert_b64,
                            "transparency_entries": [
                                make_tlog_entry(
                                    cert_der,
                                    sig_der,
                                    stmt_bytes,
                                    kind="intoto",
                                    shard_offset=121904262 if i == 0 else 0,
                                )
                            ],
                        },
                        "envelope": {
                            "statement": base64.b64encode(stmt_bytes).decode("ascii"),
                            "signature": sig_b64,
                        },
                    }
                ],
            }
        ],
    }
    (prov_dir / "provenance").write_text(json.dumps(prov_doc), encoding="utf-8")

tgz_name = f"3leaps-canonprims-{version}.tgz"
tgz_data = b"npm-tarball-bytes\n"
(stage / tgz_name).write_bytes(tgz_data)
tgz_sha256 = hashlib.sha256(tgz_data).hexdigest()
tgz_sha512 = hashlib.sha512(tgz_data).hexdigest()
sha256_lines.append(f"{tgz_sha256}  {tgz_name}")
sha512_lines.append(f"{tgz_sha512}  {tgz_name}")

(stage / "SHA256SUMS").write_text("\n".join(sorted(sha256_lines)) + "\n", encoding="utf-8")
(stage / "SHA512SUMS").write_text("\n".join(sorted(sha512_lines)) + "\n", encoding="utf-8")

pypi_ver = http / "pypi" / "canonprims" / version
pypi_ver.mkdir(parents=True, exist_ok=True)
pypi_doc = {
    "info": {"name": "canonprims", "version": version},
    "ownership": {"organization": "3leaps", "roles": []},
    "urls": urls,
}
(pypi_ver / "json").write_text(json.dumps(pypi_doc), encoding="utf-8")
(http / "pypi" / "canonprims" / "json").write_text(json.dumps(pypi_doc), encoding="utf-8")

npm_dir = http / "npm" / "@3leaps" / "canonprims"
npm_dir.mkdir(parents=True, exist_ok=True)
integrity = "sha512-" + base64.b64encode(hashlib.sha512(tgz_data).digest()).decode("ascii")
shasum = hashlib.sha1(tgz_data).hexdigest()
npm_doc = {
    "name": "@3leaps/canonprims",
    "version": version,
    "dist": {
        "integrity": integrity,
        "shasum": shasum,
        "attestations": {
            "url": f"{npm_base}/-/npm/v1/attestations/@3leaps%2Fcanonprims@{version}",
            "provenance": {"predicateType": "https://slsa.dev/provenance/v1"},
        },
    },
}
(npm_dir / version).write_text(json.dumps(npm_doc), encoding="utf-8")

npm_att_dir = http / "npm" / "-" / "npm" / "v1" / "attestations" / "@3leaps"
npm_att_dir.mkdir(parents=True, exist_ok=True)
npm_stmt_bytes = make_slsa_statement(f"pkg:npm/%403leaps/canonprims@{version}", "sha512", tgz_sha512, version)
npm_sig_b64, npm_sig_der = sign_dsse_pae(npm_stmt_bytes)
npm_att_doc = {
    "attestations": [
        {
            "predicateType": "https://slsa.dev/provenance/v1",
            "bundle": {
                "mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.1",
                "verificationMaterial": {
                    "certificate": {"rawBytes": cert_b64},
                    "tlogEntries": [
                        make_tlog_entry(cert_der, npm_sig_der, npm_stmt_bytes, kind="dsse", shard_offset=121904262)
                    ],
                },
                "dsseEnvelope": {
                    "payloadType": "application/vnd.in-toto+json",
                    "payload": base64.b64encode(npm_stmt_bytes).decode("ascii"),
                    "signatures": [{"sig": npm_sig_b64}],
                },
            },
        }
    ]
}
(npm_att_dir / f"canonprims@{version}").write_text(json.dumps(npm_att_doc), encoding="utf-8")


def write_pypi_bundle(filename: str, c_b64: str, tlog_entry: dict, stmt_b: bytes, s_b64: str) -> None:
    (http.parent / filename).write_text(
        json.dumps(
            {
                "version": 1,
                "attestation_bundles": [
                    {
                        "publisher": {
                            "kind": "GitHub",
                            "repository": "3leaps/canonprims",
                            "workflow": "registry-publish.yml",
                            "environment": "publish-pypi",
                        },
                        "attestations": [
                            {
                                "version": 1,
                                "verification_material": {
                                    "certificate": c_b64,
                                    "transparency_entries": [tlog_entry],
                                },
                                "envelope": {
                                    "statement": base64.b64encode(stmt_b).decode("ascii"),
                                    "signature": s_b64,
                                },
                            }
                        ],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


# Generate negative control fixtures for PyPI and npm.
first_wheel = f"canonprims-{version}-cp310-abi3-macosx_11_0_arm64.whl"
first_wheel_sha256 = hashlib.sha256((stage / first_wheel).read_bytes()).hexdigest()
good_wheel_stmt = make_slsa_statement(first_wheel, "sha256", first_wheel_sha256, version)
good_wheel_sig_b64, good_wheel_sig_der = sign_dsse_pae(good_wheel_stmt)

# 1. Wrong subject digest.
bad_subj_stmt = make_slsa_statement(first_wheel, "sha256", "00" * 32, version)
bad_subj_sig_b64, bad_subj_sig_der = sign_dsse_pae(bad_subj_stmt)
write_pypi_bundle(
    "prov.wrong-subj.json",
    cert_b64,
    make_tlog_entry(cert_der, bad_subj_sig_der, bad_subj_stmt, kind="intoto"),
    bad_subj_stmt,
    bad_subj_sig_b64,
)

# 1b. Non-empty predicate on PyPI Publish v1 statement and null predicate on SLSA Provenance v1 statement.
bad_pypi_pred_stmt = make_pypi_publish_statement(first_wheel, first_wheel_sha256, "non-empty")
bad_pypi_pred_sig_b64, bad_pypi_pred_sig_der = sign_dsse_pae(bad_pypi_pred_stmt)
write_pypi_bundle(
    "prov.bad-pypi-pred.json",
    cert_b64,
    make_tlog_entry(cert_der, bad_pypi_pred_sig_der, bad_pypi_pred_stmt, kind="intoto"),
    bad_pypi_pred_stmt,
    bad_pypi_pred_sig_b64,
)
null_slsa_pred_stmt = json.dumps(
    {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": first_wheel, "digest": {"sha256": first_wheel_sha256}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": None,
    },
    separators=(",", ":"),
).encode("utf-8")
null_slsa_pred_sig_b64, null_slsa_pred_sig_der = sign_dsse_pae(null_slsa_pred_stmt)
write_pypi_bundle(
    "prov.null-slsa-pred.json",
    cert_b64,
    make_tlog_entry(cert_der, null_slsa_pred_sig_der, null_slsa_pred_stmt, kind="intoto"),
    null_slsa_pred_stmt,
    null_slsa_pred_sig_b64,
)

# 2. Wrong repository in SAN URI.
evil_cert_b64, evil_cert_der = make_test_cert_b64(version, repo="evil/canonprims")
write_pypi_bundle(
    "prov.wrong-cert.json",
    evil_cert_b64,
    make_tlog_entry(evil_cert_der, good_wheel_sig_der, good_wheel_stmt, kind="intoto"),
    good_wheel_stmt,
    good_wheel_sig_b64,
)

# 3. SAN URI with version suffix (v0.1.20) that would pass a naive substring check.
suffix_cert_b64, suffix_cert_der = make_test_cert_b64(f"{version}0", include_workflow_oids=False)
write_pypi_bundle(
    "prov.san-suffix.json",
    suffix_cert_b64,
    make_tlog_entry(suffix_cert_der, good_wheel_sig_der, good_wheel_stmt, kind="intoto"),
    good_wheel_stmt,
    good_wheel_sig_b64,
)

# 4. SAN URI string smuggled in Subject CN while actual SAN extension has wrong repo.
smuggled_cn = f"https://github.com/3leaps/canonprims/.github/workflows/registry-publish.yml@refs/tags/v{version}".encode(
    "ascii"
)
smuggled_cert_b64, smuggled_cert_der = make_test_cert_b64(
    version, repo="evil/canonprims", subject_cn=smuggled_cn, include_workflow_oids=False
)
write_pypi_bundle(
    "prov.san-in-cn.json",
    smuggled_cert_b64,
    make_tlog_entry(smuggled_cert_der, good_wheel_sig_der, good_wheel_stmt, kind="intoto"),
    good_wheel_stmt,
    good_wheel_sig_b64,
)

# 5. Unanchored / attacker-CA-signed leaf certificate (signed by d=29 instead of ca_priv_d=13).
untrusted_cert_b64, untrusted_cert_der = make_test_cert_b64(version, signer_d=29)
write_pypi_bundle(
    "prov.untrusted-ca.json",
    untrusted_cert_b64,
    make_tlog_entry(untrusted_cert_der, good_wheel_sig_der, good_wheel_stmt, kind="intoto"),
    good_wheel_stmt,
    good_wheel_sig_b64,
)

# 6. Rekor integratedTime outside leaf certificate validity window.
write_pypi_bundle(
    "prov.expired-cert.json",
    cert_b64,
    make_tlog_entry(cert_der, good_wheel_sig_der, good_wheel_stmt, kind="intoto", integrated_time=1700009999),
    good_wheel_stmt,
    good_wheel_sig_b64,
)

# 7. Rekor canonicalizedBody where cert/sig strings appear only in unrelated JSON fields while spec.signatures has wrong values.
other_cert_b64, other_cert_der = make_test_cert_b64(version, repo="other/repo")
unrelated_entry = make_tlog_entry(other_cert_der, good_wheel_sig_der, good_wheel_stmt, kind="dsse")
unrelated_doc = json.loads(base64.b64decode(unrelated_entry["canonicalizedBody"]).decode("utf-8"))
unrelated_doc["unrelated_cert"] = cert_b64
unrelated_entry = make_tlog_entry(cert_der, good_wheel_sig_der, good_wheel_stmt, kind="dsse")
# Re-sign a body whose spec.signatures[].verifier is other_cert_b64 while cert_b64 is only in unrelated_note
tampered_body = {
    "apiVersion": "0.0.1",
    "kind": "dsse",
    "spec": {
        "payloadHash": {"algorithm": "sha256", "value": hashlib.sha256(good_wheel_stmt).hexdigest()},
        "signatures": [{"signature": good_wheel_sig_b64, "verifier": other_cert_b64}],
        "unrelated_note": cert_b64,
    },
}
tampered_b64 = base64.b64encode(
    json.dumps(tampered_body, separators=(",", ":"), sort_keys=True).encode("utf-8")
).decode("ascii")
tampered_set_payload = json.dumps(
    {
        "body": tampered_b64,
        "integratedTime": 1700000000,
        "logID": rekor_log_id_hex,
        "logIndex": 1,
    },
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8")
tampered_set_sig = ecdsa_sign(
    rekor_priv_d,
    hashlib.sha256(tampered_set_payload).digest(),
    rvr.P256_N,
    rvr.P256_G,
    rvr.P256_P,
    rvr.P256_A,
)
write_pypi_bundle(
    "prov.unrelated-fields.json",
    cert_b64,
    {
        "logIndex": 1,
        "logId": {"keyId": rekor_log_id_b64},
        "integratedTime": 1700000000,
        "inclusionPromise": {"signedEntryTimestamp": base64.b64encode(tampered_set_sig).decode("ascii")},
        "canonicalizedBody": tampered_b64,
    },
    good_wheel_stmt,
    good_wheel_sig_b64,
)

bad_npm_stmt = make_slsa_statement(f"pkg:npm/%403leaps/canonprims@{version}", "sha512", "00" * 64, version)
bad_npm_sig_b64, bad_npm_sig_der = sign_dsse_pae(bad_npm_stmt)
(http.parent / "npm-att.wrong-subj.json").write_text(
    json.dumps(
        {
            "attestations": [
                {
                    "predicateType": "https://slsa.dev/provenance/v1",
                    "bundle": {
                        "mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.1",
                        "verificationMaterial": {
                            "certificate": {"rawBytes": cert_b64},
                            "tlogEntries": [make_tlog_entry(cert_der, bad_npm_sig_der, bad_npm_stmt, kind="dsse")],
                        },
                        "dsseEnvelope": {
                            "payloadType": "application/vnd.in-toto+json",
                            "payload": base64.b64encode(bad_npm_stmt).decode("ascii"),
                            "signatures": [{"sig": bad_npm_sig_b64}],
                        },
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
PY

cp "$scratch/http/pypi/canonprims/$version/json" "$scratch/pypi.pristine.json"
cp "$scratch/http/npm/@3leaps/canonprims/$version" "$scratch/npm.pristine.json"
npm_att_file="$scratch/http/npm/-/npm/v1/attestations/@3leaps/canonprims@$version"

# If node and @sigstore/protobuf-specs are installed with npm, round-trip the npm
# bundle through Bundle.fromJSON / Bundle.toJSON so the positive fixture is
# serializer-derived and guaranteed wire-compatible.
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
	node - "$npm_att_file" <<'NODE'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const attPath = process.argv[2];
const npmBin = fs.realpathSync(execFileSync("which", ["npm"], { encoding: "utf8" }).trim());
const npmRoot = path.resolve(path.dirname(npmBin), "..");
const specsPath = path.join(npmRoot, "node_modules/@sigstore/protobuf-specs");
if (fs.existsSync(specsPath)) {
  const specs = require(specsPath);
  const doc = JSON.parse(fs.readFileSync(attPath, "utf8"));
  doc.attestations[0].bundle = specs.Bundle.toJSON(specs.Bundle.fromJSON(doc.attestations[0].bundle));
  fs.writeFileSync(attPath, JSON.stringify(doc));
}
NODE
fi
cp "$npm_att_file" "$scratch/npm-att.pristine.json"

run_verify() {
	CANONPRIMS_PYPI_API_URL="$pypi_base" \
		CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
		CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
		CANONPRIMS_REGISTRY_POLL_ATTEMPTS=2 \
		CANONPRIMS_REGISTRY_POLL_SLEEP=0.05 \
		python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" "${1:-all}" >"$scratch/out" 2>&1
}

refused() {
	local scope="$1" pattern="$2"
	if run_verify "$scope"; then
		echo "error: accepted, expected failure matching '$pattern'" >&2
		cat "$scratch/out" >&2
		exit 1
	fi
	grep -Eq -- "$pattern" "$scratch/out" || {
		echo "error: failed for unexpected reason (want '$pattern')" >&2
		cat "$scratch/out" >&2
		exit 1
	}
}

run_verify all
run_verify pypi
run_verify npm

# Without CANONPRIMS_SIGSTORE_TEST_ROOT, synthetic test CA certs must be rejected by the pinned production Fulcio CA root!
if CANONPRIMS_PYPI_API_URL="$pypi_base" \
	CANONPRIMS_REGISTRY_POLL_ATTEMPTS=1 \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" pypi >"$scratch/out" 2>&1; then
	echo "error: accepted synthetic CA certificate against production Sigstore trust root" >&2
	exit 1
fi
grep -q "Fulcio CA certificate signature: cryptographic ECDSA signature verification failed" "$scratch/out"

# Ownership fallback to project-level /pypi/canonprims/json when version JSON is cached with organization=null.
jq '.ownership.organization = null' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
run_verify pypi
jq '.ownership.organization = null' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/json"
refused pypi "ownership organization must be '3leaps'"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/$version/json"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/json"

# Wrong wheel sha256, yanked wheel, missing wheel.
jq '.urls[0].digests.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
	"$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "PyPI sha256 mismatch"
jq '.urls[0].yanked = true' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "is yanked"
jq 'del(.urls[0])' "$scratch/pypi.pristine.json" >"$scratch/http/pypi/canonprims/$version/json"
refused pypi "PyPI wheel set differs"
cp "$scratch/pypi.pristine.json" "$scratch/http/pypi/canonprims/$version/json"

# Wrong npm dist.integrity, dist.shasum, and missing/invalid Sigstore provenance.
jq '.dist.integrity = "sha512-AAAA"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm dist.integrity mismatch"
jq '.dist.shasum = "0000000000000000000000000000000000000000"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm dist.shasum mismatch"
jq 'del(.dist.attestations)' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm Sigstore provenance missing dist.attestations"
CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
	python3 -I -B "$root/scripts/release-verify-registries.py" --bootstrap-no-provenance "$stage" "$version" npm >/dev/null
jq '.dist.attestations.provenance.predicateType = "https://slsa.dev/provenance/garbage"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm Sigstore provenance attestation invalid"
jq '.dist.attestations.url = "https://attacker.invalid/-/npm/v1/attestations/@3leaps%2Fcanonprims@0.1.2"' "$scratch/npm.pristine.json" >"$scratch/http/npm/@3leaps/canonprims/$version"
refused npm "npm Sigstore provenance attestation invalid"
cp "$scratch/npm.pristine.json" "$scratch/http/npm/@3leaps/canonprims/$version"

# Missing, tampered, or mismatched npm Sigstore attestation bundle at the fetched URL.
rm -f "$npm_att_file"
refused npm "npm Sigstore provenance for .* unavailable"
jq '.attestations = []' "$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "attestation endpoint returned no attestations"
jq '.attestations[0].bundle.dsseEnvelope.signatures[0].sig = "MEUCIQD/////////////////////////////////////////AAIgf/////////////////////////////////////////8="' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "(ECDSA signature|signature verification failed)"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries = []' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "missing Rekor transparency log entries"
# Empty or missing inclusionPromise (including proof-only with shifted integratedTime) / forged SET / forged Merkle root / forged checkpoint / untrusted logId on npm bundle.
jq 'del(.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionProof) | .attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionPromise = {}' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "missing or invalid inclusionPromise"
jq 'del(.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionPromise) | .attestations[0].bundle.verificationMaterial.tlogEntries[0].integratedTime = 1700000000' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "missing or invalid inclusionPromise"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionPromise.signedEntryTimestamp = "MEUCIQD/////////////////////////////////////////AAIgf/////////////////////////////////////////8="' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "Rekor SET: .*ECDSA signature"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionProof.logIndex = "121904264"' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "inclusionProof logIndex/treeSize mismatch"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionProof.rootHash = "0000000000000000000000000000000000000000000000000000000000000000"' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "inclusionProof rootHash must decode to 32 bytes"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionProof.rootHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "inclusionProof Merkle root mismatch"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].inclusionProof.checkpoint.envelope = "rekor.sigstore.dev - 1\n2\nAAAA\n\n— rekor.sigstore.dev AAAA\n"' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "checkpoint root hash does not match"
jq '.attestations[0].bundle.verificationMaterial.tlogEntries[0].logId.keyId = "untrusted-log"' \
	"$scratch/npm-att.pristine.json" >"$npm_att_file"
refused npm "untrusted or missing Rekor logId.keyId"
cp "$scratch/npm-att.wrong-subj.json" "$npm_att_file"
refused npm "statement subject mismatch"
cp "$scratch/npm-att.pristine.json" "$npm_att_file"

# Missing, empty, forged, or mismatched PyPI PEP 740 provenance is refused unless --bootstrap-no-provenance is passed.
first_wheel="canonprims-$version-cp310-abi3-macosx_11_0_arm64.whl"
prov_file="$scratch/http/integrity/canonprims/$version/$first_wheel/provenance"
cp "$prov_file" "$scratch/prov.pristine.json"
jq '.attestation_bundles[0].publisher.environment = "wrong-env"' "$scratch/prov.pristine.json" >"$prov_file"
refused pypi "PyPI PEP 740 provenance publisher mismatch"
jq '.attestation_bundles[0].attestations = [{}]' "$scratch/prov.pristine.json" >"$prov_file"
refused pypi "unsupported PEP 740 attestation version"
jq '.attestation_bundles[0].attestations[0].envelope.signature = "MEUCIQD/////////////////////////////////////////AAIgf/////////////////////////////////////////8="' \
	"$scratch/prov.pristine.json" >"$prov_file"
refused pypi "(ECDSA signature|signature verification failed)"
jq '.attestation_bundles[0].attestations[0].verification_material.transparency_entries = []' \
	"$scratch/prov.pristine.json" >"$prov_file"
refused pypi "missing Rekor transparency log entries"
cp "$scratch/prov.wrong-subj.json" "$prov_file"
refused pypi "statement subject mismatch"
cp "$scratch/prov.bad-pypi-pred.json" "$prov_file"
refused pypi "PyPI Publish v1 statement predicate must be null or empty object"
cp "$scratch/prov.null-slsa-pred.json" "$prov_file"
refused pypi "statement predicate must be an object"
cp "$scratch/prov.wrong-cert.json" "$prov_file"
refused pypi "(certificate missing expected workflow SAN URI|Fulcio repository extension mismatch)"
cp "$scratch/prov.san-suffix.json" "$prov_file"
refused pypi "certificate missing expected workflow SAN URI"
cp "$scratch/prov.san-in-cn.json" "$prov_file"
refused pypi "certificate missing expected workflow SAN URI"
cp "$scratch/prov.untrusted-ca.json" "$prov_file"
refused pypi "Fulcio CA certificate signature: cryptographic ECDSA signature verification failed"
cp "$scratch/prov.expired-cert.json" "$prov_file"
refused pypi "outside certificate validity"
# Proof-only entry with expired integratedTime moved into the leaf validity window must also be rejected!
jq 'del(.attestation_bundles[0].attestations[0].verification_material.transparency_entries[0].inclusionPromise) | .attestation_bundles[0].attestations[0].verification_material.transparency_entries[0].integratedTime = 1700000000' \
	"$scratch/prov.expired-cert.json" >"$prov_file"
refused pypi "missing or invalid inclusionPromise"
cp "$scratch/prov.unrelated-fields.json" "$prov_file"
refused pypi "does not bind leaf certificate and DSSE signature"
bad_stmt="$(python3 -c 'import base64,json; print(base64.b64encode(json.dumps({"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"wrong.whl","digest":{"sha256":"00"*32}}],"predicateType":"https://slsa.dev/provenance/v1","predicate":{}}).encode()).decode())')"
jq --arg s "$bad_stmt" '.attestation_bundles[0].attestations[0].envelope.statement = $s' \
	"$scratch/prov.pristine.json" >"$prov_file"
refused pypi "signature verification failed"
jq '.attestation_bundles = []' "$scratch/prov.pristine.json" >"$prov_file"
refused pypi "PyPI PEP 740 provenance missing attestation_bundles"
rm -f "$prov_file"
refused pypi "PyPI PEP 740 provenance for .* unavailable"
CANONPRIMS_PYPI_API_URL="$pypi_base" \
	python3 -I -B "$root/scripts/release-verify-registries.py" --bootstrap-no-provenance "$stage" "$version" pypi >/dev/null
cp "$scratch/prov.pristine.json" "$prov_file"

# Conflicting provenance flags (both orders) or --bootstrap-no-provenance under GITHUB_ACTIONS or CI are refused.
for pair in "--expect-provenance --bootstrap-no-provenance" "--bootstrap-no-provenance --expect-provenance"; do
	# shellcheck disable=SC2086
	if python3 -I -B "$root/scripts/release-verify-registries.py" $pair "$stage" "$version" all >"$scratch/out" 2>&1; then
		echo "error: accepted conflicting provenance flags ($pair) in .py" >&2
		exit 1
	fi
	grep -q "cannot combine --expect-provenance and --bootstrap-no-provenance" "$scratch/out"
	# shellcheck disable=SC2086
	if CANONPRIMS_RELEASE_TAG="v$version" "$root/scripts/release-verify-registries.sh" $pair "$stage" all >"$scratch/out" 2>&1; then
		echo "error: accepted conflicting provenance flags ($pair) in .sh" >&2
		exit 1
	fi
	grep -q "cannot combine --expect-provenance and --bootstrap-no-provenance" "$scratch/out"
done
if GITHUB_ACTIONS=true python3 -I -B "$root/scripts/release-verify-registries.py" --bootstrap-no-provenance "$stage" "$version" all >"$scratch/out" 2>&1; then
	echo "error: accepted --bootstrap-no-provenance under GITHUB_ACTIONS" >&2
	exit 1
fi
grep -q -- "--bootstrap-no-provenance is not accepted under GitHub Actions or CI" "$scratch/out"
if CI=true python3 -I -B "$root/scripts/release-verify-registries.py" --bootstrap-no-provenance "$stage" "$version" all >"$scratch/out" 2>&1; then
	echo "error: accepted --bootstrap-no-provenance under CI=true" >&2
	exit 1
fi
grep -q -- "--bootstrap-no-provenance is not accepted under GitHub Actions or CI" "$scratch/out"

# Bounded retry on HTTP 404 (e.g. npm async processing scan): missing initially, restored while polling.
rm -f "$scratch/http/npm/@3leaps/canonprims/$version"
(sleep 0.15 && cp "$scratch/npm.pristine.json" "$scratch/http/npm/@3leaps/canonprims/$version") &
CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
	CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
	CANONPRIMS_REGISTRY_POLL_ATTEMPTS=5 \
	CANONPRIMS_REGISTRY_POLL_SLEEP=0.1 \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" npm >/dev/null

# Under GITHUB_ACTIONS or CI, API URL overrides and CANONPRIMS_SIGSTORE_TEST_ROOT are refused.
if GITHUB_ACTIONS=true CANONPRIMS_PYPI_API_URL="$pypi_base" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" pypi >"$scratch/out" 2>&1; then
	echo "error: accepted CANONPRIMS_PYPI_API_URL under GITHUB_ACTIONS" >&2
	exit 1
fi
grep -q "CANONPRIMS_PYPI_API_URL is not accepted under GitHub Actions" "$scratch/out"
if GITHUB_ACTIONS=true CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" npm >"$scratch/out" 2>&1; then
	echo "error: accepted CANONPRIMS_NPM_REGISTRY_URL under GITHUB_ACTIONS" >&2
	exit 1
fi
grep -q "CANONPRIMS_NPM_REGISTRY_URL is not accepted under GitHub Actions" "$scratch/out"
if CI=true CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" npm >"$scratch/out" 2>&1; then
	echo "error: accepted CANONPRIMS_SIGSTORE_TEST_ROOT under CI" >&2
	exit 1
fi
grep -q "CANONPRIMS_SIGSTORE_TEST_ROOT is not accepted under GitHub Actions or CI" "$scratch/out"
if CANONPRIMS_PYPI_API_URL="http://127.0.0.1:$port@attacker.example/pypi" \
	CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" pypi >"$scratch/out" 2>&1; then
	echo "error: accepted userinfo loopback bypass in PyPI API URL" >&2
	exit 1
fi
grep -q "must not contain userinfo, query, or fragment" "$scratch/out"
if CANONPRIMS_NPM_REGISTRY_URL="http://127.0.0.1:$port@attacker.example/npm" \
	CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
	python3 -I -B "$root/scripts/release-verify-registries.py" "$stage" "$version" npm >"$scratch/out" 2>&1; then
	echo "error: accepted userinfo loopback bypass in npm registry URL" >&2
	exit 1
fi
grep -q "must not contain userinfo, query, or fragment" "$scratch/out"

if command -v npm >/dev/null 2>&1; then
	"$root/scripts/pack-npm-redirector.sh" "$scratch/redirector" "$version" >/dev/null
	[[ -s "$scratch/redirector/canonprims-$version.tgz" ]]
fi

head_commit="$(git -C "$root" rev-parse HEAD)"
repo_ver="$(tr -d ' \t\r\n' < "$root/VERSION")"
if [[ "$repo_ver" == "$version" ]]; then
	"$root/scripts/ci-prepare-pypi-publish.sh" "$version" "$head_commit" "$stage" "$scratch/pypi-wheels" >/dev/null
	[[ "$(find "$scratch/pypi-wheels" -maxdepth 1 -name '*.whl' | wc -l | tr -d ' ')" == 5 ]]
	if "$root/scripts/ci-prepare-pypi-publish.sh" "$version" "0000000000000000000000000000000000000000" "$stage" "$scratch/pypi-wheels-bad" >"$scratch/out" 2>&1; then
		echo "error: accepted wrong commit in ci-prepare-pypi-publish.sh" >&2
		exit 1
	fi
	grep -q "HEAD differs from verified stage commit" "$scratch/out"
fi

# Standalone scripts/release-verify-registries.sh must bind staged public keys
# and fingerprint pins to the verified tagged commit, rejecting a replacement
# stage signed with an unrelated keypair even when verify-signatures.sh passes
# on the unanchored directory.
fixture="$scratch/repo"
git init -q -b main "$fixture"
git -C "$fixture" config user.name fixture
git -C "$fixture" config user.email fixture@example.invalid
mkdir -p "$fixture/scripts" "$fixture/keys" "$fixture/docs/security" "$fixture/docs/releases" "$scratch/full-stage"
cp "$root/scripts/"{release-common.sh,release-gh.sh,release-decernor.sh,release-verify-registries.sh,release-verify-registries.py,verify-checksums.sh} "$fixture/scripts/"
printf '%s\n' "$version" >"$fixture/VERSION"
for ext in txt ndjson; do
	printf 'committed %s\n' "$ext" >"$fixture/keys/expected-fingerprints.$ext"
done
printf 'committed gpg key\n' >"$fixture/docs/security/release-signing-keys.asc"
printf 'committed minisign key\n' >"$fixture/docs/security/canonprims-minisign.pub"
printf 'committed notes\n' >"$fixture/docs/releases/v$version.md"
cat >"$fixture/scripts/verify-pinned-tag.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fixture/scripts/verify-public-keys.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$fixture/scripts/verify-signatures.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -s "$1/SHA256SUMS.minisig" && -s "$1/SHA512SUMS.minisig" && -s "$1/SHA256SUMS.asc" && -s "$1/SHA512SUMS.asc" ]]
SH
cat >"$scratch/fake-decernor" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" && "${2:-}" == "-e" ]]; then
	printf 'Version:    0.1.8\nCommit:     0000000\nBuild Date: 2026-10-30\nGo Version: go1.25.0\nGofulmen:   0.1.0\nCrucible:   0.1.0\n'
else
	printf 'decernor 0.1.8\n'
fi
SH
chmod +x "$fixture/scripts/"*.sh "$scratch/fake-decernor"
git -C "$fixture" add -A
git -C "$fixture" commit -qm "fixture v$version"
git -C "$fixture" tag "v$version"

(
	export CANONPRIMS_RELEASE_TAG="v$version"
	source "$root/scripts/release-common.sh"
	while IFS= read -r name; do
		if [[ -f "$stage/$name" ]]; then
			cp "$stage/$name" "$scratch/full-stage/$name"
		else
			printf 'synthetic %s\n' "$name" >"$scratch/full-stage/$name"
		fi
	done < <(release_signable_assets)
	cp "$fixture/keys/expected-fingerprints.txt" "$scratch/full-stage/expected-fingerprints.txt"
	cp "$fixture/keys/expected-fingerprints.ndjson" "$scratch/full-stage/expected-fingerprints.ndjson"
	cp "$fixture/docs/security/release-signing-keys.asc" "$scratch/full-stage/canonprims-release-signing-key.asc"
	cp "$fixture/docs/security/canonprims-minisign.pub" "$scratch/full-stage/canonprims-minisign.pub"
	cp "$fixture/docs/releases/v$version.md" "$scratch/full-stage/release-notes-v$version.md"
	files=()
	while IFS= read -r name; do files+=("$name"); done < <(release_signable_assets | LC_ALL=C sort)
	(
		cd "$scratch/full-stage"
		shasum -a 256 ${files[@]+"${files[@]}"} >SHA256SUMS
		shasum -a 512 ${files[@]+"${files[@]}"} >SHA512SUMS
		for sig in SHA256SUMS.minisig SHA512SUMS.minisig SHA256SUMS.asc SHA512SUMS.asc; do
			printf 'sig\n' >"$sig"
		done
	)
)

CANONPRIMS_RELEASE_TAG="v$version" \
	CANONPRIMS_DECERNOR_BIN="$scratch/fake-decernor" \
	CANONPRIMS_PYPI_API_URL="$pypi_base" \
	CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
	CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
	"$fixture/scripts/release-verify-registries.sh" "$scratch/full-stage" all >/dev/null

# Replace staged key/fingerprint material with an unrelated keypair and re-compute checksums:
# verify-signatures.sh and verify-checksums.sh alone would pass on the stage,
# but release-verify-registries.sh must reject it at the tagged-blob binding.
cp "$scratch/full-stage/SHA256SUMS" "$scratch/saved.SHA256SUMS"
cp "$scratch/full-stage/SHA512SUMS" "$scratch/saved.SHA512SUMS"
for swapped in expected-fingerprints.txt expected-fingerprints.ndjson canonprims-release-signing-key.asc canonprims-minisign.pub "release-notes-v$version.md"; do
	cp "$scratch/full-stage/$swapped" "$scratch/saved.$swapped"
	printf 'attacker replacement %s\n' "$swapped" >"$scratch/full-stage/$swapped"
	(
		export CANONPRIMS_RELEASE_TAG="v$version"
		source "$root/scripts/release-common.sh"
		files=()
		while IFS= read -r name; do files+=("$name"); done < <(release_signable_assets | LC_ALL=C sort)
		cd "$scratch/full-stage"
		shasum -a 256 ${files[@]+"${files[@]}"} >SHA256SUMS
		shasum -a 512 ${files[@]+"${files[@]}"} >SHA512SUMS
	)
	if CANONPRIMS_RELEASE_TAG="v$version" \
		CANONPRIMS_DECERNOR_BIN="$scratch/fake-decernor" \
		CANONPRIMS_PYPI_API_URL="$pypi_base" \
		CANONPRIMS_NPM_REGISTRY_URL="$npm_base" \
		CANONPRIMS_SIGSTORE_TEST_ROOT="$test_root_file" \
		"$fixture/scripts/release-verify-registries.sh" "$scratch/full-stage" all >"$scratch/out" 2>&1; then
		echo "error: release-verify-registries.sh accepted unanchored replacement $swapped" >&2
		exit 1
	fi
	grep -q "published release public material differs from verified commit" "$scratch/out" || {
		cat "$scratch/out" >&2
		exit 1
	}
	cp "$scratch/saved.$swapped" "$scratch/full-stage/$swapped"
	cp "$scratch/saved.SHA256SUMS" "$scratch/full-stage/SHA256SUMS"
	cp "$scratch/saved.SHA512SUMS" "$scratch/full-stage/SHA512SUMS"
done

echo '[ok] registry verification and bare-name redirector controls'

# Release Signing and Verification

Official canonprims releases use GPG-signed annotated Git tags and
`SHA256SUMS` and `SHA512SUMS` manifests that each carry a minisign signature
and an OpenPGP signature by the committed signing subkey. These are separate
signatures, and all are required.

Establish the expected GPG primary key, the exact signing subkey, and the
minisign public-blob fingerprint through an independently trusted maintainer
channel before accepting downloaded public keys. A key distributed beside a
signature is not independent authentication.

## Public pins

| File | Contents |
| --- | --- |
| `docs/security/release-signing-keys.asc` | Public OpenPGP export: the approved primary key and the exact signing subkey, nothing else |
| `docs/security/canonprims-minisign.pub` | The minisign public key that signs the checksum manifests |
| `config/release/signing-subkey.txt` | The fingerprint of the one signing subkey tags may use |
| `config/release/tagger-identity.txt` | The exact git tagger identity |
| `keys/expected-fingerprints.txt` | Two lines: the OpenPGP primary fingerprint, then the minisign public-blob SHA-256 |
| `keys/expected-fingerprints.ndjson` | The checker's fingerprint records for the same two keys |
| `config/release/decernor-ci-sha256.txt` | Digest and filename of the checker archive the tag workflow downloads |
| `config/ci-python-requirements.txt` | Python packages the CI gates import, pinned by version and source-archive hash (copied in as pure Python; nothing built) |
| `config/release/release-workflow.sha256` | Digests of every reviewed workflow and local action (workflows must be read-only) |

Release staging extracts the public keys from the verified tagged commit as
inert blobs, not from the current checkout or an external public-key locator.
The published `canonprims-minisign.pub` asset must match the committed file
byte-for-byte; fingerprint verification remains required.

## Fingerprint anchors

The text and NDJSON anchors in each tagged commit are derived by
`decernor 0.1.8` or newer. The minisign fingerprint covers the decoded public
blob, not its comment or the whole file. Verify exported public material
against both anchors with that tool, then use the approved minisign public key
to verify both manifests and check every listed digest. Require the complete
expected asset set.

## Tags

A release is one tag, `vX.Y.Z`, which releases the Rust crates and the root Go
module together (see [ADR-0001](../decisions/ADR-0001-release-identity-and-tags.md)).
It must be annotated, signed by the committed signing subkey, and point at a
commit whose root `go.mod` declares `github.com/3leaps/canonprims`.
Verification refuses a release where the tag is missing or points elsewhere.
The GitHub release is bound to `vX.Y.Z`.

Tag verification reads committed public data in an isolated keyring and
requires the exact signing subkey. The forge's own "verified" flag is an
additional check. Historical tags are not retroactively signed.

The tag workflow has read-only permissions. A passing tag workflow is a
consistency signal; it is not release authorization. Every workflow's
reviewed contents are pinned by digest in
`config/release/release-workflow.sha256`; `make check`, the pre-tag gate and
tag verification fail on any change until that pin is updated, so a workflow
change is always a reviewed change to a trust file.

## Crate publication

The publication ceremony compiles nothing; package verification is compiled
in credential-free CI. A crate's package is
verified there (`cargo package`, which builds it) and the SHA-256 of the
verified archive is recorded with the tag object, the commit and the run.
The maintainer packages the same source with `cargo package --no-verify` in a
fresh Cargo home and must reproduce that archive byte for byte. The upload
runs `cargo publish --no-verify` with `scripts/release-cargo-provider.py` as
the only credential provider: Cargo reports the checksum of the exact archive
it is about to send, and the provider releases the token only for the
approved crate, version and checksum, never caching it. Any other archive,
crate or operation gets no token, and nothing is transmitted. After upload,
the index checksum and the downloaded published archive must both equal the
verified digest.

## Not applicable

- The `canon` binary verifies no signatures, so it embeds no key.
- No signing key has been retired; there are no retired pins.
- The build verifies no third-party tool with a minisign key; CI tools are
  pinned by SHA-256 in `config/ci-tools.sha256`.

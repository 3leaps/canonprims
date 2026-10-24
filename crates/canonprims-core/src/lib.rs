// SPDX-License-Identifier: MIT OR Apache-2.0

//! Format-independent vocabulary for canonprims: scheme identifiers,
//! refusal codes, explicit limits, and the digest prefix convention.
//!
//! This crate does no parsing and no I/O. Each format crate (for example
//! `canonprims-json`) exposes the same four verbs over these types:
//! `canonicalize`, `check`, `digest` and `scheme_info`.

use std::fmt;

use sha2::{Digest as _, Sha256};
use thiserror::Error;

/// A canonicalization scheme. Part of every digest's provenance.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Scheme {
    /// RFC 8785 JSON Canonicalization Scheme over strict I-JSON input.
    JcsRfc8785,
}

impl Scheme {
    /// Every scheme this release knows.
    pub const ALL: &'static [Scheme] = &[Scheme::JcsRfc8785];

    /// The closed identifier, for example `jcs/rfc8785`.
    pub fn id(self) -> &'static str {
        match self {
            Scheme::JcsRfc8785 => "jcs/rfc8785",
        }
    }

    /// Resolve a closed identifier.
    pub fn from_id(id: &str) -> Result<Self, CallError> {
        Self::ALL
            .iter()
            .copied()
            .find(|s| s.id() == id)
            .ok_or_else(|| CallError::UnknownScheme(id.to_owned()))
    }
}

impl fmt::Display for Scheme {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.id())
    }
}

/// What a scheme is and which corpus gated it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemeInfo {
    /// The scheme.
    pub scheme: Scheme,
    /// The specification it implements, for example `RFC 8785`.
    pub spec: &'static str,
    /// The conformance corpus, for example `canonical-json/v0`.
    pub corpus: &'static str,
    /// `sha256:` of the corpus `MANIFEST.json` this build was gated against.
    pub corpus_digest: &'static str,
}

/// Why an input has no canonical form. The code is normative and identical
/// across languages; the offset is informative.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("{code} at byte {offset}")]
pub struct Refusal {
    /// The normative refusal code.
    pub code: Code,
    /// Byte offset in the input where the defect was found.
    pub offset: usize,
}

impl Refusal {
    /// A refusal with `code` at `offset`.
    pub fn new(code: Code, offset: usize) -> Self {
        Self { code, offset }
    }
}

/// Refusal codes. `NotCanonical` is only produced by `check`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Code {
    /// Not a JSON text (or, for other schemes, not well-formed input).
    InvalidJson,
    /// The input is not well-formed UTF-8.
    InvalidUtf8,
    /// An object member name repeats an earlier name in the same object.
    DuplicateMember,
    /// An escaped surrogate is not part of a high-then-low pair.
    LoneSurrogate,
    /// A string contains a Unicode noncharacter (RFC 7493 section 2.1).
    Noncharacter,
    /// A fraction or exponent number rounds to infinity.
    NonFiniteNumber,
    /// An integer token's exact value is not a binary64 value.
    IntegerOutsideBinary64,
    /// Nesting exceeds `Limits::max_depth`.
    TooDeep,
    /// A size limit was exceeded.
    TooLarge,
    /// The input is in the domain but is not byte-identical to its
    /// canonical form.
    NotCanonical,
}

impl Code {
    /// Every code, in spec order.
    pub const ALL: &'static [Code] = &[
        Code::TooLarge,
        Code::InvalidUtf8,
        Code::InvalidJson,
        Code::LoneSurrogate,
        Code::Noncharacter,
        Code::DuplicateMember,
        Code::NonFiniteNumber,
        Code::IntegerOutsideBinary64,
        Code::TooDeep,
        Code::NotCanonical,
    ];

    /// The wire name, for example `duplicate_member`.
    pub fn as_str(self) -> &'static str {
        match self {
            Code::InvalidJson => "invalid_json",
            Code::InvalidUtf8 => "invalid_utf8",
            Code::DuplicateMember => "duplicate_member",
            Code::LoneSurrogate => "lone_surrogate",
            Code::Noncharacter => "noncharacter",
            Code::NonFiniteNumber => "non_finite_number",
            Code::IntegerOutsideBinary64 => "integer_outside_binary64",
            Code::TooDeep => "too_deep",
            Code::TooLarge => "too_large",
            Code::NotCanonical => "not_canonical",
        }
    }
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Errors about the call rather than the input.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum CallError {
    /// The scheme identifier is not one this build knows.
    #[error("unknown scheme {0:?}")]
    UnknownScheme(String),
    /// The digest algorithm is not one this build knows.
    #[error("unknown digest algorithm {0:?}")]
    UnknownAlgorithm(String),
}

/// Explicit resource limits. Every public entry point takes one; exceeding
/// a limit is a `too_large` or `too_deep` refusal, never an unbounded
/// allocation. A limit of 0 allows none of that thing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Input length in bytes.
    pub max_bytes: usize,
    /// Array and object nesting. The outermost container is depth 1.
    pub max_depth: usize,
    /// Members in any one object.
    pub max_object_members: usize,
    /// Decoded UTF-8 bytes of any one string, names included.
    pub max_string_bytes: usize,
}

impl Limits {
    /// Default `max_bytes`: 16 MiB.
    pub const DEFAULT_MAX_BYTES: usize = 16 * 1024 * 1024;
    /// Default `max_depth`.
    pub const DEFAULT_MAX_DEPTH: usize = 128;
    /// Default `max_object_members`.
    pub const DEFAULT_MAX_OBJECT_MEMBERS: usize = 1024 * 1024;
    /// Default `max_string_bytes`: 16 MiB.
    pub const DEFAULT_MAX_STRING_BYTES: usize = 16 * 1024 * 1024;
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_bytes: Self::DEFAULT_MAX_BYTES,
            max_depth: Self::DEFAULT_MAX_DEPTH,
            max_object_members: Self::DEFAULT_MAX_OBJECT_MEMBERS,
            max_string_bytes: Self::DEFAULT_MAX_STRING_BYTES,
        }
    }
}

/// Digest algorithms, written `<alg>:<hex>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum DigestAlg {
    /// SHA-256, written `sha256:<64 lowercase hex>`.
    Sha256,
}

impl DigestAlg {
    /// The prefix name, for example `sha256`.
    pub fn id(self) -> &'static str {
        match self {
            DigestAlg::Sha256 => "sha256",
        }
    }

    /// Resolve a prefix name.
    pub fn from_id(id: &str) -> Result<Self, CallError> {
        match id {
            "sha256" => Ok(DigestAlg::Sha256),
            _ => Err(CallError::UnknownAlgorithm(id.to_owned())),
        }
    }

    /// Hash `bytes` and format as `<alg>:<lowercase hex>`.
    pub fn format(self, bytes: &[u8]) -> String {
        match self {
            DigestAlg::Sha256 => {
                let sum = Sha256::digest(bytes);
                let mut out = String::with_capacity(7 + 64);
                out.push_str("sha256:");
                push_hex(&mut out, &sum);
                out
            }
        }
    }
}

fn push_hex(out: &mut String, bytes: &[u8]) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for b in bytes {
        out.push(HEX[usize::from(b >> 4)] as char);
        out.push(HEX[usize::from(b & 0xf)] as char);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scheme_ids_round_trip() {
        for s in Scheme::ALL {
            assert_eq!(Scheme::from_id(s.id()).unwrap(), *s);
        }
        assert_eq!(
            Scheme::from_id("jcs/rfc8259"),
            Err(CallError::UnknownScheme("jcs/rfc8259".into()))
        );
    }

    #[test]
    fn code_names_are_the_spec_names() {
        let names: Vec<_> = Code::ALL.iter().map(|c| c.as_str()).collect();
        assert_eq!(
            names,
            [
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
            ]
        );
    }

    #[test]
    fn sha256_prefix_and_known_vector() {
        assert_eq!(
            DigestAlg::Sha256.format(b"abc"),
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(DigestAlg::from_id("SHA256").is_err());
        assert!(DigestAlg::from_id("sha512").is_err());
    }

    #[test]
    fn default_limits_match_the_spec() {
        let l = Limits::default();
        assert_eq!(l.max_bytes, 16_777_216);
        assert_eq!(l.max_depth, 128);
        assert_eq!(l.max_object_members, 1_048_576);
        assert_eq!(l.max_string_bytes, 16_777_216);
    }

    #[test]
    fn refusal_displays_code_and_offset() {
        assert_eq!(
            Refusal::new(Code::TooDeep, 128).to_string(),
            "too_deep at byte 128"
        );
    }
}

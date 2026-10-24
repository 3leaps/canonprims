// SPDX-License-Identifier: MIT OR Apache-2.0

// Package canon canonicalizes JSON texts under the canonprims schemes.
//
// The only scheme in this version is JCS ("jcs/rfc8785"): the RFC 8785 JSON
// Canonicalization Scheme over I-JSON (RFC 7493) input. Input outside the
// domain is never repaired; it is refused with a Refusal carrying one
// normative Code. Every entry point takes Limits explicitly, and exceeding a
// limit is a refusal, never an unbounded allocation or a panic.
//
// This package is a pure-Go, standard-library-only implementation. It is
// gated against the canonical-json/v0 conformance corpus identified by
// CorpusDigest.
package canon

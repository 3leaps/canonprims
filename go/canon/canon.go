// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
)

// Scheme identifies a canonicalization scheme.
type Scheme string

// JCS is the RFC 8785 JSON Canonicalization Scheme.
const JCS Scheme = "jcs/rfc8785"

// CorpusDigest is the sha256 of the conformance corpus MANIFEST.json bytes
// this implementation was gated against.
const CorpusDigest = "sha256:de3ac543580ddb90f7e3a6e72239097274d3635ea783f302a9260b5a7d0c8d90"

// Limits bounds the work done on one input. A limit of 0 means none of that
// thing is allowed; a negative limit behaves like 0.
type Limits struct {
	// MaxBytes is the maximum input length in bytes.
	MaxBytes int
	// MaxDepth is the maximum array/object nesting; the outermost container
	// is depth 1 and a top-level scalar is depth 0.
	MaxDepth int
	// MaxObjectMembers is the maximum number of members in any one object.
	MaxObjectMembers int
	// MaxStringBytes is the maximum decoded UTF-8 length of any one string,
	// member names included.
	MaxStringBytes int
}

// DefaultLimits returns the scheme's default limits.
func DefaultLimits() Limits {
	return Limits{
		MaxBytes:         16 << 20,
		MaxDepth:         128,
		MaxObjectMembers: 1 << 20,
		MaxStringBytes:   16 << 20,
	}
}

// Code is a normative refusal code.
type Code string

// Refusal codes. NotCanonical is returned only by Check.
const (
	TooLarge               Code = "too_large"
	InvalidUTF8            Code = "invalid_utf8"
	InvalidJSON            Code = "invalid_json"
	LoneSurrogate          Code = "lone_surrogate"
	Noncharacter           Code = "noncharacter"
	DuplicateMember        Code = "duplicate_member"
	NonFiniteNumber        Code = "non_finite_number"
	IntegerOutsideBinary64 Code = "integer_outside_binary64"
	TooDeep                Code = "too_deep"
	NotCanonical           Code = "not_canonical"
)

// Refusal reports an input outside the scheme's domain (or, from Check, an
// input that is not canonical). Code is normative; Offset is an informative
// byte offset into the input and may differ between implementations.
type Refusal struct {
	Code   Code
	Offset int
}

// Error implements error.
func (r Refusal) Error() string {
	return "canon: " + string(r.Code) + " at byte " + strconv.Itoa(r.Offset)
}

// Errors about the call rather than the input. They are not refusal codes.
var (
	ErrUnknownScheme    = errors.New("canon: unknown_scheme")
	ErrUnknownAlgorithm = errors.New("canon: unknown_algorithm")
)

// SchemeInfo describes a scheme and the corpus it was gated against.
type SchemeInfo struct {
	Name         string
	Spec         string
	Corpus       string
	CorpusDigest string
}

// Info returns the identity of scheme s.
func Info(s Scheme) (SchemeInfo, error) {
	if s != JCS {
		return SchemeInfo{}, ErrUnknownScheme
	}
	return SchemeInfo{
		Name:         string(JCS),
		Spec:         "RFC 8785",
		Corpus:       "canonical-json/v0",
		CorpusDigest: CorpusDigest,
	}, nil
}

// Canonicalize returns the canonical bytes of input under scheme s, or a
// Refusal. The returned slice never aliases input.
func Canonicalize(s Scheme, input []byte, l Limits) ([]byte, error) {
	if s != JCS {
		return nil, ErrUnknownScheme
	}
	out, r := canonicalize(input, l)
	if r != nil {
		return nil, *r
	}
	return out, nil
}

// Check succeeds when input is byte-identical to its canonical form. It
// returns the refusal for input outside the domain, or a Refusal with code
// NotCanonical (offset of the first differing byte) otherwise.
func Check(s Scheme, input []byte, l Limits) error {
	out, err := Canonicalize(s, input, l)
	if err != nil {
		return err
	}
	if bytes.Equal(out, input) {
		return nil
	}
	i := 0
	for i < len(out) && i < len(input) && out[i] == input[i] {
		i++
	}
	return Refusal{Code: NotCanonical, Offset: i}
}

// Digest canonicalizes input and hashes the canonical bytes, returning
// "<alg>:<lowercase hex>". The only algorithm is "sha256". A refusal from
// canonicalization is returned unchanged.
func Digest(s Scheme, input []byte, l Limits, alg string) (string, error) {
	if s != JCS {
		return "", ErrUnknownScheme
	}
	if alg != "sha256" {
		return "", ErrUnknownAlgorithm
	}
	out, err := Canonicalize(s, input, l)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(out)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

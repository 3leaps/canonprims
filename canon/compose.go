// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strconv"
)

// Helpers built on Canonicalize under JCS: golden vectors, strict NDJSON
// prefixes framed as one canonical array, and canonical sets. Each is
// specified in docs/spec/jcs-rfc8785.md ("Composition helpers") and agrees
// byte for byte with the Rust crate canonprims-json.

// Vector is a golden test vector: canonical JCS bytes, their length and
// their sha256 digest. A Vector made by VectorOf or VectorOfCanonical always
// holds canonical bytes. The zero Vector holds none and is not a vector: its
// Canonical is nil, its Digest is empty and its JSON is nil.
type Vector struct {
	canonical []byte
	digest    string
}

func newVector(canonical []byte) Vector {
	sum := sha256.Sum256(canonical)
	return Vector{canonical: canonical, digest: "sha256:" + hex.EncodeToString(sum[:])}
}

// VectorOf canonicalizes input under JCS and describes the result.
func VectorOf(input []byte, l Limits) (Vector, error) {
	out, r := canonicalize(input, l)
	if r != nil {
		return Vector{}, *r
	}
	return newVector(out), nil
}

// VectorOfCanonical wraps bytes that must already be canonical under l;
// otherwise it returns the error from Check (NotCanonical included). The
// Vector keeps its own copy.
func VectorOfCanonical(canonical []byte, l Limits) (Vector, error) {
	if err := Check(JCS, canonical, l); err != nil {
		return Vector{}, err
	}
	return newVector(bytes.Clone(canonical)), nil
}

// Canonical returns a copy of the canonical bytes.
func (v Vector) Canonical() []byte { return bytes.Clone(v.canonical) }

// ByteLength is the length of the canonical bytes.
func (v Vector) ByteLength() int { return len(v.canonical) }

// Digest is "sha256:<lowercase hex>" of the canonical bytes.
func (v Vector) Digest() string { return v.digest }

// Scheme is the scheme the bytes are canonical under.
func (v Vector) Scheme() Scheme { return JCS }

// JSON returns the vector as one canonical JSON object, without a trailing
// newline: {"byte_length":N,"canonical":"...","digest":"sha256:...","scheme":"jcs/rfc8785"}.
func (v Vector) JSON() []byte {
	if v.digest == "" {
		return nil
	}
	out := make([]byte, 0, len(v.canonical)+160)
	out = append(out, `{"byte_length":`...)
	out = strconv.AppendInt(out, int64(len(v.canonical)), 10)
	out = append(out, `,"canonical":`...)
	out = appendString(out, v.canonical)
	out = append(out, `,"digest":"`...)
	out = append(out, v.digest...)
	out = append(out, `","scheme":"`...)
	out = append(out, JCS...)
	return append(out, `"}`...)
}

// elementLimits are the limits for one element of an array the helpers
// assemble: one level shallower, so the array stays within l.MaxDepth.
func elementLimits(l Limits) (Limits, *Refusal) {
	if nonNeg(l.MaxDepth) == 0 {
		return Limits{}, refuse(TooDeep, 0)
	}
	l.MaxDepth = nonNeg(l.MaxDepth) - 1
	return l, nil
}

// NDJSONElements returns the canonical bytes of each line of a strict NDJSON
// prefix.
//
// Lines are read from the start of input: exactly the first head when
// head > 0, and all of them otherwise. A zero or negative head (for example a
// count that underflowed) is not refused: it selects every line, still
// within l.MaxBytes. Callers that need a bound must pass a positive head. Every selected line must end with LF, must not end
// with CR LF, and must not be empty or only spaces, tabs and CRs; each is one
// JSON text canonicalized under l one level shallower. The selected lines
// together must fit in l.MaxBytes; bytes after them are never examined.
// Framing defects, too few lines and empty input are InvalidJSON. Refusal
// offsets are into input.
func NDJSONElements(input []byte, head int, l Limits) ([][]byte, error) {
	elem, r := elementLimits(l)
	if r != nil {
		return nil, *r
	}
	maxBytes := nonNeg(l.MaxBytes)
	var out [][]byte
	pos := 0
	for (head <= 0 || len(out) < head) && pos < len(input) {
		// Look for the LF only where it may lie: a line ending past
		// MaxBytes is refused without scanning the rest of the input.
		window := min(len(input), maxBytes)
		nl := bytes.IndexByte(input[pos:window], '\n')
		if nl < 0 {
			if len(input) > maxBytes {
				return nil, Refusal{Code: TooLarge, Offset: maxBytes}
			}
			// The final line has no LF.
			return nil, Refusal{Code: InvalidJSON, Offset: len(input)}
		}
		end := pos + nl + 1
		body := input[pos : pos+nl]
		if len(body) > 0 && body[len(body)-1] == '\r' {
			return nil, Refusal{Code: InvalidJSON, Offset: pos + nl - 1}
		}
		if len(bytes.Trim(body, " \t\r")) == 0 {
			return nil, Refusal{Code: InvalidJSON, Offset: pos}
		}
		c, r := canonicalize(body, elem)
		if r != nil {
			return nil, Refusal{Code: r.Code, Offset: pos + r.Offset}
		}
		out = append(out, c)
		pos = end
	}
	if len(out) == 0 || (head > 0 && len(out) < head) {
		return nil, Refusal{Code: InvalidJSON, Offset: pos}
	}
	return out, nil
}

// CanonicalizeNDJSON returns a strict NDJSON prefix (see NDJSONElements) as
// one canonical array, lines in input order.
func CanonicalizeNDJSON(input []byte, head int, l Limits) ([]byte, error) {
	elements, err := NDJSONElements(input, head, l)
	if err != nil {
		return nil, err
	}
	return join(elements), nil
}

// SortCanonicalSet canonicalizes input, which must be an array, as a
// canonical set: its elements sorted by their canonical bytes (unsigned,
// byte by byte) with no two identical. A non-array is NotAnArray; a repeated
// element is DuplicateSetElement (elements that differ only in member order
// or number spelling are the same element).
func SortCanonicalSet(input []byte, l Limits) ([]byte, error) {
	c, r := canonicalize(input, l)
	if r != nil {
		return nil, *r
	}
	elements, ok := splitArray(c)
	if !ok {
		return nil, Refusal{Code: NotAnArray, Offset: 0}
	}
	return sortSet(elements)
}

// CheckCanonicalSet succeeds when input is byte-identical to
// SortCanonicalSet of itself; otherwise it returns that function's error, or
// NotCanonical at the first differing byte.
func CheckCanonicalSet(input []byte, l Limits) error {
	sorted, err := SortCanonicalSet(input, l)
	if err != nil {
		return err
	}
	if bytes.Equal(sorted, input) {
		return nil
	}
	i := 0
	for i < len(sorted) && i < len(input) && sorted[i] == input[i] {
		i++
	}
	return Refusal{Code: NotCanonical, Offset: i}
}

// AssembleCanonicalSet builds a canonical set from elements that are each
// already canonical under l one level shallower (each is checked; the first
// that is not gives its error, NotCanonical included). Sorted and
// duplicate-free as in SortCanonicalSet. The elements are the input: together
// with the array's brackets and commas they must fit in l.MaxBytes, and this
// is checked before each element is examined. The elements are not modified.
func AssembleCanonicalSet(elements [][]byte, l Limits) ([]byte, error) {
	elem, r := elementLimits(l)
	if r != nil {
		return nil, *r
	}
	maxBytes := nonNeg(l.MaxBytes)
	size := 2
	var parts [][]byte
	for _, e := range elements {
		comma := 0
		if len(parts) > 0 {
			comma = 1
		}
		// size <= maxBytes here; compare by subtraction so nothing overflows.
		if size > maxBytes || len(e) > maxBytes-size-comma {
			return nil, Refusal{Code: TooLarge, Offset: maxBytes}
		}
		size += comma + len(e)
		if err := Check(JCS, e, elem); err != nil {
			return nil, err
		}
		parts = append(parts, e)
	}
	if size > maxBytes {
		return nil, Refusal{Code: TooLarge, Offset: maxBytes}
	}
	return sortSet(parts)
}

func join(elements [][]byte) []byte {
	n := 2
	for _, e := range elements {
		n += len(e) + 1
	}
	out := make([]byte, 0, n)
	out = append(out, '[')
	for i, e := range elements {
		if i > 0 {
			out = append(out, ',')
		}
		out = append(out, e...)
	}
	return append(out, ']')
}

func sortSet(elements [][]byte) ([]byte, error) {
	slices.SortFunc(elements, bytes.Compare)
	// The offset is where the repeat would start in the sorted output.
	at := 1
	for i := 1; i < len(elements); i++ {
		at += len(elements[i-1]) + 1
		if bytes.Equal(elements[i-1], elements[i]) {
			return nil, Refusal{Code: DuplicateSetElement, Offset: at}
		}
	}
	return join(elements), nil
}

// splitArray returns the top-level elements of canonical JSON bytes, or
// false when the value is not an array. Canonical bytes have no whitespace
// outside strings, and inside a string every '"' and '\' is escaped.
func splitArray(c []byte) ([][]byte, bool) {
	if len(c) < 2 || c[0] != '[' || c[len(c)-1] != ']' {
		return nil, false
	}
	inner := c[1 : len(c)-1]
	out := [][]byte{}
	if len(inner) == 0 {
		return out, true
	}
	depth, inString, escaped, start := 0, false, false, 0
	for i, b := range inner {
		if inString {
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				inString = false
			}
			continue
		}
		switch b {
		case '"':
			inString = true
		case '[', '{':
			depth++
		case ']', '}':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, inner[start:i])
				start = i + 1
			}
		}
	}
	return append(out, inner[start:]), true
}

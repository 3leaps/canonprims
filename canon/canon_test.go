// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"errors"
	"strings"
	"testing"
)

func TestUnknownScheme(t *testing.T) {
	l := DefaultLimits()
	if _, err := Canonicalize("jcs/other", []byte("1"), l); !errors.Is(err, ErrUnknownScheme) {
		t.Errorf("Canonicalize: %v", err)
	}
	if err := Check("", []byte("1"), l); !errors.Is(err, ErrUnknownScheme) {
		t.Errorf("Check: %v", err)
	}
	if _, err := Digest("x", []byte("1"), l, "sha256"); !errors.Is(err, ErrUnknownScheme) {
		t.Errorf("Digest: %v", err)
	}
	if _, err := Info("x"); !errors.Is(err, ErrUnknownScheme) {
		t.Errorf("Info: %v", err)
	}
}

func TestUnknownAlgorithm(t *testing.T) {
	for _, alg := range []string{"", "SHA256", "sha512", "sha-256"} {
		if _, err := Digest(JCS, []byte("1"), DefaultLimits(), alg); !errors.Is(err, ErrUnknownAlgorithm) {
			t.Errorf("Digest(%q): %v", alg, err)
		}
	}
	// The algorithm is judged before the input.
	if _, err := Digest(JCS, []byte("{"), DefaultLimits(), "md5"); !errors.Is(err, ErrUnknownAlgorithm) {
		t.Errorf("Digest(md5, bad input): %v", err)
	}
}

func TestDigest(t *testing.T) {
	d, err := Digest(JCS, []byte(` { "b" : 1 , "a" : 2 } `), DefaultLimits(), "sha256")
	if err != nil {
		t.Fatal(err)
	}
	// sha256 of {"a":2,"b":1}
	if !strings.HasPrefix(d, "sha256:") || len(d) != len("sha256:")+64 {
		t.Fatalf("digest shape: %q", d)
	}
	d2, _ := Digest(JCS, []byte(`{"a":2,"b":1}`), DefaultLimits(), "sha256")
	if d != d2 {
		t.Fatalf("%s != %s", d, d2)
	}
	_, err = Digest(JCS, []byte(`[01]`), DefaultLimits(), "sha256")
	var r Refusal
	if !errors.As(err, &r) || r.Code != InvalidJSON {
		t.Fatalf("refusal not passed through: %v", err)
	}
}

func TestInfo(t *testing.T) {
	i, err := Info(JCS)
	if err != nil {
		t.Fatal(err)
	}
	want := SchemeInfo{Name: "jcs/rfc8785", Spec: "RFC 8785", Corpus: "canonical-json/v0", CorpusDigest: CorpusDigest}
	if i != want {
		t.Fatalf("Info = %+v", i)
	}
}

func TestDefaultLimits(t *testing.T) {
	want := Limits{MaxBytes: 16777216, MaxDepth: 128, MaxObjectMembers: 1048576, MaxStringBytes: 16777216}
	if got := DefaultLimits(); got != want {
		t.Fatalf("DefaultLimits = %+v", got)
	}
}

func TestRefusalError(t *testing.T) {
	var err error = Refusal{Code: TooDeep, Offset: 129}
	if got := err.Error(); got != "canon: too_deep at byte 129" {
		t.Fatalf("Error() = %q", got)
	}
	_, err = Canonicalize(JCS, []byte(`[1,]`), DefaultLimits())
	var r Refusal
	if !errors.As(err, &r) || r.Code != InvalidJSON {
		t.Fatalf("got %v", err)
	}
	err = Check(JCS, []byte(`[1, 2]`), DefaultLimits())
	if !errors.As(err, &r) || r.Code != NotCanonical || r.Offset != 3 {
		t.Fatalf("Check: %#v", err)
	}
}

func TestCanonicalizeDoesNotAlias(t *testing.T) {
	in := []byte(`"abc"`)
	out, err := Canonicalize(JCS, in, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	out[1] = 'z'
	if in[1] != 'a' {
		t.Fatal("output aliases input")
	}
}

func TestCases(t *testing.T) {
	l := DefaultLimits()
	cases := []struct{ in, want string }{
		{`18446744073709552000`, `18446744073709552000`},
		{`18446744073709551616`, `18446744073709552000`},
		{`-18446744073709552000`, `-18446744073709552000`},
		{`295147905179352830000`, `295147905179352830000`},
		{`18446744073709552001`, "integer_outside_binary64"},
		{`295147905179352830001`, "integer_outside_binary64"},
		{`9007199254740993`, "integer_outside_binary64"},
		{`1000000000000000000000`, `1e+21`},
		{`1e+21`, `1e+21`},
		{`123456789012345680000`, `123456789012345680000`},
		{`[1e-7,1e-6,0.1,1.5,-2.25e-10]`, `[1e-7,0.000001,0.1,1.5,-2.25e-10]`},
		{`1e999999999999999999999`, "non_finite_number"},
		{`1e-999999999999999999999`, `0`},
		{`-0.0e0`, `0`},
		{`{"a":[{"c":1,"b":2},3],"A":{}}`, `{"A":{},"a":[{"b":2,"c":1},3]}`},
		{`"𐀀"`, "\"\U00010000\""},
		{`{"a":1 , "b" : {"d":[] , "c":null}}`, `{"a":1,"b":{"c":null,"d":[]}}`},
		{`[` + strings.Repeat("9", 310) + `]`, "integer_outside_binary64"},
	}
	for _, c := range cases {
		out, err := Canonicalize(JCS, []byte(c.in), l)
		got := string(out)
		if err != nil {
			got = outcome(err)
		}
		if got != c.want {
			t.Errorf("%.60q: got %q, want %q", c.in, got, c.want)
		}
	}
}

func TestHugeIntegerToken(t *testing.T) {
	in := make([]byte, 16<<20)
	for i := range in {
		in[i] = '7'
	}
	if _, err := Canonicalize(JCS, in, DefaultLimits()); outcome(err) != string(IntegerOutsideBinary64) {
		t.Fatalf("got %v", err)
	}
}

func TestNegativeLimits(t *testing.T) {
	l := Limits{MaxBytes: -1, MaxDepth: -1, MaxObjectMembers: -1, MaxStringBytes: -1}
	if _, err := Canonicalize(JCS, []byte(""), l); outcome(err) != "invalid_json" {
		t.Errorf("empty: %v", err)
	}
	l.MaxBytes = 10
	for in, want := range map[string]string{`1`: "ok", `[]`: "too_deep", `""`: "ok", `"a"`: "too_large"} {
		if _, err := Canonicalize(JCS, []byte(in), l); outcome(err) != want {
			t.Errorf("%s: %v, want %s", in, err, want)
		}
	}
}

// A caller-raised depth limit is honoured without exhausting the stack, and
// one less refuses with too_deep.
func TestRaisedDepthLimit(t *testing.T) {
	const depth = 1000000
	doc := make([]byte, 0, 4*depth+8)
	for i := 0; i < depth; i++ {
		if i%2 == 0 {
			doc = append(doc, '[')
		} else {
			doc = append(doc, `{"a":`...)
		}
	}
	doc = append(doc, '0')
	for i := depth - 1; i >= 0; i-- {
		if i%2 == 0 {
			doc = append(doc, ']')
		} else {
			doc = append(doc, '}')
		}
	}
	l := DefaultLimits()
	l.MaxDepth = depth
	out, err := Canonicalize(JCS, doc, l)
	if err != nil || string(out) != string(doc) {
		t.Fatalf("depth %d: err %v, equal %v", depth, err, string(out) == string(doc))
	}
	l.MaxDepth = depth - 1
	var r Refusal
	if _, err := Canonicalize(JCS, doc, l); !errors.As(err, &r) || r.Code != TooDeep {
		t.Fatalf("depth %d with limit %d: %v", depth, depth-1, err)
	}
}

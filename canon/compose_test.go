// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"bytes"
	"errors"
	"strconv"
	"testing"
)

func refusalOf(t *testing.T, err error) Refusal {
	t.Helper()
	var r Refusal
	if !errors.As(err, &r) {
		t.Fatalf("got %v, want a Refusal", err)
	}
	return r
}

func TestVector(t *testing.T) {
	l := DefaultLimits()
	v, err := VectorOf([]byte("{\"b\": 2, \"a\": [1.0, 1e21, \"\u00e9\\n\"]}"), l)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(v.Canonical()), "{\"a\":[1,1e+21,\"\u00e9\\n\"],\"b\":2}"; got != want {
		t.Fatalf("canonical %q, want %q", got, want)
	}
	if v.ByteLength() != len(v.Canonical()) || v.Scheme() != JCS {
		t.Fatal("byte length or scheme")
	}
	d, _ := Digest(JCS, v.Canonical(), l, "sha256")
	if v.Digest() != d {
		t.Fatalf("digest %s, want %s", v.Digest(), d)
	}
	doc := v.JSON()
	if err := Check(JCS, doc, l); err != nil {
		t.Fatalf("vector JSON is not canonical: %v", err)
	}
	want := `{"byte_length":` + strconv.Itoa(v.ByteLength()) +
		`,"canonical":"{\"a\":[1,1e+21,\"` + "\u00e9" + `\\n\"],\"b\":2}","digest":"` + d + `","scheme":"jcs/rfc8785"}`
	if string(doc) != want {
		t.Fatalf("JSON\n got %s\nwant %s", doc, want)
	}
	// The returned bytes are a copy.
	c := v.Canonical()
	c[0] = 'X'
	if v.Canonical()[0] != '{' {
		t.Fatal("Canonical aliases the vector")
	}
}

func TestVectorOfCanonicalChecks(t *testing.T) {
	l := DefaultLimits()
	if _, err := VectorOfCanonical([]byte(`{"a":1}`), l); err != nil {
		t.Fatal(err)
	}
	if r := refusalOf(t, func() error { _, e := VectorOfCanonical([]byte(`{"a": 1}`), l); return e }()); r.Code != NotCanonical {
		t.Fatalf("code %s", r.Code)
	}
	if r := refusalOf(t, func() error { _, e := VectorOfCanonical([]byte{0xff}, l); return e }()); r.Code != InvalidUTF8 {
		t.Fatalf("code %s", r.Code)
	}
	in := []byte(`[1]`)
	v, _ := VectorOfCanonical(in, l)
	in[1] = '2'
	if string(v.Canonical()) != `[1]` {
		t.Fatal("VectorOfCanonical aliases its input")
	}
}

func TestNDJSON(t *testing.T) {
	l := DefaultLimits()
	in := []byte("{\"b\":2,\"a\":1}\n{\"d\":4,\"c\":3}\n[1.0]\n")
	cases := []struct {
		in   string
		head int
		want string
	}{
		{string(in), 0, `[{"a":1,"b":2},{"c":3,"d":4},[1]]`},
		{string(in), -1, `[{"a":1,"b":2},{"c":3,"d":4},[1]]`},
		{string(in), 2, `[{"a":1,"b":2},{"c":3,"d":4}]`},
		{"1\n2\nnot json\r\n", 2, `[1,2]`},
		{" 1\t\n", 0, `[1]`},
	}
	for _, c := range cases {
		got, err := CanonicalizeNDJSON([]byte(c.in), c.head, l)
		if err != nil || string(got) != c.want {
			t.Fatalf("%q head %d: %s, %v; want %s", c.in, c.head, got, err, c.want)
		}
	}
}

func TestNDJSONRefusals(t *testing.T) {
	l := DefaultLimits()
	for _, bad := range []string{"", `{"a":1}`, "{\"a\":1}\r\n", "{\"a\":1}\n\n", "{\"a\":1}\n   \n", "\n", " \r\n", "1\n2"} {
		_, err := CanonicalizeNDJSON([]byte(bad), 0, l)
		if r := refusalOf(t, err); r.Code != InvalidJSON {
			t.Fatalf("%q: %s", bad, r.Code)
		}
	}
	_, err := CanonicalizeNDJSON([]byte("1\n2\n3\n"), 4, l)
	if r := refusalOf(t, err); r.Code != InvalidJSON {
		t.Fatalf("short head: %s", r.Code)
	}
	_, err = CanonicalizeNDJSON([]byte("1\n{\"a\":1,\"a\":2}\n"), 0, l)
	if r := refusalOf(t, err); r != (Refusal{DuplicateMember, 2 + 7}) {
		t.Fatalf("offset: %+v", r)
	}
	_, err = CanonicalizeNDJSON([]byte("1\n2\r\n"), 0, l)
	if r := refusalOf(t, err); r != (Refusal{InvalidJSON, 3}) {
		t.Fatalf("CR offset: %+v", r)
	}
}

func TestNDJSONLimits(t *testing.T) {
	tight := func(maxBytes, maxDepth int) Limits {
		l := DefaultLimits()
		l.MaxBytes, l.MaxDepth = maxBytes, maxDepth
		return l
	}
	code := func(in string, head int, l Limits) Code {
		_, err := CanonicalizeNDJSON([]byte(in), head, l)
		if err == nil {
			return ""
		}
		return refusalOf(t, err).Code
	}
	for _, c := range []struct {
		in         string
		head       int
		bytes, dep int
		want       Code
	}{
		{"1\n2\n", 0, 4, 1, ""},
		{"1\n2\n", 0, 3, 1, TooLarge},
		{"1\n2\n", 1, 2, 1, ""},
		{"[]\n", 0, 16, 1, TooDeep},
		{"[]\n", 0, 16, 2, ""},
		{"1\n", 0, 16, 0, TooDeep},
		{"1\n", 0, 16, -3, TooDeep},
	} {
		if got := code(c.in, c.head, tight(c.bytes, c.dep)); got != c.want {
			t.Fatalf("%q head %d bytes %d depth %d: %q, want %q", c.in, c.head, c.bytes, c.dep, got, c.want)
		}
	}
}

func TestSortCanonicalSet(t *testing.T) {
	l := DefaultLimits()
	for in, want := range map[string]string{
		`[{"stream":"b","seq":2},{"stream":"a","seq":1}]`: `[{"seq":1,"stream":"a"},{"seq":2,"stream":"b"}]`,
		`[]`:                                 `[]`,
		`[10, 9, "b", "a", [1,"x,y"], null]`: `["a","b",10,9,[1,"x,y"],null]`,
		`["\"]", "\\"]`:                      `["\"]","\\"]`,
	} {
		got, err := SortCanonicalSet([]byte(in), l)
		if err != nil || string(got) != want {
			t.Fatalf("%s: %s, %v; want %s", in, got, err, want)
		}
	}
	for _, dup := range []string{`[{"a":1,"b":2},{"b":2,"a":1}]`, `[1, 1.0]`, `["x","x"]`, `[[],[]]`} {
		_, err := SortCanonicalSet([]byte(dup), l)
		if r := refusalOf(t, err); r.Code != DuplicateSetElement {
			t.Fatalf("%s: %s", dup, r.Code)
		}
	}
	for _, non := range []string{`{}`, `123`, `"s"`, `null`, `true`} {
		_, err := SortCanonicalSet([]byte(non), l)
		if r := refusalOf(t, err); r.Code != NotAnArray {
			t.Fatalf("%s: %s", non, r.Code)
		}
	}
	_, err := SortCanonicalSet([]byte(`[22,1,22]`), l)
	if r := refusalOf(t, err); r != (Refusal{DuplicateSetElement, 6}) {
		t.Fatalf("offset %+v", r)
	}
}

func TestCheckCanonicalSet(t *testing.T) {
	l := DefaultLimits()
	if err := CheckCanonicalSet([]byte(`[{"seq":1},{"seq":2}]`), l); err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]Code{
		`[{"seq":2},{"seq":1}]`:  NotCanonical,
		`[{"seq":1}, {"seq":2}]`: NotCanonical,
		`[1,1]`:                  DuplicateSetElement,
		`{}`:                     NotAnArray,
	} {
		if r := refusalOf(t, CheckCanonicalSet([]byte(in), l)); r.Code != want {
			t.Fatalf("%s: %s, want %s", in, r.Code, want)
		}
	}
}

func TestAssembleCanonicalSet(t *testing.T) {
	l := DefaultLimits()
	elems := [][]byte{[]byte(`"b"`), []byte(`"a"`)}
	got, err := AssembleCanonicalSet(elems, l)
	if err != nil || string(got) != `["a","b"]` {
		t.Fatalf("%s, %v", got, err)
	}
	if string(elems[0]) != `"b"` {
		t.Fatal("caller's slice was reordered")
	}
	if got, err := AssembleCanonicalSet(nil, l); err != nil || string(got) != `[]` {
		t.Fatalf("empty: %s, %v", got, err)
	}
	if _, err := AssembleCanonicalSet([][]byte{[]byte(`1.0`)}, l); refusalOf(t, err).Code != NotCanonical {
		t.Fatal("non-canonical element accepted")
	}
	if _, err := AssembleCanonicalSet([][]byte{[]byte(`1`), []byte(`1`)}, l); refusalOf(t, err).Code != DuplicateSetElement {
		t.Fatal("duplicate accepted")
	}
	shallow := l
	shallow.MaxDepth = 1
	if _, err := AssembleCanonicalSet([][]byte{[]byte(`[]`)}, shallow); refusalOf(t, err).Code != TooDeep {
		t.Fatal("depth not enforced")
	}
}

func TestSplitMatchesReparse(t *testing.T) {
	l := DefaultLimits()
	c, err := Canonicalize(JCS, []byte(`[{"a":"],[{\"}"},[[],{}],"\\",-0.5,1e+21,true,null,"x"]`), l)
	if err != nil {
		t.Fatal(err)
	}
	parts, ok := splitArray(c)
	if !ok || len(parts) != 8 {
		t.Fatalf("parts %d", len(parts))
	}
	for _, p := range parts {
		if err := Check(JCS, p, l); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
	}
	if !bytes.Equal(join(parts), c) {
		t.Fatal("join(split) != canonical")
	}
}

func TestNDJSONSizeLimitComesFirstAndIsBounded(t *testing.T) {
	l := DefaultLimits()
	l.MaxBytes = 3
	for in, want := range map[string]Code{
		"12345":  TooLarge,
		"123":    InvalidJSON,
		"1\n2":   InvalidJSON,
		"1\n234": TooLarge,
		"12\n":   "",
		"123\n":  TooLarge,
	} {
		_, err := CanonicalizeNDJSON([]byte(in), 0, l)
		got := Code("")
		if err != nil {
			got = refusalOf(t, err).Code
		}
		if got != want {
			t.Fatalf("%q: %q, want %q", in, got, want)
		}
	}
	_, err := CanonicalizeNDJSON(bytes.Repeat([]byte("x"), 1<<20), 0, l)
	if r := refusalOf(t, err); r != (Refusal{TooLarge, 3}) {
		t.Fatalf("long line: %+v", r)
	}
}

func TestZeroVector(t *testing.T) {
	var v Vector
	if v.Canonical() != nil || v.Digest() != "" || v.ByteLength() != 0 || v.JSON() != nil {
		t.Fatalf("zero Vector: %q %q %d %q", v.Canonical(), v.Digest(), v.ByteLength(), v.JSON())
	}
	if _, err := VectorOf([]byte("{"), DefaultLimits()); err == nil {
		t.Fatal("VectorOf accepted invalid input")
	}
}

func TestCheckCanonicalSetOffset(t *testing.T) {
	if r := refusalOf(t, CheckCanonicalSet([]byte(`[2,1]`), DefaultLimits())); r != (Refusal{NotCanonical, 1}) {
		t.Fatalf("%+v", r)
	}
}

func TestAssembleBoundsTheWholeInput(t *testing.T) {
	at := func(n int) Limits { l := DefaultLimits(); l.MaxBytes = n; return l }
	code := func(elems [][]byte, l Limits) Code {
		_, err := AssembleCanonicalSet(elems, l)
		if err == nil {
			return ""
		}
		return refusalOf(t, err).Code
	}
	b := func(s ...string) [][]byte {
		out := make([][]byte, len(s))
		for i, x := range s {
			out[i] = []byte(x)
		}
		return out
	}
	for _, c := range []struct {
		elems [][]byte
		max   int
		want  Code
	}{
		{b("0", "1"), 5, ""},
		{b("0", "1"), 4, TooLarge},
		{b("0"), 1, TooLarge},
		{nil, 1, TooLarge},
		{b("1", "not json"), 4, TooLarge},
		{make([][]byte, 1_000_000), 3, InvalidJSON},
		{make([][]byte, 1_000_000), 16 << 20, InvalidJSON},
	} {
		if got := code(c.elems, at(c.max)); got != c.want {
			t.Fatalf("%d elements, max %d: %q, want %q", len(c.elems), c.max, got, c.want)
		}
	}
}

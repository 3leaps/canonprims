// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"errors"
	"fmt"
	"testing"
	"unicode/utf16"
)

func noncharacters() []rune {
	var v []rune
	for r := rune(0xFDD0); r <= 0xFDEF; r++ {
		v = append(v, r)
	}
	for plane := rune(0); plane <= 0x10; plane++ {
		v = append(v, plane<<16|0xFFFE, plane<<16|0xFFFF)
	}
	return v
}

func escapeRune(r rune) string {
	if r < 0x10000 {
		return fmt.Sprintf(`\u%04x`, r)
	}
	hi, lo := utf16.EncodeRune(r)
	return fmt.Sprintf(`\u%04x\u%04x`, hi, lo)
}

func refusalCode(t *testing.T, doc string, l Limits) Code {
	t.Helper()
	_, err := Canonicalize(JCS, []byte(doc), l)
	if err == nil {
		return ""
	}
	var r Refusal
	if !errors.As(err, &r) {
		t.Fatalf("%q: %v", doc, err)
	}
	return r.Code
}

// All 66 noncharacters, in every input form, are refused.
func TestEveryNoncharacter(t *testing.T) {
	all := noncharacters()
	if len(all) != 66 {
		t.Fatalf("%d noncharacters", len(all))
	}
	l := DefaultLimits()
	for _, r := range all {
		raw, esc := string(r), escapeRune(r)
		for _, doc := range []string{
			`"` + raw + `"`,
			`"` + esc + `"`,
			`{"` + raw + `":1}`,
			`{"` + esc + `":1}`,
			`["ok","x` + esc + `y"]`,
		} {
			if got := refusalCode(t, doc, l); got != Noncharacter {
				t.Errorf("U+%04X in %q: %q", r, doc, got)
			}
		}
	}
}

func TestNoncharacterNeighbours(t *testing.T) {
	l := DefaultLimits()
	neighbours := []rune{0xFDCF, 0xFDF0}
	for plane := rune(0); plane <= 0x10; plane++ {
		neighbours = append(neighbours, plane<<16|0xFFFD)
		if plane > 0 {
			neighbours = append(neighbours, plane<<16)
		}
	}
	for _, r := range neighbours {
		for _, doc := range []string{`"` + string(r) + `"`, `"` + escapeRune(r) + `"`} {
			if got := refusalCode(t, doc, l); got != "" {
				t.Errorf("U+%04X in %q: %q", r, doc, got)
			}
		}
	}
}

func TestNoncharacterVersusStringLimit(t *testing.T) {
	l := DefaultLimits()
	l.MaxStringBytes = 3
	for doc, want := range map[string]Code{
		"\"abcd\uffff\"":  TooLarge,     // raw U+FFFF after the limit is passed
		"\"abcd\\uffff\"": TooLarge,     // escaped
		"\"ab\uffff\"":    Noncharacter, // raw, reached first
		"\"ab\\uffff\"":   Noncharacter, // escaped, reached first
	} {
		if got := refusalCode(t, doc, l); got != want {
			t.Errorf("%q: %q, want %q", doc, got, want)
		}
	}
}

// Limits apply to the input; canonical output can be longer.
func TestLimitsApplyToInput(t *testing.T) {
	l := DefaultLimits()
	l.MaxBytes = 4
	out, err := Canonicalize(JCS, []byte("1e20"), l)
	if err != nil || string(out) != "100000000000000000000" {
		t.Fatalf("%q %v", out, err)
	}
	if got := refusalCode(t, string(out), l); got != TooLarge {
		t.Fatalf("output under the same limits: %q", got)
	}
	l.MaxBytes = len(out)
	if again, err := Canonicalize(JCS, out, l); err != nil || string(again) != string(out) {
		t.Fatalf("output under fitting limits: %q %v", again, err)
	}
}

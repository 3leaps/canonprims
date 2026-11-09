// SPDX-License-Identifier: MIT OR Apache-2.0

package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("write refused") }

func TestRunWritesResults(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run("", strings.NewReader("7b7d\n5b315d\n"), &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if got, want := out.String(), "ok 7b7d\nok 5b315d\n"; got != want {
		t.Fatalf("stdout %q, want %q", got, want)
	}
}

func TestRunRefusesBadHex(t *testing.T) {
	for _, bad := range []string{"7b7d\n7B7D\n", "7b7d\n+17b\n", "7b7d\n7b7\n", "7b7d\n7b7d\r\n"} {
		var out, errOut bytes.Buffer
		if code := run("", strings.NewReader(bad), &out, &errOut); code != 2 {
			t.Fatalf("%q: exit %d, want 2", bad, code)
		}
		if out.String() != "ok 7b7d\n" || !strings.Contains(errOut.String(), "line 2: not valid hex") {
			t.Fatalf("%q: stdout %q, stderr %q", bad, out.String(), errOut.String())
		}
	}
}

// A failed write must never exit 0: the crosscheck compares this output byte
// for byte, and a truncated result that exits 0 would look like agreement.
func TestRunFailsOnWriteError(t *testing.T) {
	var errOut bytes.Buffer
	if code := run("", strings.NewReader("7b7d\n"), failingWriter{}, &errOut); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "write refused") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

func TestOperations(t *testing.T) {
	cases := []struct{ mode, in, want string }{
		{"jcs", "7b7d", "ok 7b7d\n"},
		{"sort-set", "5b322c315d", "ok 5b312c325d\n"},
		{"sort-set", "5b312c315d", "duplicate_set_element\n"},
		{"check-set", "5b322c315d", "not_canonical\n"},
		{"check-set", "7b7d", "not_an_array\n"},
		{"ndjson", "320a310a", "ok 5b322c315d\n"},
		{"ndjson:1", "320a310a", "ok 5b325d\n"},
		{"ndjson-set", "320a310a", "ok 5b312c325d\n"},
		{"ndjson:3", "320a310a", "invalid_json\n"},
	}
	for _, c := range cases {
		var out, errOut bytes.Buffer
		if code := run(c.mode, strings.NewReader(c.in+"\n"), &out, &errOut); code != 0 || out.String() != c.want {
			t.Fatalf("%s %s: exit %d, stdout %q, stderr %q", c.mode, c.in, code, out.String(), errOut.String())
		}
	}
	for _, bad := range []string{"nope", "ndjson:", "ndjson:0", "ndjson:+1", "ndjson:x", "ndjson-set:-1"} {
		var out, errOut bytes.Buffer
		if code := run(bad, strings.NewReader("7b7d\n"), &out, &errOut); code != 2 || out.Len() != 0 {
			t.Fatalf("%q: exit %d, stdout %q", bad, code, out.String())
		}
	}
}

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
	if code := run(strings.NewReader("7b7d\n5b315d\n"), &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if got, want := out.String(), "ok 7b7d\nok 5b315d\n"; got != want {
		t.Fatalf("stdout %q, want %q", got, want)
	}
}

func TestRunRefusesBadHex(t *testing.T) {
	for _, bad := range []string{"7b7d\n7B7D\n", "7b7d\n+17b\n", "7b7d\n7b7\n", "7b7d\n7b7d\r\n"} {
		var out, errOut bytes.Buffer
		if code := run(strings.NewReader(bad), &out, &errOut); code != 2 {
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
	if code := run(strings.NewReader("7b7d\n"), failingWriter{}, &errOut); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "write refused") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

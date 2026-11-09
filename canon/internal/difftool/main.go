// SPDX-License-Identifier: MIT OR Apache-2.0

// Command difftool is the canonprims differential driver for the Go
// implementation. Each LF-terminated stdin line is the lowercase hex of one
// input (an empty line is the empty input); for each it writes
// "ok <hex of canonical bytes>" or "<refusal code>". It always uses the
// default limits, exits 0 at end of input, and exits 2 on a line that is not
// valid hex or when a write fails (a truncated result must never exit 0).
//
// An optional argument selects the operation applied to each input:
// "jcs" (the default), "vector" (the vector JSON), "sort-set", "check-set"
// (writes the input when it is already a canonical set), "ndjson[:N]" and
// "ndjson-set[:N]" (NDJSON elements assembled as a canonical set). N is the
// head; without it every line is used. An unknown operation exits 2.
package main

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"

	"github.com/3leaps/canonprims/canon"
)

func main() {
	mode := ""
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	os.Exit(run(mode, os.Stdin, os.Stdout, os.Stderr))
}

type operation func(in []byte, lim canon.Limits) ([]byte, error)

// headOf parses the optional ":N" suffix of an NDJSON mode.
func headOf(mode, name string) (int, bool) {
	if mode == name {
		return 0, true
	}
	rest, ok := strings.CutPrefix(mode, name+":")
	if !ok || rest == "" || strings.TrimLeft(rest, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.Atoi(rest)
	return n, err == nil && n >= 1
}

func operationFor(mode string) (operation, bool) {
	switch mode {
	case "", "jcs":
		return func(in []byte, l canon.Limits) ([]byte, error) { return canon.Canonicalize(canon.JCS, in, l) }, true
	case "vector":
		return func(in []byte, l canon.Limits) ([]byte, error) {
			v, err := canon.VectorOf(in, l)
			if err != nil {
				return nil, err
			}
			return v.JSON(), nil
		}, true
	case "sort-set":
		return canon.SortCanonicalSet, true
	case "check-set":
		return func(in []byte, l canon.Limits) ([]byte, error) { return in, canon.CheckCanonicalSet(in, l) }, true
	}
	if head, ok := headOf(mode, "ndjson"); ok {
		return func(in []byte, l canon.Limits) ([]byte, error) { return canon.CanonicalizeNDJSON(in, head, l) }, true
	}
	if head, ok := headOf(mode, "ndjson-set"); ok {
		return func(in []byte, l canon.Limits) ([]byte, error) {
			elements, err := canon.NDJSONElements(in, head, l)
			if err != nil {
				return nil, err
			}
			// As the command does: the lines were bounded when selected.
			l.MaxBytes = math.MaxInt
			return canon.AssembleCanonicalSet(elements, l)
		}, true
	}
	return nil, false
}

func run(mode string, stdin io.Reader, stdout, stderr io.Writer) int {
	op, ok := operationFor(mode)
	if !ok {
		_, _ = fmt.Fprintf(stderr, "difftool: unknown operation %q\n", mode)
		return 2
	}
	r := bufio.NewReaderSize(stdin, 1<<20)
	w := bufio.NewWriterSize(stdout, 1<<20)
	// fail reports to stderr after flushing whatever results were written.
	fail := func(format string, args ...any) int {
		_ = w.Flush()
		_, _ = fmt.Fprintf(stderr, format, args...)
		return 2
	}
	done := func() int {
		if err := w.Flush(); err != nil {
			_, _ = fmt.Fprintf(stderr, "difftool: write: %v\n", err)
			return 2
		}
		return 0
	}
	lim := canon.DefaultLimits()
	for lineNo := 1; ; lineNo++ {
		line, err := r.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			// Long line: accumulate the rest.
			buf := append([]byte(nil), line...)
			for err == bufio.ErrBufferFull {
				line, err = r.ReadSlice('\n')
				buf = append(buf, line...)
			}
			line = buf
		}
		if err != nil && err != io.EOF {
			return fail("difftool: read: %v\n", err)
		}
		if err == io.EOF && len(line) == 0 {
			return done()
		}
		if n := len(line); n > 0 && line[n-1] == '\n' {
			line = line[:n-1]
		}
		in, ok := decodeLowerHex(line)
		if !ok {
			return fail("difftool: line %d: not valid hex\n", lineNo)
		}
		var werr error
		out, cerr := op(in, lim)
		if cerr != nil {
			var ref canon.Refusal
			if !errors.As(cerr, &ref) {
				return fail("difftool: %v\n", cerr)
			}
			_, werr = w.WriteString(string(ref.Code))
		} else {
			_, werr = w.WriteString("ok " + hex.EncodeToString(out))
		}
		if werr == nil {
			werr = w.WriteByte('\n')
		}
		if werr != nil {
			return fail("difftool: write: %v\n", werr)
		}
		if err == io.EOF {
			return done()
		}
	}
}

// decodeLowerHex decodes lowercase hex; any other byte is invalid.
func decodeLowerHex(s []byte) ([]byte, bool) {
	if len(s)%2 != 0 {
		return nil, false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return nil, false
		}
	}
	out := make([]byte, len(s)/2)
	if _, err := hex.Decode(out, s); err != nil {
		return nil, false
	}
	return out, true
}

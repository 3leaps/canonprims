// SPDX-License-Identifier: MIT OR Apache-2.0

// Command difftool is the canonprims differential driver for the Go
// implementation. Each LF-terminated stdin line is the lowercase hex of one
// input (an empty line is the empty input); for each it writes
// "ok <hex of canonical bytes>" or "<refusal code>". It always uses the
// default limits, exits 0 at end of input, and exits 2 on a line that is not
// valid hex or when a write fails (a truncated result must never exit 0).
package main

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/3leaps/canonprims/canon"
)

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr))
}

func run(stdin io.Reader, stdout, stderr io.Writer) int {
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
		out, cerr := canon.Canonicalize(canon.JCS, in, lim)
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

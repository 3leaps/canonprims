// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func FuzzCanonicalize(f *testing.F) {
	dir := corpusDir()
	if raw, err := os.ReadFile(filepath.Join(dir, "cases.json")); err == nil {
		var idx corpusIndex
		if json.Unmarshal(raw, &idx) == nil {
			for _, c := range idx.Cases {
				if c.Input == "" {
					continue
				}
				if in, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(c.Input))); err == nil {
					f.Add(in)
				}
			}
		}
	}
	f.Add([]byte(`{"a":[1,2.5e-7,"x\u0000"],"b":{"":null}}`))
	l := DefaultLimits()
	f.Fuzz(func(t *testing.T, in []byte) {
		out, err := Canonicalize(JCS, in, l)
		if err != nil {
			var r Refusal
			if !errors.As(err, &r) || r.Code == NotCanonical {
				t.Fatalf("unexpected error %v", err)
			}
			if r.Offset < 0 || r.Offset > len(in) {
				t.Fatalf("offset %d outside input of %d bytes", r.Offset, len(in))
			}
			return
		}
		if !json.Valid(out) {
			t.Fatalf("output is not valid JSON: %q", out)
		}
		again, err := Canonicalize(JCS, out, l)
		if err != nil {
			t.Fatalf("canonical output refused: %v\n in: %q\nout: %q", err, in, out)
		}
		if !bytes.Equal(again, out) {
			t.Fatalf("not idempotent\n in: %q\nout: %q\nagain: %q", in, out, again)
		}
		if err := Check(JCS, out, l); err != nil {
			t.Fatalf("Check(output) = %v", err)
		}
		cerr := Check(JCS, in, l)
		if bytes.Equal(in, out) != (cerr == nil) {
			t.Fatalf("Check(input) = %v, input==output is %v", cerr, bytes.Equal(in, out))
		}
	})
}

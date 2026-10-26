// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type corpusLimits struct {
	MaxBytes         *int `json:"max_bytes"`
	MaxDepth         *int `json:"max_depth"`
	MaxObjectMembers *int `json:"max_object_members"`
	MaxStringBytes   *int `json:"max_string_bytes"`
}

type corpusCase struct {
	ID       string `json:"id"`
	Input    string `json:"input"`
	Generate *struct {
		Prefix string `json:"prefix"`
		Unit   string `json:"unit"`
		Count  int    `json:"count"`
		Suffix string `json:"suffix"`
	} `json:"generate"`
	Expect string        `json:"expect"`
	Output string        `json:"output"`
	Digest string        `json:"digest"`
	Limits *corpusLimits `json:"limits"`
}

type corpusIndex struct {
	Corpus        string       `json:"corpus"`
	Scheme        string       `json:"scheme"`
	DefaultLimits corpusLimits `json:"default_limits"`
	Cases         []corpusCase `json:"cases"`
}

func corpusDir() string {
	if d := os.Getenv("CANONPRIMS_CORPUS_DIR"); d != "" {
		return d
	}
	return filepath.Join("..", "conformance", "canonical-json", "v0")
}

func loadCorpus(t testing.TB) (string, *corpusIndex) {
	t.Helper()
	dir := corpusDir()
	raw, err := os.ReadFile(filepath.Join(dir, "cases.json"))
	if err != nil {
		if testing.Short() {
			t.Skipf("corpus not found at %s: %v", dir, err)
		}
		t.Fatalf("corpus not found at %s (set CANONPRIMS_CORPUS_DIR): %v", dir, err)
	}
	var idx corpusIndex
	if err := json.Unmarshal(raw, &idx); err != nil {
		t.Fatalf("cases.json: %v", err)
	}
	return dir, &idx
}

func (l *corpusLimits) apply(base Limits) Limits {
	if l == nil {
		return base
	}
	if l.MaxBytes != nil {
		base.MaxBytes = *l.MaxBytes
	}
	if l.MaxDepth != nil {
		base.MaxDepth = *l.MaxDepth
	}
	if l.MaxObjectMembers != nil {
		base.MaxObjectMembers = *l.MaxObjectMembers
	}
	if l.MaxStringBytes != nil {
		base.MaxStringBytes = *l.MaxStringBytes
	}
	return base
}

func caseInput(t testing.TB, dir string, c corpusCase) []byte {
	t.Helper()
	if c.Generate != nil {
		g := c.Generate
		var b bytes.Buffer
		b.Grow(len(g.Prefix) + len(g.Unit)*g.Count + len(g.Suffix))
		b.WriteString(g.Prefix)
		for i := 0; i < g.Count; i++ {
			b.WriteString(g.Unit)
		}
		b.WriteString(g.Suffix)
		return b.Bytes()
	}
	in, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(c.Input)))
	if err != nil {
		t.Fatalf("%s: %v", c.ID, err)
	}
	return in
}

func outcome(err error) string {
	if err == nil {
		return "ok"
	}
	var r Refusal
	if errors.As(err, &r) {
		return string(r.Code)
	}
	return "error:" + err.Error()
}

func TestCorpus(t *testing.T) {
	dir, idx := loadCorpus(t)
	if idx.Scheme != string(JCS) || idx.Corpus != "canonical-json/v0" {
		t.Fatalf("unexpected corpus %q / scheme %q", idx.Corpus, idx.Scheme)
	}
	defaults := idx.DefaultLimits.apply(Limits{})
	if defaults != DefaultLimits() {
		t.Fatalf("corpus default_limits %+v != DefaultLimits() %+v", defaults, DefaultLimits())
	}
	var results strings.Builder
	for _, c := range idx.Cases {
		in := caseInput(t, dir, c)
		lim := c.Limits.apply(defaults)
		out, err := Canonicalize(JCS, in, lim)
		got := outcome(err)
		if err == nil {
			sum := sha256.Sum256(out)
			results.WriteString(c.ID + " ok " + hex.EncodeToString(sum[:]) + "\n")
		} else {
			results.WriteString(c.ID + " " + got + "\n")
		}
		if got != c.Expect {
			t.Errorf("%s: got %s, want %s", c.ID, got, c.Expect)
			continue
		}
		if c.Expect != "ok" {
			if cerr := Check(JCS, in, lim); outcome(cerr) != c.Expect {
				t.Errorf("%s: Check got %s, want %s", c.ID, outcome(cerr), c.Expect)
			}
			if _, derr := Digest(JCS, in, lim, "sha256"); outcome(derr) != c.Expect {
				t.Errorf("%s: Digest got %s, want %s", c.ID, outcome(derr), c.Expect)
			}
			continue
		}
		var want []byte
		if c.Output == "=input" {
			want = in
		} else {
			want, err = os.ReadFile(filepath.Join(dir, filepath.FromSlash(c.Output)))
			if err != nil {
				t.Fatalf("%s: %v", c.ID, err)
			}
		}
		if !bytes.Equal(out, want) {
			t.Errorf("%s: output mismatch\n got: %.200q\nwant: %.200q", c.ID, out, want)
		}
		d, err := Digest(JCS, in, lim, "sha256")
		if err != nil || d != c.Digest {
			t.Errorf("%s: digest %q (%v), want %q", c.ID, d, err, c.Digest)
		}
		if err := Check(JCS, out, lim); err != nil {
			t.Errorf("%s: Check(output) = %v", c.ID, err)
		}
		cerr := Check(JCS, in, lim)
		if bytes.Equal(in, out) {
			if cerr != nil {
				t.Errorf("%s: Check(canonical input) = %v", c.ID, cerr)
			}
		} else if outcome(cerr) != string(NotCanonical) {
			t.Errorf("%s: Check(non-canonical input) = %v, want not_canonical", c.ID, cerr)
		}
	}
	if path := os.Getenv("CANONPRIMS_RESULTS_OUT"); path != "" {
		if err := os.WriteFile(path, []byte(results.String()), 0o644); err != nil {
			t.Fatalf("CANONPRIMS_RESULTS_OUT: %v", err)
		}
	}
}

func TestCorpusDigestMatchesManifest(t *testing.T) {
	dir, _ := loadCorpus(t)
	raw, err := os.ReadFile(filepath.Join(dir, "MANIFEST.json"))
	if err != nil {
		t.Fatalf("MANIFEST.json: %v", err)
	}
	sum := sha256.Sum256(raw)
	if got := "sha256:" + hex.EncodeToString(sum[:]); got != CorpusDigest {
		t.Fatalf("MANIFEST.json digest %s != CorpusDigest %s", got, CorpusDigest)
	}
}

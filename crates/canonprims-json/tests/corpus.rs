// SPDX-License-Identifier: MIT OR Apache-2.0

//! The `canonical-json/v0` conformance corpus.
//!
//! The corpus lives at the repository root (`conformance/`) and is shared
//! with the Go twin. `CANONPRIMS_CORPUS_DIR` overrides the location;
//! `CANONPRIMS_RESULTS_OUT` writes the harness result lines for the
//! cross-language comparison.

use std::fs;
use std::path::PathBuf;

use canonprims_json::canonprims_core::{Code, DigestAlg, Limits};

fn corpus_dir() -> PathBuf {
    std::env::var_os("CANONPRIMS_CORPUS_DIR").map_or_else(
        || PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/canonical-json/v0"),
        PathBuf::from,
    )
}

/// Minimal reader for the corpus index. The index is ASCII JSON written by
/// `scripts/canonical-json-corpus.py`; rather than take a JSON dependency, we
/// canonicalize it with the crate under test and walk the canonical text,
/// which has a fixed shape.
mod index {
    #[derive(Debug, Default)]
    pub struct Case {
        pub id: String,
        pub input: Option<String>,
        pub generate: Option<(String, String, usize, String)>,
        pub expect: String,
        pub output: Option<String>,
        pub digest: Option<String>,
        pub limits: Vec<(String, usize)>,
    }

    pub struct Cursor<'a> {
        s: &'a [u8],
        pos: usize,
    }

    impl<'a> Cursor<'a> {
        pub fn new(s: &'a [u8]) -> Self {
            Self { s, pos: 0 }
        }
        fn eat(&mut self, b: u8) {
            assert_eq!(self.s[self.pos], b, "index shape at {}", self.pos);
            self.pos += 1;
        }
        fn peek(&self) -> u8 {
            self.s[self.pos]
        }
        pub fn string(&mut self) -> String {
            self.eat(b'"');
            let mut out = String::new();
            loop {
                match self.peek() {
                    b'"' => {
                        self.pos += 1;
                        return out;
                    }
                    b'\\' => {
                        self.pos += 1;
                        let c = self.peek();
                        self.pos += 1;
                        match c {
                            b'u' => {
                                let hex =
                                    std::str::from_utf8(&self.s[self.pos..self.pos + 4]).unwrap();
                                self.pos += 4;
                                out.push(
                                    char::from_u32(u32::from_str_radix(hex, 16).unwrap()).unwrap(),
                                );
                            }
                            b'n' => out.push('\n'),
                            b't' => out.push('\t'),
                            b'r' => out.push('\r'),
                            b'b' => out.push('\u{8}'),
                            b'f' => out.push('\u{c}'),
                            other => out.push(other as char),
                        }
                    }
                    _ => {
                        let start = self.pos;
                        while !matches!(self.peek(), b'"' | b'\\') {
                            self.pos += 1;
                        }
                        out.push_str(std::str::from_utf8(&self.s[start..self.pos]).unwrap());
                    }
                }
            }
        }
        pub fn number(&mut self) -> usize {
            let start = self.pos;
            while self.peek().is_ascii_digit() {
                self.pos += 1;
            }
            std::str::from_utf8(&self.s[start..self.pos])
                .unwrap()
                .parse()
                .unwrap()
        }
        /// Visit each member of an object.
        pub fn object(&mut self, mut f: impl FnMut(&mut Self, &str)) {
            self.eat(b'{');
            if self.peek() == b'}' {
                self.pos += 1;
                return;
            }
            loop {
                let k = self.string();
                self.eat(b':');
                f(self, &k);
                if self.peek() == b',' {
                    self.pos += 1;
                } else {
                    self.eat(b'}');
                    return;
                }
            }
        }
        pub fn array(&mut self, mut f: impl FnMut(&mut Self)) {
            self.eat(b'[');
            if self.peek() == b']' {
                self.pos += 1;
                return;
            }
            loop {
                f(self);
                if self.peek() == b',' {
                    self.pos += 1;
                } else {
                    self.eat(b']');
                    return;
                }
            }
        }
        pub fn limits(&mut self) -> Vec<(String, usize)> {
            let mut v = Vec::new();
            self.object(|c, k| {
                let n = c.number();
                v.push((k.to_owned(), n));
            });
            v
        }
        pub fn case(&mut self) -> Case {
            let mut case = Case::default();
            self.object(|c, k| match k {
                "id" => case.id = c.string(),
                "input" => case.input = Some(c.string()),
                "expect" => case.expect = c.string(),
                "output" => case.output = Some(c.string()),
                "digest" => case.digest = Some(c.string()),
                "note" => {
                    c.string();
                }
                "limits" => case.limits = c.limits(),
                "generate" => {
                    let (mut p, mut u, mut n, mut s) =
                        (String::new(), String::new(), 0, String::new());
                    c.object(|c, k| match k {
                        "prefix" => p = c.string(),
                        "unit" => u = c.string(),
                        "count" => n = c.number(),
                        "suffix" => s = c.string(),
                        other => panic!("unknown generate field {other}"),
                    });
                    case.generate = Some((p, u, n, s));
                }
                other => panic!("unknown case field {other}"),
            });
            case
        }
    }
}

fn apply(limits: &mut Limits, overrides: &[(String, usize)]) {
    for (k, v) in overrides {
        match k.as_str() {
            "max_bytes" => limits.max_bytes = *v,
            "max_depth" => limits.max_depth = *v,
            "max_object_members" => limits.max_object_members = *v,
            "max_string_bytes" => limits.max_string_bytes = *v,
            other => panic!("unknown limit {other}"),
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    DigestAlg::Sha256.format(bytes)["sha256:".len()..].to_owned()
}

#[test]
fn manifest_digest_is_pinned() {
    let manifest = fs::read(corpus_dir().join("MANIFEST.json")).expect("corpus MANIFEST.json");
    assert_eq!(
        DigestAlg::Sha256.format(&manifest),
        canonprims_json::CORPUS_DIGEST,
        "vendored corpus differs from the pinned digest"
    );
}

#[test]
fn corpus() {
    let dir = corpus_dir();
    let raw = fs::read(dir.join("cases.json")).expect("corpus cases.json");
    let canonical =
        canonprims_json::canonicalize(&raw, &Limits::default()).expect("index canonicalizes");

    let mut defaults = Limits::default();
    let mut cases = Vec::new();
    let mut cursor = index::Cursor::new(&canonical);
    cursor.object(|c, k| match k {
        "cases" => c.array(|c| cases.push(c.case())),
        "default_limits" => apply(&mut defaults, &c.limits()),
        "corpus" | "scheme" => {
            c.string();
        }
        other => panic!("unknown index field {other}"),
    });
    assert_eq!(
        defaults,
        Limits::default(),
        "corpus default limits differ from the crate"
    );
    assert!(cases.len() > 150, "corpus looks truncated: {}", cases.len());

    let mut results = String::new();
    let mut failures = Vec::new();
    for case in &cases {
        let input = match (&case.input, &case.generate) {
            (Some(path), None) => fs::read(dir.join(path)).unwrap(),
            (None, Some((p, u, n, s))) => {
                let mut v = String::with_capacity(p.len() + u.len() * n + s.len());
                v.push_str(p);
                for _ in 0..*n {
                    v.push_str(u);
                }
                v.push_str(s);
                v.into_bytes()
            }
            _ => panic!("{}: needs exactly one of input/generate", case.id),
        };
        let mut limits = Limits::default();
        apply(&mut limits, &case.limits);
        let got = canonprims_json::canonicalize(&input, &limits);
        match &got {
            Ok(bytes) => results.push_str(&format!("{} ok {}\n", case.id, sha256_hex(bytes))),
            Err(r) => results.push_str(&format!("{} {}\n", case.id, r.code)),
        }
        let outcome = got.as_ref().map_or_else(|r| r.code.as_str(), |_| "ok");
        if outcome != case.expect {
            failures.push(format!(
                "{}: expected {}, got {outcome}",
                case.id, case.expect
            ));
            continue;
        }
        let Ok(bytes) = got else { continue };
        let want = match case.output.as_deref() {
            Some("=input") => input.clone(),
            Some(path) => fs::read(dir.join(path)).unwrap(),
            None => panic!("{}: ok case without output", case.id),
        };
        if bytes != want {
            failures.push(format!("{}: canonical bytes differ", case.id));
            continue;
        }
        if Some(DigestAlg::Sha256.format(&bytes)) != case.digest {
            failures.push(format!("{}: digest differs", case.id));
        }
        if canonprims_json::check(&bytes, &limits).is_err() {
            failures.push(format!("{}: check refused its own output", case.id));
        }
        let checked = canonprims_json::check(&input, &limits);
        let expect_canonical = input == bytes;
        match (checked, expect_canonical) {
            (Ok(()), true) => {}
            (Err(r), false) if r.code == Code::NotCanonical => {}
            (other, _) => failures.push(format!("{}: check on input gave {other:?}", case.id)),
        }
    }
    if let Some(path) = std::env::var_os("CANONPRIMS_RESULTS_OUT") {
        fs::write(path, &results).unwrap();
    }
    assert!(
        failures.is_empty(),
        "{} corpus failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

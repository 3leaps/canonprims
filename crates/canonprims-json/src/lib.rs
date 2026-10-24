// SPDX-License-Identifier: MIT OR Apache-2.0

//! RFC 8785 JSON Canonicalization Scheme (`jcs/rfc8785`) over a strict
//! I-JSON loader.
//!
//! One pass over the input both validates and emits: each object level
//! holds only its own members (decoded name plus already-canonical value
//! bytes), sorts them by UTF-16 code units when it closes, and writes them
//! out. No intermediate document tree is built.
//!
//! Every refusal code, the order in which defects are detected, and the
//! limits are specified in `docs/spec/jcs-rfc8785.md` and pinned by the
//! `canonical-json/v0` corpus. Nothing is silently repaired: duplicate
//! names, lone surrogates, non-finite numbers, inexact integers and
//! invalid UTF-8 are refusals.

use canonprims_core::{Code, DigestAlg, Limits, Refusal, Scheme, SchemeInfo};

mod number;

pub use canonprims_core;

/// `sha256:` of the `canonical-json/v0` corpus `MANIFEST.json` this build is
/// gated against. The corpus test fails if the vendored manifest differs.
pub const CORPUS_DIGEST: &str =
    "sha256:de3ac543580ddb90f7e3a6e72239097274d3635ea783f302a9260b5a7d0c8d90";

/// The scheme this crate implements.
pub const SCHEME: Scheme = Scheme::JcsRfc8785;

/// Canonical bytes of `input`, or the refusal.
pub fn canonicalize(input: &[u8], limits: &Limits) -> Result<Vec<u8>, Refusal> {
    if input.len() > limits.max_bytes {
        return Err(Refusal::new(Code::TooLarge, limits.max_bytes));
    }
    let text =
        std::str::from_utf8(input).map_err(|e| Refusal::new(Code::InvalidUtf8, e.valid_up_to()))?;
    let mut parser = Parser {
        text,
        bytes: input,
        pos: 0,
        depth: 0,
        limits,
    };
    let mut out = Vec::with_capacity(input.len());
    parser.skip_ws();
    parser.value(&mut out)?;
    parser.skip_ws();
    if parser.pos != input.len() {
        return Err(parser.refuse(Code::InvalidJson));
    }
    Ok(out)
}

/// `Ok` when `input` is already byte-identical to its canonical form.
pub fn check(input: &[u8], limits: &Limits) -> Result<(), Refusal> {
    let canonical = canonicalize(input, limits)?;
    if canonical == input {
        return Ok(());
    }
    let at = canonical
        .iter()
        .zip(input)
        .position(|(a, b)| a != b)
        .unwrap_or(canonical.len().min(input.len()));
    Err(Refusal::new(Code::NotCanonical, at))
}

/// Canonicalize, then hash: `<alg>:<lowercase hex>`.
pub fn digest(input: &[u8], limits: &Limits, alg: DigestAlg) -> Result<String, Refusal> {
    Ok(alg.format(&canonicalize(input, limits)?))
}

/// What this scheme is and which corpus gated it.
pub fn scheme_info() -> SchemeInfo {
    SchemeInfo {
        scheme: SCHEME,
        spec: "RFC 8785",
        corpus: "canonical-json/v0",
        corpus_digest: CORPUS_DIGEST,
    }
}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    pos: usize,
    depth: usize,
    limits: &'a Limits,
}

/// An open container on the parser's explicit stack.
enum Frame {
    /// An array.
    Array,
    /// An object. Members are written to the shared output as they are read,
    /// each as `"name":value`; `spans[i]` is member i's byte range. If the
    /// names arrive out of order the members are re-sorted when it closes.
    Object {
        names: Vec<String>,
        seen: std::collections::HashSet<String>,
        spans: Vec<(usize, usize)>,
        sorted: bool,
    },
}

fn utf16_less(a: &str, b: &str) -> bool {
    a.encode_utf16().lt(b.encode_utf16())
}

impl Parser<'_> {
    fn refuse(&self, code: Code) -> Refusal {
        Refusal::new(code, self.pos)
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    /// Parse one value and append its canonical form to `out`.
    ///
    /// Containers are tracked on an explicit stack, not the call stack, so a
    /// caller-raised `max_depth` cannot overflow the thread's stack. Output is
    /// written in place; an object whose names arrive unsorted re-sorts only
    /// its own bytes when it closes.
    fn value(&mut self, out: &mut Vec<u8>) -> Result<(), Refusal> {
        let mut stack: Vec<Frame> = Vec::new();
        let mut scratch: Vec<u8> = Vec::new();
        loop {
            // Parse a value at the current position.
            match self.peek() {
                Some(b'[') => {
                    self.enter()?;
                    out.push(b'[');
                    self.skip_ws();
                    if self.peek() == Some(b']') {
                        self.pos += 1;
                        out.push(b']');
                        self.depth -= 1;
                    } else {
                        stack.push(Frame::Array);
                        continue;
                    }
                }
                Some(b'{') => {
                    self.enter()?;
                    out.push(b'{');
                    self.skip_ws();
                    if self.peek() == Some(b'}') {
                        self.pos += 1;
                        out.push(b'}');
                        self.depth -= 1;
                    } else {
                        let mut frame = Frame::Object {
                            names: Vec::new(),
                            seen: std::collections::HashSet::new(),
                            spans: Vec::new(),
                            sorted: true,
                        };
                        self.member(&mut frame, out)?;
                        stack.push(frame);
                        continue;
                    }
                }
                Some(b'n') => self.literal(b"null", out)?,
                Some(b't') => self.literal(b"true", out)?,
                Some(b'f') => self.literal(b"false", out)?,
                Some(b'"') => {
                    let s = self.string()?;
                    write_string(&s, out);
                }
                Some(b'-' | b'0'..=b'9') => self.number(out)?,
                _ => return Err(self.refuse(Code::InvalidJson)),
            }
            // A value is complete: close containers until one wants another
            // value.
            loop {
                let Some(top) = stack.last_mut() else {
                    return Ok(());
                };
                if let Frame::Object { spans, .. } = top {
                    if let Some(last) = spans.last_mut() {
                        last.1 = out.len();
                    }
                }
                self.skip_ws();
                let (more, close) = match top {
                    Frame::Array => (b',', b']'),
                    Frame::Object { .. } => (b',', b'}'),
                };
                match self.peek() {
                    Some(b) if b == more => {
                        self.pos += 1;
                        match top {
                            Frame::Array => {
                                out.push(b',');
                                self.skip_ws();
                            }
                            Frame::Object { .. } => self.member(top, out)?,
                        }
                        break;
                    }
                    Some(b) if b == close => {
                        self.pos += 1;
                        if let Some(Frame::Object {
                            names,
                            spans,
                            sorted: false,
                            ..
                        }) = stack.pop()
                        {
                            reorder(&names, &spans, out, &mut scratch);
                        }
                        out.push(close);
                        self.depth -= 1;
                    }
                    _ => return Err(self.refuse(Code::InvalidJson)),
                }
            }
        }
    }

    /// Read the next member's `"name":` in the order the spec fixes (opening
    /// quote, member count, name, duplicate, colon), write it, and leave
    /// `pos` at the value.
    fn member(&mut self, frame: &mut Frame, out: &mut Vec<u8>) -> Result<(), Refusal> {
        let Frame::Object {
            names,
            seen,
            spans,
            sorted,
        } = frame
        else {
            unreachable!("member on an array frame");
        };
        self.skip_ws();
        if self.peek() != Some(b'"') {
            return Err(self.refuse(Code::InvalidJson));
        }
        if names.len() >= self.limits.max_object_members {
            return Err(self.refuse(Code::TooLarge));
        }
        let name_at = self.pos;
        let name = self.string()?;
        if seen.contains(&name) {
            return Err(Refusal::new(Code::DuplicateMember, name_at));
        }
        self.skip_ws();
        if self.peek() != Some(b':') {
            return Err(self.refuse(Code::InvalidJson));
        }
        self.pos += 1;
        self.skip_ws();
        if let Some(prev) = names.last() {
            out.push(b',');
            if *sorted && !utf16_less(prev, &name) {
                *sorted = false;
            }
        }
        let start = out.len();
        write_string(&name, out);
        out.push(b':');
        spans.push((start, out.len()));
        seen.insert(name.clone());
        names.push(name);
        Ok(())
    }

    fn literal(&mut self, token: &[u8], out: &mut Vec<u8>) -> Result<(), Refusal> {
        if self.bytes.get(self.pos..self.pos + token.len()) != Some(token) {
            return Err(self.refuse(Code::InvalidJson));
        }
        self.pos += token.len();
        out.extend_from_slice(token);
        Ok(())
    }

    /// Enter a container at the opening bracket, before reading inside it.
    fn enter(&mut self) -> Result<(), Refusal> {
        if self.depth >= self.limits.max_depth {
            return Err(self.refuse(Code::TooDeep));
        }
        self.depth += 1;
        self.pos += 1;
        Ok(())
    }

    /// Decode a string starting at its opening quote.
    fn string(&mut self) -> Result<String, Refusal> {
        self.pos += 1;
        let mut s = String::new();
        loop {
            // Copy the run of plain bytes in one step; the input is already
            // valid UTF-8, so a run ending at an ASCII byte is a char boundary.
            let run = self.bytes[self.pos..]
                .iter()
                .position(|&b| b == b'"' || b == b'\\' || b < 0x20)
                .unwrap_or(self.bytes.len() - self.pos);
            if run > 0 {
                let chunk = &self.text[self.pos..self.pos + run];
                // Noncharacters are three or four UTF-8 bytes, all with a lead
                // byte of 0xEF or 0xF0-0xF4; skip the per-char scan otherwise.
                let suspect = chunk.bytes().any(|b| b == 0xef || b >= 0xf0);
                if suspect || s.len() + run > self.limits.max_string_bytes {
                    // Walk code points in order: the first defect wins.
                    let mut len = s.len();
                    for (i, ch) in chunk.char_indices() {
                        if is_noncharacter(ch) {
                            self.pos += i;
                            return Err(self.refuse(Code::Noncharacter));
                        }
                        len += ch.len_utf8();
                        if len > self.limits.max_string_bytes {
                            self.pos += i + ch.len_utf8();
                            return Err(self.refuse(Code::TooLarge));
                        }
                    }
                }
                s.push_str(chunk);
                self.pos += run;
            }
            match self.peek() {
                None => return Err(self.refuse(Code::InvalidJson)),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(s);
                }
                Some(b'\\') => {
                    let at = self.pos;
                    let ch = self.escape()?;
                    if is_noncharacter(ch) {
                        return Err(Refusal::new(Code::Noncharacter, at));
                    }
                    if s.len() + ch.len_utf8() > self.limits.max_string_bytes {
                        return Err(self.refuse(Code::TooLarge));
                    }
                    s.push(ch);
                }
                Some(_) => return Err(self.refuse(Code::InvalidJson)),
            }
        }
    }

    /// Decode one escape starting at its backslash.
    fn escape(&mut self) -> Result<char, Refusal> {
        self.pos += 1;
        let Some(b) = self.peek() else {
            return Err(self.refuse(Code::InvalidJson));
        };
        self.pos += 1;
        let ch = match b {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{0008}',
            b'f' => '\u{000c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => return self.unicode_escape(),
            _ => {
                self.pos -= 1;
                return Err(self.refuse(Code::InvalidJson));
            }
        };
        Ok(ch)
    }

    /// Decode the rest of a `\u` escape (the `\u` is consumed).
    fn unicode_escape(&mut self) -> Result<char, Refusal> {
        let unit = self.hex4()?;
        if (0xdc00..=0xdfff).contains(&unit) {
            return Err(self.refuse(Code::LoneSurrogate));
        }
        if !(0xd800..=0xdbff).contains(&unit) {
            // Not a surrogate, so it is a scalar value.
            return char::from_u32(u32::from(unit)).ok_or_else(|| self.refuse(Code::InvalidJson));
        }
        if self.bytes.get(self.pos..self.pos + 2) != Some(b"\\u") {
            return Err(self.refuse(Code::LoneSurrogate));
        }
        self.pos += 2;
        let low = self.hex4()?;
        if !(0xdc00..=0xdfff).contains(&low) {
            return Err(self.refuse(Code::LoneSurrogate));
        }
        let cp = 0x10000 + (((u32::from(unit) - 0xd800) << 10) | (u32::from(low) - 0xdc00));
        char::from_u32(cp).ok_or_else(|| self.refuse(Code::LoneSurrogate))
    }

    fn hex4(&mut self) -> Result<u16, Refusal> {
        let mut value = 0u16;
        for _ in 0..4 {
            let digit = match self.peek() {
                Some(b @ b'0'..=b'9') => b - b'0',
                Some(b @ b'a'..=b'f') => b - b'a' + 10,
                Some(b @ b'A'..=b'F') => b - b'A' + 10,
                _ => return Err(self.refuse(Code::InvalidJson)),
            };
            self.pos += 1;
            value = (value << 4) | u16::from(digit);
        }
        Ok(value)
    }

    fn digits(&mut self) -> usize {
        let start = self.pos;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
        self.pos - start
    }

    fn number(&mut self, out: &mut Vec<u8>) -> Result<(), Refusal> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return Err(self.refuse(Code::InvalidJson)),
        }
        let mut integer = true;
        if self.peek() == Some(b'.') {
            integer = false;
            self.pos += 1;
            if self.digits() == 0 {
                return Err(self.refuse(Code::InvalidJson));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            integer = false;
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if self.digits() == 0 {
                return Err(self.refuse(Code::InvalidJson));
            }
        }
        // `01` ends the token at `0`; the caller refuses the `1` as content
        // that cannot follow a value.
        let token = &self.text[start..self.pos];
        let value = if integer {
            number::admit_integer(token).ok_or(Refusal::new(Code::IntegerOutsideBinary64, start))?
        } else {
            let v: f64 = token
                .parse()
                .map_err(|_| Refusal::new(Code::InvalidJson, start))?;
            if !v.is_finite() {
                return Err(Refusal::new(Code::NonFiniteNumber, start));
            }
            v
        };
        number::write_es6(value, out);
        Ok(())
    }
}

/// U+FDD0..=U+FDEF, or any code point whose low 16 bits are FFFE or FFFF.
fn is_noncharacter(ch: char) -> bool {
    let cp = u32::from(ch);
    (0xfdd0..=0xfdef).contains(&cp) || cp & 0xfffe == 0xfffe
}

/// Write `s` as an RFC 8785 string (ECMAScript `JSON.stringify` escaping).
fn write_string(s: &str, out: &mut Vec<u8>) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    out.push(b'"');
    let bytes = s.as_bytes();
    let mut plain = 0;
    for (i, &b) in bytes.iter().enumerate() {
        let short = match b {
            b'"' => b'"',
            b'\\' => b'\\',
            0x08 => b'b',
            0x09 => b't',
            0x0a => b'n',
            0x0c => b'f',
            0x0d => b'r',
            0x00..=0x1f => 0,
            _ => continue,
        };
        out.extend_from_slice(&bytes[plain..i]);
        plain = i + 1;
        out.push(b'\\');
        if short != 0 {
            out.push(short);
        } else {
            out.extend_from_slice(b"u00");
            out.push(HEX[usize::from(b >> 4)]);
            out.push(HEX[usize::from(b & 0xf)]);
        }
    }
    out.extend_from_slice(&bytes[plain..]);
    out.push(b'"');
}

/// Rewrite an object's members (all bytes from the first span to the end
/// of `out`) in UTF-16 name order.
fn reorder(names: &[String], spans: &[(usize, usize)], out: &mut Vec<u8>, scratch: &mut Vec<u8>) {
    let base = spans[0].0;
    scratch.clear();
    scratch.extend_from_slice(&out[base..]);
    let mut order: Vec<usize> = (0..names.len()).collect();
    order.sort_by(|&a, &b| names[a].encode_utf16().cmp(names[b].encode_utf16()));
    out.truncate(base);
    for (i, &k) in order.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        let (from, to) = spans[k];
        out.extend_from_slice(&scratch[from - base..to - base]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canon(s: &str) -> Result<String, Code> {
        canonicalize(s.as_bytes(), &Limits::default())
            .map(|b| String::from_utf8(b).unwrap())
            .map_err(|r| r.code)
    }

    #[test]
    fn sorts_and_strips() {
        assert_eq!(
            canon("{\n \"y\": 2, \"x\": 1 }").unwrap(),
            r#"{"x":1,"y":2}"#
        );
    }

    #[test]
    fn leading_zero_is_invalid() {
        assert_eq!(canon("01"), Err(Code::InvalidJson));
        assert_eq!(canon("[-01]"), Err(Code::InvalidJson));
    }

    #[test]
    fn check_reports_not_canonical() {
        let l = Limits::default();
        assert!(check(br#"{"a":1}"#, &l).is_ok());
        let r = check(br#"{"a": 1}"#, &l).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::NotCanonical, 5));
        assert_eq!(check(b"[1,]", &l).unwrap_err().code, Code::InvalidJson);
    }

    #[test]
    fn digest_prefixes_and_refuses() {
        let l = Limits::default();
        assert_eq!(
            digest(b"{}", &l, DigestAlg::Sha256).unwrap(),
            "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        );
        assert_eq!(
            digest(b"{", &l, DigestAlg::Sha256).unwrap_err().code,
            Code::InvalidJson
        );
    }

    #[test]
    fn duplicate_offset_points_at_the_name() {
        let r = canonicalize(br#"{"a":1,"a":2}"#, &Limits::default()).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::DuplicateMember, 7));
    }

    #[test]
    fn scheme_info_names_the_corpus() {
        let info = scheme_info();
        assert_eq!(info.scheme.id(), "jcs/rfc8785");
        assert_eq!(info.corpus, "canonical-json/v0");
        assert_eq!(info.corpus_digest, CORPUS_DIGEST);
    }

    #[test]
    fn string_limit_counts_decoded_bytes() {
        let l = Limits {
            max_string_bytes: 2,
            ..Limits::default()
        };
        assert!(canonicalize("\"\u{e9}\"".as_bytes(), &l).is_ok());
        assert_eq!(
            canonicalize("\"\u{e9}a\"".as_bytes(), &l).unwrap_err().code,
            Code::TooLarge
        );
        assert_eq!(
            canonicalize("\"a\u{e9}\"".as_bytes(), &l).unwrap_err().code,
            Code::TooLarge
        );
    }
}

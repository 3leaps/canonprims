// SPDX-License-Identifier: MIT OR Apache-2.0

//! Helpers built on `canonicalize`: golden vectors, strict NDJSON prefixes
//! framed as one canonical array, and canonical sets.
//!
//! Each helper is specified in `docs/spec/jcs-rfc8785.md` (section
//! "Composition helpers"). None of them repairs input: every element is
//! canonicalized under the caller's limits, and every defect is a refusal.

use std::num::NonZeroUsize;

use canonprims_core::{Code, DigestAlg, Limits, Refusal, Scheme};

use crate::{canonicalize, check, write_string, SCHEME};

/// A golden test vector: canonical bytes, their length and their digest.
///
/// The bytes are always canonical under `jcs/rfc8785`: a `Vector` is only
/// made by [`vector`] or by [`Vector::from_canonical`], which checks them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Vector {
    canonical: Vec<u8>,
    digest: String,
}

impl Vector {
    /// Wrap bytes that must already be canonical under `limits`; otherwise
    /// the refusal from [`check`] (`not_canonical` included).
    pub fn from_canonical(canonical: Vec<u8>, limits: &Limits) -> Result<Self, Refusal> {
        check(&canonical, limits)?;
        Ok(Self::new(canonical))
    }

    fn new(canonical: Vec<u8>) -> Self {
        let digest = DigestAlg::Sha256.format(&canonical);
        Self { canonical, digest }
    }

    /// The canonical bytes.
    pub fn canonical(&self) -> &[u8] {
        &self.canonical
    }

    /// The length of the canonical bytes.
    pub fn byte_length(&self) -> usize {
        self.canonical.len()
    }

    /// `sha256:<lowercase hex>` of the canonical bytes.
    pub fn digest(&self) -> &str {
        &self.digest
    }

    /// The scheme the bytes are canonical under.
    pub fn scheme(&self) -> Scheme {
        SCHEME
    }

    /// The vector as one canonical JSON object, without a trailing newline:
    /// `{"byte_length":N,"canonical":"...","digest":"sha256:...","scheme":"jcs/rfc8785"}`.
    pub fn to_json(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.canonical.len() + 160);
        out.extend_from_slice(b"{\"byte_length\":");
        out.extend_from_slice(self.canonical.len().to_string().as_bytes());
        out.extend_from_slice(b",\"canonical\":");
        // Canonical bytes are valid UTF-8 by construction.
        let text = std::str::from_utf8(&self.canonical).expect("canonical bytes are UTF-8");
        write_string(text, &mut out);
        out.extend_from_slice(b",\"digest\":\"");
        out.extend_from_slice(self.digest.as_bytes());
        out.extend_from_slice(b"\",\"scheme\":\"");
        out.extend_from_slice(SCHEME.id().as_bytes());
        out.extend_from_slice(b"\"}");
        out
    }
}

/// Canonicalize `input`, then describe the result as a [`Vector`].
pub fn vector(input: &[u8], limits: &Limits) -> Result<Vector, Refusal> {
    Ok(Vector::new(canonicalize(input, limits)?))
}

/// The limits for one element of an array the helpers assemble: one level
/// shallower, so the assembled array stays within `limits.max_depth`.
fn element_limits(limits: &Limits) -> Result<Limits, Refusal> {
    if limits.max_depth == 0 {
        return Err(Refusal::new(Code::TooDeep, 0));
    }
    Ok(Limits {
        max_depth: limits.max_depth - 1,
        ..*limits
    })
}

/// The canonical bytes of each line of a strict NDJSON prefix.
///
/// Lines are read from the start of `input`: all of them, or exactly the
/// first `head`. Every selected line must end with LF, must not end with
/// CR LF, and must not be empty or only spaces, tabs and CRs; each is one
/// JSON text canonicalized under `limits` one level shallower. The selected
/// lines together must fit in `limits.max_bytes`; bytes after them are never
/// examined. Framing defects, too few lines and empty input are
/// `invalid_json`. Refusal offsets are into `input`.
pub fn ndjson_elements(
    input: &[u8],
    head: Option<NonZeroUsize>,
    limits: &Limits,
) -> Result<Vec<Vec<u8>>, Refusal> {
    let element = element_limits(limits)?;
    let want = head.map(NonZeroUsize::get);
    let mut out = Vec::new();
    let mut pos = 0;
    while want != Some(out.len()) && pos < input.len() {
        // Look for the LF only where it may lie: a line ending past
        // `max_bytes` is refused without scanning the rest of the input.
        let window = input.len().min(limits.max_bytes);
        let Some(len) = input[pos..window].iter().position(|&b| b == b'\n') else {
            if input.len() > limits.max_bytes {
                return Err(Refusal::new(Code::TooLarge, limits.max_bytes));
            }
            // The final line has no LF.
            return Err(Refusal::new(Code::InvalidJson, input.len()));
        };
        let end = pos + len + 1;
        let body = &input[pos..pos + len];
        if body.last() == Some(&b'\r') {
            return Err(Refusal::new(Code::InvalidJson, pos + len - 1));
        }
        if body.iter().all(|b| matches!(b, b' ' | b'\t' | b'\r')) {
            return Err(Refusal::new(Code::InvalidJson, pos));
        }
        let canonical =
            canonicalize(body, &element).map_err(|r| Refusal::new(r.code, pos + r.offset))?;
        out.push(canonical);
        pos = end;
    }
    if out.is_empty() || want.is_some_and(|n| out.len() < n) {
        return Err(Refusal::new(Code::InvalidJson, pos));
    }
    Ok(out)
}

/// A strict NDJSON prefix (see [`ndjson_elements`]) as one canonical array,
/// lines in input order.
pub fn canonicalize_ndjson(
    input: &[u8],
    head: Option<NonZeroUsize>,
    limits: &Limits,
) -> Result<Vec<u8>, Refusal> {
    let elements = ndjson_elements(input, head, limits)?;
    Ok(join(elements.iter().map(Vec::as_slice)))
}

/// Canonicalize `input`, which must be an array, as a canonical set: its
/// elements sorted by their canonical bytes (unsigned, byte by byte) with
/// no two identical. A non-array is `not_an_array`; a repeated element is
/// `duplicate_set_element` (elements that differ only in member order or
/// number spelling are the same element).
pub fn sort_canonical_set(input: &[u8], limits: &Limits) -> Result<Vec<u8>, Refusal> {
    let canonical = canonicalize(input, limits)?;
    let elements = split_array(&canonical).ok_or(Refusal::new(Code::NotAnArray, 0))?;
    sort_set(elements)
}

/// `Ok` when `input` is byte-identical to [`sort_canonical_set`] of itself;
/// otherwise that function's refusal, or `not_canonical` at the first
/// differing byte.
pub fn check_canonical_set(input: &[u8], limits: &Limits) -> Result<(), Refusal> {
    let sorted = sort_canonical_set(input, limits)?;
    if sorted == input {
        return Ok(());
    }
    let at = sorted
        .iter()
        .zip(input)
        .position(|(a, b)| a != b)
        .unwrap_or(sorted.len().min(input.len()));
    Err(Refusal::new(Code::NotCanonical, at))
}

/// A canonical set from elements that are each already canonical under
/// `limits` one level shallower (each is checked; the first that is not
/// gives its refusal, `not_canonical` included). Sorted and duplicate-free
/// as in [`sort_canonical_set`]. The elements are the input: together with
/// the array's brackets and commas they must fit in `limits.max_bytes`, and
/// this is checked before each element is examined.
pub fn assemble_canonical_set<E: AsRef<[u8]>>(
    elements: &[E],
    limits: &Limits,
) -> Result<Vec<u8>, Refusal> {
    let element = element_limits(limits)?;
    let mut size: usize = 2;
    let mut parts = Vec::new();
    for e in elements {
        // Take each slice once, so the bytes checked are the bytes kept.
        let part = e.as_ref();
        let comma = usize::from(!parts.is_empty());
        size = size.saturating_add(part.len()).saturating_add(comma);
        if size > limits.max_bytes {
            return Err(Refusal::new(Code::TooLarge, limits.max_bytes));
        }
        check(part, &element)?;
        parts.push(part);
    }
    if size > limits.max_bytes {
        return Err(Refusal::new(Code::TooLarge, limits.max_bytes));
    }
    sort_set(parts)
}

fn join<'a>(elements: impl Iterator<Item = &'a [u8]>) -> Vec<u8> {
    let mut out = vec![b'['];
    for (i, e) in elements.enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(e);
    }
    out.push(b']');
    out
}

fn sort_set(mut elements: Vec<&[u8]>) -> Result<Vec<u8>, Refusal> {
    elements.sort_unstable();
    // The offset is where the repeat would start in the sorted output.
    let mut at = 1;
    for pair in elements.windows(2) {
        at += pair[0].len() + 1;
        if pair[0] == pair[1] {
            return Err(Refusal::new(Code::DuplicateSetElement, at));
        }
    }
    Ok(join(elements.into_iter()))
}

/// The top-level elements of canonical JSON bytes, or `None` when the value
/// is not an array. Canonical bytes have no whitespace outside strings, and
/// inside a string every `"` and `\` is escaped.
fn split_array(canonical: &[u8]) -> Option<Vec<&[u8]>> {
    let inner = canonical.strip_prefix(b"[")?.strip_suffix(b"]")?;
    let mut out = Vec::new();
    if inner.is_empty() {
        return Some(out);
    }
    let (mut depth, mut in_string, mut escaped, mut start) = (0usize, false, false, 0);
    for (i, &b) in inner.iter().enumerate() {
        if in_string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'[' | b'{' => depth += 1,
            b']' | b'}' => depth -= 1,
            b',' if depth == 0 => {
                out.push(&inner[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&inner[start..]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn l() -> Limits {
        Limits::default()
    }

    fn head(n: usize) -> Option<NonZeroUsize> {
        NonZeroUsize::new(n)
    }

    fn code<T>(r: Result<T, Refusal>) -> Code {
        match r {
            Ok(_) => panic!("expected a refusal"),
            Err(r) => r.code,
        }
    }

    #[test]
    fn vector_json_is_canonical_and_consistent() {
        let v = vector(
            "{\"b\": 2, \"a\": [1.0, 1e21, \"\u{e9}\\n\"]}".as_bytes(),
            &l(),
        )
        .unwrap();
        assert_eq!(
            v.canonical(),
            "{\"a\":[1,1e+21,\"\u{e9}\\n\"],\"b\":2}".as_bytes()
        );
        assert_eq!(v.byte_length(), v.canonical().len());
        assert_eq!(v.digest(), DigestAlg::Sha256.format(v.canonical()));
        let json = v.to_json();
        check(&json, &l()).unwrap();
        let expected = format!(
            "{{\"byte_length\":{},\"canonical\":\"{{\\\"a\\\":[1,1e+21,\\\"\u{e9}\\\\n\\\"],\\\"b\\\":2}}\",\"digest\":\"{}\",\"scheme\":\"jcs/rfc8785\"}}",
            v.byte_length(),
            v.digest()
        );
        assert_eq!(String::from_utf8(json).unwrap(), expected);
    }

    #[test]
    fn vector_from_canonical_checks() {
        assert!(Vector::from_canonical(br#"{"a":1}"#.to_vec(), &l()).is_ok());
        assert_eq!(
            code(Vector::from_canonical(br#"{"a": 1}"#.to_vec(), &l())),
            Code::NotCanonical
        );
        assert_eq!(
            code(Vector::from_canonical(vec![0xff], &l())),
            Code::InvalidUtf8
        );
    }

    #[test]
    fn ndjson_frames_in_order() {
        let input = b"{\"b\":2,\"a\":1}\n{\"d\":4,\"c\":3}\n[1.0]\n";
        assert_eq!(
            canonicalize_ndjson(input, None, &l()).unwrap(),
            br#"[{"a":1,"b":2},{"c":3,"d":4},[1]]"#
        );
        assert_eq!(
            canonicalize_ndjson(input, head(2), &l()).unwrap(),
            br#"[{"a":1,"b":2},{"c":3,"d":4}]"#
        );
        // Bytes after the selected lines are never examined.
        assert_eq!(
            canonicalize_ndjson(b"1\n2\nnot json\r\n", head(2), &l()).unwrap(),
            b"[1,2]"
        );
        // Spaces and tabs around a value are JSON whitespace.
        assert_eq!(canonicalize_ndjson(b" 1\t\n", None, &l()).unwrap(), b"[1]");
    }

    #[test]
    fn ndjson_framing_refusals() {
        for bad in [
            &b""[..],
            b"{\"a\":1}",
            b"{\"a\":1}\r\n",
            b"{\"a\":1}\n\n",
            b"{\"a\":1}\n   \n",
            b"\n",
            b" \r\n",
            b"1\n2",
        ] {
            assert_eq!(
                code(canonicalize_ndjson(bad, None, &l())),
                Code::InvalidJson,
                "{bad:?}"
            );
        }
        assert_eq!(
            code(canonicalize_ndjson(b"1\n2\n3\n", head(4), &l())),
            Code::InvalidJson
        );
    }

    #[test]
    fn ndjson_offsets_point_into_the_input() {
        let r = canonicalize_ndjson(b"1\n{\"a\":1,\"a\":2}\n", None, &l()).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::DuplicateMember, 2 + 7));
        let r = canonicalize_ndjson(b"1\n2\r\n", None, &l()).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::InvalidJson, 3));
    }

    #[test]
    fn ndjson_limits() {
        let tight = |max_bytes, max_depth| Limits {
            max_bytes,
            max_depth,
            ..l()
        };
        assert!(canonicalize_ndjson(b"1\n2\n", None, &tight(4, 1)).is_ok());
        assert_eq!(
            code(canonicalize_ndjson(b"1\n2\n", None, &tight(3, 1))),
            Code::TooLarge
        );
        // Only the selected lines count.
        assert!(canonicalize_ndjson(b"1\n2\n", head(1), &tight(2, 1)).is_ok());
        // Elements sit one level below the array.
        assert_eq!(
            code(canonicalize_ndjson(b"[]\n", None, &tight(16, 1))),
            Code::TooDeep
        );
        assert!(canonicalize_ndjson(b"[]\n", None, &tight(16, 2)).is_ok());
        assert_eq!(
            code(canonicalize_ndjson(b"1\n", None, &tight(16, 0))),
            Code::TooDeep
        );
    }

    #[test]
    fn ndjson_size_limit_comes_first_and_is_bounded() {
        let tight = Limits {
            max_bytes: 3,
            ..l()
        };
        // An unterminated line past the limit is too large, not unterminated.
        assert_eq!(
            code(canonicalize_ndjson(b"12345", None, &tight)),
            Code::TooLarge
        );
        // A line that fits but has no LF is unterminated.
        assert_eq!(
            code(canonicalize_ndjson(b"123", None, &tight)),
            Code::InvalidJson
        );
        assert_eq!(
            code(canonicalize_ndjson(b"1\n2", None, &tight)),
            Code::InvalidJson
        );
        assert_eq!(
            code(canonicalize_ndjson(b"1\n234", None, &tight)),
            Code::TooLarge
        );
        // An LF exactly at the limit is inside it; one byte later is not.
        assert!(canonicalize_ndjson(b"12\n", None, &tight).is_ok());
        assert_eq!(
            code(canonicalize_ndjson(b"123\n", None, &tight)),
            Code::TooLarge
        );
        // Refusing a long line costs no more than the limit.
        let big = vec![b'x'; 1 << 20];
        let r = canonicalize_ndjson(&big, None, &tight).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::TooLarge, 3));
    }

    #[test]
    fn assemble_keeps_the_bytes_it_checked() {
        struct Shifty(std::cell::Cell<bool>);
        impl AsRef<[u8]> for Shifty {
            fn as_ref(&self) -> &[u8] {
                if self.0.replace(true) {
                    b"not-json"
                } else {
                    b"1"
                }
            }
        }
        assert_eq!(
            assemble_canonical_set(&[Shifty(std::cell::Cell::new(false))], &l()).unwrap(),
            b"[1]"
        );
    }

    #[test]
    fn sort_set_sorts_by_canonical_bytes() {
        assert_eq!(
            sort_canonical_set(br#"[{"stream":"b","seq":2},{"stream":"a","seq":1}]"#, &l())
                .unwrap(),
            br#"[{"seq":1,"stream":"a"},{"seq":2,"stream":"b"}]"#
        );
        assert_eq!(sort_canonical_set(b"[]", &l()).unwrap(), b"[]");
        // Byte order, not numeric or code-point-by-UTF-16 order.
        assert_eq!(
            sort_canonical_set(br#"[10, 9, "b", "a", [1,"x,y"], null]"#, &l()).unwrap(),
            br#"["a","b",10,9,[1,"x,y"],null]"#
        );
        assert_eq!(
            sort_canonical_set(b"[\"\\\"]\", \"\\\\\"]", &l()).unwrap(),
            b"[\"\\\"]\",\"\\\\\"]"
        );
    }

    #[test]
    fn sort_set_refusals() {
        for dup in [
            &br#"[{"a":1,"b":2},{"b":2,"a":1}]"#[..],
            b"[1, 1.0]",
            b"[\"x\",\"x\"]",
            b"[[],[]]",
        ] {
            assert_eq!(
                code(sort_canonical_set(dup, &l())),
                Code::DuplicateSetElement,
                "{dup:?}"
            );
        }
        for non in [&b"{}"[..], b"123", b"\"s\"", b"null", b"true"] {
            assert_eq!(code(sort_canonical_set(non, &l())), Code::NotAnArray);
        }
        assert_eq!(code(sort_canonical_set(b"[1,", &l())), Code::InvalidJson);
        let r = sort_canonical_set(b"[22,1,22]", &l()).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::DuplicateSetElement, 6));
    }

    #[test]
    fn check_set() {
        assert!(check_canonical_set(br#"[{"seq":1},{"seq":2}]"#, &l()).is_ok());
        assert_eq!(
            code(check_canonical_set(br#"[{"seq":2},{"seq":1}]"#, &l())),
            Code::NotCanonical
        );
        assert_eq!(
            code(check_canonical_set(br#"[{"seq":1}, {"seq":2}]"#, &l())),
            Code::NotCanonical
        );
        assert_eq!(
            code(check_canonical_set(b"[1,1]", &l())),
            Code::DuplicateSetElement
        );
        assert_eq!(code(check_canonical_set(b"{}", &l())), Code::NotAnArray);
        let r = check_canonical_set(b"[2,1]", &l()).unwrap_err();
        assert_eq!((r.code, r.offset), (Code::NotCanonical, 1));
    }

    #[test]
    fn assemble_checks_each_element() {
        assert_eq!(
            assemble_canonical_set(&[&b"\"b\""[..], b"\"a\""], &l()).unwrap(),
            b"[\"a\",\"b\"]"
        );
        assert_eq!(assemble_canonical_set::<&[u8]>(&[], &l()).unwrap(), b"[]");
        assert_eq!(
            code(assemble_canonical_set(&[&b"1.0"[..]], &l())),
            Code::NotCanonical
        );
        assert_eq!(
            code(assemble_canonical_set(&[&b"1"[..], b"1"], &l())),
            Code::DuplicateSetElement
        );
        let shallow = Limits {
            max_depth: 1,
            ..l()
        };
        assert_eq!(
            code(assemble_canonical_set(&[&b"[]"[..]], &shallow)),
            Code::TooDeep
        );
    }

    #[test]
    fn assemble_bounds_the_whole_input() {
        let at = |max_bytes| Limits { max_bytes, ..l() };
        // "[0,1]" is five bytes.
        assert_eq!(
            assemble_canonical_set(&[&b"0"[..], b"1"], &at(5)).unwrap(),
            b"[0,1]"
        );
        assert_eq!(
            code(assemble_canonical_set(&[&b"0"[..], b"1"], &at(4))),
            Code::TooLarge
        );
        assert_eq!(
            code(assemble_canonical_set(&[&b"0"[..]], &at(1))),
            Code::TooLarge
        );
        assert_eq!(
            code(assemble_canonical_set::<&[u8]>(&[], &at(1))),
            Code::TooLarge
        );
        // The size is checked before an element is examined.
        assert_eq!(
            code(assemble_canonical_set(&[&b"1"[..], b"not json"], &at(4))),
            Code::TooLarge
        );
        // Many empty elements are refused without reserving room for them.
        struct Empty;
        impl AsRef<[u8]> for Empty {
            fn as_ref(&self) -> &[u8] {
                b""
            }
        }
        let many: Vec<Empty> = (0..1_000_000).map(|_| Empty).collect();
        assert_eq!(
            code(assemble_canonical_set(&many, &at(3))),
            Code::InvalidJson
        );
        assert_eq!(code(assemble_canonical_set(&many, &l())), Code::InvalidJson);
    }

    #[test]
    fn split_matches_a_reparse() {
        // Every element split from canonical bytes is itself canonical.
        let doc = br#"[{"a":"],[{\"}"},[[],{}],"\\",-0.5,1e+21,true,null,"x"]"#;
        let canonical = canonicalize(doc, &l()).unwrap();
        let parts = split_array(&canonical).unwrap();
        assert_eq!(parts.len(), 8);
        for p in &parts {
            check(p, &l()).unwrap();
        }
        assert_eq!(join(parts.into_iter()), canonical);
    }
}

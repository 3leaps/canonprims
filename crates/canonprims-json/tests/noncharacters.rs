// SPDX-License-Identifier: MIT OR Apache-2.0

//! All 66 noncharacters, in every input form, and their precedence against
//! the string size limit. Also the expansion boundary of input-only limits.

use canonprims_json::canonicalize;
use canonprims_json::canonprims_core::{Code, Limits};

fn noncharacters() -> Vec<u32> {
    let mut v: Vec<u32> = (0xfdd0..=0xfdef).collect();
    for plane in 0..=0x10 {
        v.push(plane << 16 | 0xfffe);
        v.push(plane << 16 | 0xffff);
    }
    v
}

fn escaped(cp: u32) -> String {
    let ch = char::from_u32(cp).unwrap();
    let mut buf = [0u16; 2];
    ch.encode_utf16(&mut buf)
        .iter()
        .map(|u| format!("\\u{u:04x}"))
        .collect()
}

fn code(input: &str, limits: &Limits) -> Option<Code> {
    canonicalize(input.as_bytes(), limits).err().map(|r| r.code)
}

#[test]
fn every_noncharacter_is_refused_in_every_form() {
    let all = noncharacters();
    assert_eq!(all.len(), 66);
    let l = Limits::default();
    for cp in all {
        let raw = char::from_u32(cp).unwrap().to_string();
        let esc = escaped(cp);
        for doc in [
            format!("\"{raw}\""),
            format!("\"{esc}\""),
            format!("{{\"{raw}\":1}}"),
            format!("{{\"{esc}\":1}}"),
            format!("[\"ok\",\"x{esc}y\"]"),
        ] {
            assert_eq!(
                code(&doc, &l),
                Some(Code::Noncharacter),
                "U+{cp:04X} in {doc:?}"
            );
        }
    }
}

#[test]
fn neighbours_are_admitted() {
    let l = Limits::default();
    let mut neighbours = vec![0xfdcf, 0xfdf0];
    for plane in 0..=0x10u32 {
        neighbours.push(plane << 16 | 0xfffd);
        if plane > 0 {
            neighbours.push(plane << 16);
        }
    }
    for cp in neighbours {
        let raw = char::from_u32(cp).unwrap().to_string();
        assert_eq!(code(&format!("\"{raw}\""), &l), None, "U+{cp:04X}");
        assert_eq!(
            code(&format!("\"{}\"", escaped(cp)), &l),
            None,
            "U+{cp:04X}"
        );
    }
}

#[test]
fn noncharacter_versus_string_limit_first_reached_wins() {
    // U+FFFF is three UTF-8 bytes.
    let small = Limits {
        max_string_bytes: 3,
        ..Limits::default()
    };
    // Size exceeded at "abcd" before the noncharacter is reached.
    assert_eq!(code("\"abcd\u{ffff}\"", &small), Some(Code::TooLarge));
    assert_eq!(code("\"abcd\\uffff\"", &small), Some(Code::TooLarge));
    // Noncharacter reached first: refused as such, though appending it would
    // also exceed the limit.
    assert_eq!(code("\"ab\u{ffff}\"", &small), Some(Code::Noncharacter));
    assert_eq!(code("\"ab\\uffff\"", &small), Some(Code::Noncharacter));
}

#[test]
fn limits_apply_to_input_not_output() {
    let l = Limits {
        max_bytes: 4,
        ..Limits::default()
    };
    let out = canonicalize(b"1e20", &l).unwrap();
    assert_eq!(out, b"100000000000000000000");
    // The output is canonical but longer than max_bytes, so it is refused
    // under the same limits and admitted under limits that fit it.
    assert_eq!(canonicalize(&out, &l).unwrap_err().code, Code::TooLarge);
    let fits = Limits {
        max_bytes: out.len(),
        ..Limits::default()
    };
    assert_eq!(canonicalize(&out, &fits).unwrap(), out);
}

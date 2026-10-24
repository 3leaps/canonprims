// SPDX-License-Identifier: MIT OR Apache-2.0

//! Properties over generated input: no panics, idempotence, and invariance
//! under member order and whitespace.

use canonprims_json::canonprims_core::{Code, Limits};
use canonprims_json::{canonicalize, check};
use proptest::prelude::*;

/// A JSON value with members kept in a chosen order, so the same document can
/// be written several ways.
#[derive(Debug, Clone)]
enum J {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

fn number() -> impl Strategy<Value = String> {
    prop_oneof![
        any::<i32>().prop_map(|i| i.to_string()),
        any::<f64>()
            .prop_filter("finite", |f| f.is_finite())
            .prop_map(|f| format!("{f:e}")),
        (any::<u64>(), -30i32..30).prop_map(|(m, e)| format!("{m}e{e}")),
        Just("9007199254740992".to_owned()),
        Just("-0.0".to_owned()),
    ]
}

fn text() -> impl Strategy<Value = String> {
    prop_oneof![
        "[a-c]{0,3}",
        any::<String>(),
        prop::collection::vec(any::<char>(), 0..4).prop_map(|v| v.into_iter().collect()),
    ]
}

fn value() -> impl Strategy<Value = J> {
    let leaf = prop_oneof![
        Just(J::Null),
        any::<bool>().prop_map(J::Bool),
        number().prop_map(J::Num),
        text().prop_map(J::Str),
    ];
    leaf.prop_recursive(6, 64, 6, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..6).prop_map(J::Arr),
            prop::collection::btree_map(text(), inner, 0..6)
                .prop_map(|m| J::Obj(m.into_iter().collect())),
        ]
    })
}

fn escape(s: &str, out: &mut String, loose: bool) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04X}", c as u32)),
            c if loose && !c.is_ascii() => {
                let mut buf = [0u16; 2];
                for unit in c.encode_utf16(&mut buf) {
                    out.push_str(&format!("\\u{unit:04x}"));
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Write `v`; `seed` picks member order and whitespace, `loose` escapes
/// non-ASCII.
fn write(v: &J, seed: u64, loose: bool, out: &mut String) {
    let ws = if seed.is_multiple_of(3) { " \n" } else { "" };
    match v {
        J::Null => out.push_str("null"),
        J::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        J::Num(n) => out.push_str(n),
        J::Str(s) => escape(s, out, loose),
        J::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(ws);
                write(item, seed.rotate_left(7) ^ i as u64, loose, out);
            }
            out.push(']');
        }
        J::Obj(members) => {
            let mut order: Vec<usize> = (0..members.len()).collect();
            if !seed.is_multiple_of(2) {
                order.reverse();
            }
            if !order.is_empty() {
                let k = (seed as usize) % order.len();
                order.rotate_left(k);
            }
            out.push('{');
            for (n, &i) in order.iter().enumerate() {
                if n > 0 {
                    out.push(',');
                }
                out.push_str(ws);
                escape(&members[i].0, out, loose);
                out.push(':');
                out.push_str(ws);
                write(&members[i].1, seed.rotate_left(13) ^ i as u64, loose, out);
            }
            out.push('}');
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2048))]

    #[test]
    fn arbitrary_bytes_never_panic(input in prop::collection::vec(any::<u8>(), 0..256)) {
        let _ = canonicalize(&input, &Limits::default());
        let _ = check(&input, &Limits::default());
    }

    #[test]
    fn json_like_bytes_never_panic(input in "[\\[\\]{}\":,0-9eE.+\\-\\\\u tnrfalsd]{0,64}") {
        let _ = canonicalize(input.as_bytes(), &Limits::default());
    }

    #[test]
    fn canonical_output_is_canonical(v in value(), seed in any::<u64>()) {
        let mut doc = String::new();
        write(&v, seed, false, &mut doc);
        if let Ok(out) = canonicalize(doc.as_bytes(), &Limits::default()) {
            prop_assert_eq!(canonicalize(&out, &Limits::default()).unwrap(), out.clone());
            prop_assert!(check(&out, &Limits::default()).is_ok());
            prop_assert!(std::str::from_utf8(&out).is_ok());
        }
    }

    #[test]
    fn order_whitespace_and_escapes_do_not_matter(v in value(), a in any::<u64>(), b in any::<u64>()) {
        let (mut x, mut y) = (String::new(), String::new());
        write(&v, a, false, &mut x);
        write(&v, b, true, &mut y);
        let cx = canonicalize(x.as_bytes(), &Limits::default());
        let cy = canonicalize(y.as_bytes(), &Limits::default());
        match (cx, cy) {
            (Ok(p), Ok(q)) => prop_assert_eq!(p, q),
            (Err(p), Err(q)) => prop_assert_eq!(p.code, q.code),
            (p, q) => prop_assert!(false, "{:?} vs {:?}", p.map(|_| ()), q.map(|_| ())),
        }
    }

    #[test]
    fn limits_refuse_rather_than_allocate(
        input in prop::collection::vec(any::<u8>(), 0..128),
        max_bytes in 0usize..64,
        max_depth in 0usize..4,
        max_object_members in 0usize..4,
        max_string_bytes in 0usize..8,
    ) {
        let limits = Limits { max_bytes, max_depth, max_object_members, max_string_bytes };
        if let Ok(out) = canonicalize(&input, &limits) {
            prop_assert!(input.len() <= max_bytes);
            prop_assert!(out.len() <= 4 * input.len() + 2);
        } else if input.len() > max_bytes {
            prop_assert_eq!(canonicalize(&input, &limits).unwrap_err().code, Code::TooLarge);
        }
    }
}

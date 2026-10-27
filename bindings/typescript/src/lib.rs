// SPDX-License-Identifier: MIT OR Apache-2.0

//! The WebAssembly module behind the `@3leaps/canonprims` package: the four
//! verbs of `canonprims-json` over linear memory, with no imports.
//!
//! The module owns two buffers. The caller asks for an input buffer of `len`
//! bytes (`input_reserve`), writes the input at the returned address, and calls
//! a verb with the four limits. A verb returns 0 on success, with the result
//! (canonical bytes or digest text) in the output buffer (`output_ptr`,
//! `output_len`), or 1 on refusal, with the refusal code's wire name in the
//! output buffer and its byte offset from `refusal_offset`. The only Rust-side
//! unsafety is exporting the symbols; no pointer from the caller is ever
//! dereferenced.

use std::cell::RefCell;

use canonprims_json::canonprims_core::{DigestAlg, Limits, Refusal};

#[derive(Default)]
struct State {
    input: Vec<u8>,
    output: Vec<u8>,
    offset: usize,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

const OK: u32 = 0;
const REFUSED: u32 = 1;
const UNKNOWN_ALGORITHM: u32 = 2;

fn limits(
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
) -> Limits {
    Limits {
        max_bytes,
        max_depth,
        max_object_members,
        max_string_bytes,
    }
}

fn run(f: impl FnOnce(&[u8]) -> Result<Vec<u8>, Refusal>) -> u32 {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let result = f(&s.input);
        s.input = Vec::new();
        match result {
            Ok(out) => {
                s.output = out;
                s.offset = 0;
                OK
            }
            Err(r) => {
                s.output = r.code.as_str().as_bytes().to_vec();
                s.offset = r.offset;
                REFUSED
            }
        }
    })
}

/// Replace the input buffer with `len` zero bytes and return its address.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn input_reserve(len: usize) -> *mut u8 {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.input = vec![0; len];
        s.input.as_mut_ptr()
    })
}

/// Address of the output buffer.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn output_ptr() -> *const u8 {
    STATE.with(|s| s.borrow().output.as_ptr())
}

/// Length of the output buffer.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn output_len() -> usize {
    STATE.with(|s| s.borrow().output.len())
}

/// Byte offset of the last refusal.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn refusal_offset() -> usize {
    STATE.with(|s| s.borrow().offset)
}

/// Release both buffers.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn release() {
    STATE.with(|s| *s.borrow_mut() = State::default());
}

/// Canonicalize the input buffer.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn canonicalize(
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
) -> u32 {
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    run(|input| canonprims_json::canonicalize(input, &l))
}

/// Check the input buffer; success leaves the output empty.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn check(
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
) -> u32 {
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    run(|input| canonprims_json::check(input, &l).map(|()| Vec::new()))
}

/// Digest the input buffer with SHA-256; `alg` 0 is the only algorithm.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn digest(
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
    alg: u32,
) -> u32 {
    let alg = match alg {
        0 => DigestAlg::Sha256,
        _ => return UNKNOWN_ALGORITHM,
    };
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    run(|input| canonprims_json::digest(input, &l, alg).map(String::into_bytes))
}

/// Scheme info as `scheme\nspec\ncorpus\ncorpus_digest\nversion` in the output buffer.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn scheme_info() {
    let i = canonprims_json::scheme_info();
    let text = format!(
        "{}\n{}\n{}\n{}\n{}",
        i.scheme.id(),
        i.spec,
        i.corpus,
        i.corpus_digest,
        env!("CARGO_PKG_VERSION")
    );
    STATE.with(|s| s.borrow_mut().output = text.into_bytes());
}

/// Default limits, by index: max_bytes, max_depth, max_object_members, max_string_bytes.
#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn default_limit(which: u32) -> usize {
    match which {
        0 => Limits::DEFAULT_MAX_BYTES,
        1 => Limits::DEFAULT_MAX_DEPTH,
        2 => Limits::DEFAULT_MAX_OBJECT_MEMBERS,
        3 => Limits::DEFAULT_MAX_STRING_BYTES,
        _ => 0,
    }
}

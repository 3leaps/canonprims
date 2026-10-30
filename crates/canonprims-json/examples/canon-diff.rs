// SPDX-License-Identifier: MIT OR Apache-2.0

//! Differential driver (docs/spec/jcs-rfc8785.md, "Conformance harness
//! protocol"): one hex-encoded input per stdin line, one result per stdout
//! line, default limits.

use std::io::{self, BufRead, BufWriter, Write};
use std::process::ExitCode;

use canonprims_json::canonprims_core::Limits;

fn unhex(line: &str) -> Option<Vec<u8>> {
    let bytes = line.as_bytes();
    if !bytes.len().is_multiple_of(2)
        || !bytes.iter().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    (0..bytes.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(line.get(i..i + 2)?, 16).ok())
        .collect()
}

fn main() -> ExitCode {
    let limits = Limits::default();
    let mut stdin = io::stdin().lock();
    let mut out = BufWriter::new(io::stdout().lock());
    let mut raw = Vec::new();
    loop {
        raw.clear();
        match stdin.read_until(b'\n', &mut raw) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => return ExitCode::from(2),
        }
        // LF-terminated only: a CR is not hex and is refused, as in Go.
        if raw.last() == Some(&b'\n') {
            raw.pop();
        }
        let Ok(line) = std::str::from_utf8(&raw) else {
            eprintln!("canon-diff: line is not hex");
            return ExitCode::from(2);
        };
        let Some(input) = unhex(line) else {
            eprintln!("canon-diff: line is not hex");
            return ExitCode::from(2);
        };
        let written = match canonprims_json::canonicalize(&input, &limits) {
            Ok(bytes) => {
                let mut hex = String::with_capacity(bytes.len() * 2 + 4);
                hex.push_str("ok ");
                for b in bytes {
                    hex.push_str(&format!("{b:02x}"));
                }
                writeln!(out, "{hex}")
            }
            Err(r) => writeln!(out, "{}", r.code),
        };
        if written.is_err() {
            return ExitCode::from(5);
        }
    }
    if out.flush().is_err() {
        return ExitCode::from(5);
    }
    ExitCode::SUCCESS
}

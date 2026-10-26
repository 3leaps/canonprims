// SPDX-License-Identifier: MIT OR Apache-2.0

//! The `canon` binary: streams, exit codes and flags.

use std::io::Write;
use std::process::{Command, Output, Stdio};

fn canon(args: &[&str], stdin: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_canon"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // canon may stop reading early (an oversized input), so feed stdin from
    // a thread and let a broken pipe end the write.
    let mut pipe = child.stdin.take().unwrap();
    let data = stdin.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = pipe.write_all(&data);
    });
    let out = child.wait_with_output().unwrap();
    writer.join().unwrap();
    out
}

#[test]
fn canonicalizes_stdin_without_newline() {
    let out = canon(&["jcs"], b"{ \"b\": 1, \"a\": [1.0, -0] }\n");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(out.stdout, br#"{"a":[1,0],"b":1}"#);
    assert!(out.stderr.is_empty());
}

#[test]
fn digest_line() {
    let out = canon(&["jcs", "--digest"], b"{}");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(
        out.stdout,
        b"sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\n"
    );
    let out = canon(&["jcs", "--digest", "-"], b"{}");
    assert_eq!(out.status.code(), Some(0));
    // No algorithm choice is offered until a second algorithm exists.
    let out = canon(&["jcs", "--digest=sha256"], b"{}");
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
}

#[test]
fn check_mode() {
    let ok = canon(&["jcs", "--check"], br#"{"a":1}"#);
    assert_eq!(ok.status.code(), Some(0));
    assert!(ok.stdout.is_empty());
    let not = canon(&["jcs", "--check"], b"{\"a\": 1}");
    assert_eq!(not.status.code(), Some(1));
    assert!(not.stdout.is_empty());
    assert!(String::from_utf8_lossy(&not.stderr).contains("not_canonical"));
}

#[test]
fn refusal_is_exit_1_with_code_on_stderr() {
    let out = canon(&["jcs"], br#"{"a":1,"a":2}"#);
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("jcs/rfc8785") && err.contains("duplicate_member"),
        "{err}"
    );
}

#[test]
fn limits_flags() {
    let out = canon(&["jcs", "--max-bytes", "3"], b"[12]");
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("too_large"));
    let out = canon(&["jcs", "--max-depth", "1"], b"[[]]");
    assert!(String::from_utf8_lossy(&out.stderr).contains("too_deep"));
}

#[test]
fn oversized_stdin_is_refused_not_slurped() {
    let big = vec![b' '; 1 << 20];
    let out = canon(&["jcs", "--max-bytes", "16"], &big);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("too_large"));
}

#[test]
fn missing_file_is_input_error() {
    let out = canon(&["jcs", "/nonexistent/canonprims-test.json"], b"");
    assert_eq!(out.status.code(), Some(4));
    assert!(out.stdout.is_empty());
}

#[test]
fn usage_errors_are_exit_2() {
    assert_eq!(
        canon(&["jcs", "--check", "--digest"], b"{}").status.code(),
        Some(2)
    );
    assert_eq!(canon(&["nope"], b"").status.code(), Some(2));
    assert_eq!(canon(&["info", "xml/c14n2"], b"").status.code(), Some(2));
}

#[test]
fn info_is_json() {
    let out = canon(&["info"], b"");
    assert_eq!(out.status.code(), Some(0));
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(
        text.starts_with(r#"{"corpus":"canonical-json/v0","corpus_digest":"sha256:"#),
        "{text}"
    );
    assert!(
        text.ends_with("\"scheme\":\"jcs/rfc8785\",\"spec\":\"RFC 8785\"}\n"),
        "{text}"
    );
}

#[test]
fn version_line_and_extended_json() {
    let version = env!("CARGO_PKG_VERSION");
    let plain = canon(&["version"], b"");
    assert_eq!(plain.status.code(), Some(0));
    assert_eq!(plain.stdout, format!("canon {version}\n").into_bytes());
    assert!(plain.stderr.is_empty());

    let ext = canon(&["version", "--extended"], b"");
    assert_eq!(ext.status.code(), Some(0));
    assert!(ext.stderr.is_empty());
    let text = String::from_utf8(ext.stdout).unwrap();
    let doc = text.strip_suffix('\n').expect("one trailing newline");
    assert!(
        doc.starts_with(
            r#"{"name":"canon","schemes":[{"corpus":"canonical-json/v0","corpus_digest":"sha256:"#
        ),
        "{doc}"
    );
    assert!(
        doc.ends_with(&format!(
            r#""scheme":"jcs/rfc8785","spec":"RFC 8785"}}],"version":"{version}"}}"#
        )),
        "{doc}"
    );
    // The document is its own canonical form.
    let again = canon(&["jcs", "--check", "-"], doc.as_bytes());
    assert_eq!(
        again.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&again.stderr)
    );
}

#[test]
fn info_json_is_canonical() {
    let out = canon(&["info"], b"");
    let text = String::from_utf8(out.stdout).unwrap();
    let doc = text.strip_suffix('\n').expect("one trailing newline");
    let again = canon(&["jcs", "--check", "-"], doc.as_bytes());
    assert_eq!(
        again.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&again.stderr)
    );
}

/// A caller-raised depth limit must not overflow the stack: run in a child
/// process so an abort fails this test instead of the harness.
#[test]
fn deep_nesting_with_raised_limit_is_stack_safe() {
    const DEPTH: usize = 1_000_000;
    let mut doc = Vec::with_capacity(4 * DEPTH + 8);
    for i in 0..DEPTH {
        doc.extend_from_slice(if i % 2 == 0 { b"[" } else { b"{\"a\":" });
    }
    doc.push(b'0');
    for i in (0..DEPTH).rev() {
        doc.push(if i % 2 == 0 { b']' } else { b'}' });
    }
    let limit = DEPTH.to_string();
    let out = canon(&["jcs", "--max-depth", &limit], &doc);
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(out.stdout, doc);

    let just_under = (DEPTH - 1).to_string();
    let out = canon(&["jcs", "--max-depth", &just_under], &doc);
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("too_deep"));
}

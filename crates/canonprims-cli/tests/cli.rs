// SPDX-License-Identifier: MIT OR Apache-2.0

//! The `canonprims` binary: streams, exit codes and flags.

use std::io::Write;
use std::process::{Command, Output, Stdio};

fn canon(args: &[&str], stdin: &[u8]) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_canonprims"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // canonprims may stop reading early (an oversized input), so feed stdin from
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
    assert_eq!(plain.stdout, format!("canonprims {version}\n").into_bytes());
    assert!(plain.stderr.is_empty());

    let ext = canon(&["version", "--extended"], b"");
    assert_eq!(ext.status.code(), Some(0));
    assert!(ext.stderr.is_empty());
    let text = String::from_utf8(ext.stdout).unwrap();
    let doc = text.strip_suffix('\n').expect("one trailing newline");
    assert!(
        doc.starts_with(
            r#"{"name":"canonprims","schemes":[{"corpus":"canonical-json/v0","corpus_digest":"sha256:"#
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

fn stdout_of(out: &Output) -> &[u8] {
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stderr.is_empty());
    &out.stdout
}

fn refused_with(out: &Output, code: &str) {
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.starts_with(&format!("canonprims: jcs/rfc8785: {code} at byte ")),
        "{err}"
    );
}

#[test]
fn diagnostics_name_the_command() {
    let out = canon(&["jcs"], b"[");
    refused_with(&out, "invalid_json");
}

#[test]
fn vector_is_canonical_and_self_consistent() {
    let out = canon(&["jcs", "--vector"], b"{\"b\": 2, \"a\": [1.0, 1e21]}\n");
    let text = String::from_utf8(stdout_of(&out).to_vec()).unwrap();
    let doc = text.strip_suffix('\n').expect("one trailing newline");
    let canonical = r#"{"a":[1,1e+21],"b":2}"#;
    let digest = canon(&["jcs", "--digest"], canonical.as_bytes());
    let digest = String::from_utf8(stdout_of(&digest).to_vec()).unwrap();
    assert_eq!(
        doc,
        format!(
            r#"{{"byte_length":{},"canonical":"{{\"a\":[1,1e+21],\"b\":2}}","digest":"{}","scheme":"jcs/rfc8785"}}"#,
            canonical.len(),
            digest.trim_end()
        )
    );
    stdout_of(&canon(&["jcs", "--check"], doc.as_bytes()));
}

#[test]
fn ndjson_array_and_head() {
    let journal = b"{\"b\":2,\"a\":1}\n{\"d\":4,\"c\":3}\n{\"e\":5}\n";
    assert_eq!(
        stdout_of(&canon(&["jcs", "--ndjson-array"], journal)),
        br#"[{"a":1,"b":2},{"c":3,"d":4},{"e":5}]"#
    );
    assert_eq!(
        stdout_of(&canon(&["jcs", "--ndjson-array", "--head", "2"], journal)),
        br#"[{"a":1,"b":2},{"c":3,"d":4}]"#
    );
    // Torn bytes after the selected lines are never read as JSON.
    assert_eq!(
        stdout_of(&canon(
            &["jcs", "--ndjson-array", "--head", "1"],
            b"1\n{torn"
        )),
        b"[1]"
    );
    let digest = canon(
        &["jcs", "--ndjson-array", "--head", "2", "--digest"],
        journal,
    );
    let direct = canon(&["jcs", "--digest"], br#"[{"a":1,"b":2},{"c":3,"d":4}]"#);
    assert_eq!(stdout_of(&digest), stdout_of(&direct));
    for bad in [
        &b""[..],
        b"{\"a\":1}",
        b"{\"a\":1}\r\n",
        b"{\"a\":1}\n\n",
        b"{\"a\":1}\n \t\n",
    ] {
        refused_with(&canon(&["jcs", "--ndjson-array"], bad), "invalid_json");
    }
    refused_with(
        &canon(&["jcs", "--ndjson-array", "--head", "4"], journal),
        "invalid_json",
    );
    // The selected lines must fit in --max-bytes; the rest is not counted.
    refused_with(
        &canon(&["jcs", "--ndjson-array", "--max-bytes", "3"], b"1\n2\n"),
        "too_large",
    );
    stdout_of(&canon(
        &["jcs", "--ndjson-array", "--head", "1", "--max-bytes", "2"],
        b"1\n2\n",
    ));
}

#[test]
fn sort_set_sorts_checks_and_refuses() {
    let unsorted = br#"[{"stream":"b","seq":2},{"stream":"a","seq":1}]"#;
    let sorted = br#"[{"seq":1,"stream":"a"},{"seq":2,"stream":"b"}]"#;
    assert_eq!(stdout_of(&canon(&["jcs", "--sort-set"], unsorted)), sorted);
    assert!(stdout_of(&canon(&["jcs", "--sort-set", "--check"], sorted)).is_empty());
    refused_with(
        &canon(&["jcs", "--sort-set", "--check"], unsorted),
        "not_canonical",
    );
    for dup in [
        &br#"[{"a":1,"b":2},{"b":2,"a":1}]"#[..],
        b"[1, 1.0]",
        b"[\"x\",\"x\"]",
    ] {
        refused_with(&canon(&["jcs", "--sort-set"], dup), "duplicate_set_element");
    }
    for non in [&b"{}"[..], b"123", b"\"s\"", b"null", b"true"] {
        refused_with(&canon(&["jcs", "--sort-set"], non), "not_an_array");
    }
}

#[test]
fn modes_compose() {
    let out = canon(
        &["jcs", "--ndjson-array", "--sort-set", "--vector"],
        b"{\"id\":\"b\"}\n{\"id\":\"a\"}\n",
    );
    let text = String::from_utf8(stdout_of(&out).to_vec()).unwrap();
    assert!(
        text.starts_with(
            r#"{"byte_length":23,"canonical":"[{\"id\":\"a\"},{\"id\":\"b\"}]","digest":"sha256:"#
        ),
        "{text}"
    );
    refused_with(
        &canon(&["jcs", "--ndjson-array", "--sort-set"], b"1\n1.0\n"),
        "duplicate_set_element",
    );
    // Elements sit one level below the array.
    refused_with(
        &canon(&["jcs", "--ndjson-array", "--max-depth", "1"], b"[]\n"),
        "too_deep",
    );
}

#[test]
fn new_flag_usage_errors_are_exit_2() {
    for args in [
        &["jcs", "--check", "--vector"][..],
        &["jcs", "--digest", "--vector"],
        &["jcs", "--ndjson-array", "--check"],
        &["jcs", "--head", "1"],
        &["jcs", "--ndjson-array", "--head", "0"],
        &["jcs", "--ndjson-array", "--head", "-1"],
        &["jcs", "--ndjson-array", "--head", "+1"],
        &["jcs", "--ndjson-array", "--head", "1_0"],
        &["jcs", "--max-bytes", "1_000"],
        &["jcs", "--max-bytes", " 5"],
        &["jcs", "--max-depth", "+5"],
        &["jcs", "a.json", "b.json"],
    ] {
        let out = canon(args, b"{}");
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(out.stdout.is_empty(), "{args:?}");
    }
}

/// `--head N` answers as soon as the N lines arrive, while the writer keeps
/// the stream open.
#[test]
fn head_does_not_wait_for_the_rest_of_the_stream() {
    use std::io::Read;
    use std::time::{Duration, Instant};
    let mut child = Command::new(env!("CARGO_BIN_EXE_canonprims"))
        .args(["jcs", "--ndjson-array", "--head", "2", "--max-bytes", "4"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"1\n2\n").unwrap();
    stdin.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "still waiting for input after the selected lines"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    drop(stdin);
    let mut out = Vec::new();
    child.stdout.take().unwrap().read_to_end(&mut out).unwrap();
    assert_eq!(status.code(), Some(0));
    assert_eq!(out, b"[1,2]");
}

/// A file and stdin give the same answer at the size boundary.
#[test]
fn file_and_stdin_agree_at_the_size_limit() {
    let dir = std::env::temp_dir().join(format!("canonprims-cli-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cases: [(&[u8], &[&str], Option<&str>); 6] = [
        (b"[]", &["jcs", "--max-bytes", "2"], None),
        (b"[]junk", &["jcs", "--max-bytes", "2"], Some("too_large")),
        (b"[] ", &["jcs", "--max-bytes", "2"], Some("too_large")),
        (
            b"1\n2\n",
            &["jcs", "--ndjson-array", "--max-bytes", "4"],
            None,
        ),
        (
            b"1\n2\n",
            &["jcs", "--ndjson-array", "--max-bytes", "3"],
            Some("too_large"),
        ),
        (
            b"1\n2\n3",
            &["jcs", "--ndjson-array", "--head", "2", "--max-bytes", "4"],
            None,
        ),
    ];
    for (i, (input, args, refusal)) in cases.iter().enumerate() {
        let path = dir.join(format!("case-{i}"));
        std::fs::write(&path, input).unwrap();
        let mut with_file: Vec<&str> = args.to_vec();
        let p = path.to_str().unwrap().to_owned();
        with_file.push(&p);
        let from_file = canon(&with_file, b"");
        let from_stdin = canon(args, input);
        assert_eq!(
            from_file.status.code(),
            from_stdin.status.code(),
            "{args:?}"
        );
        assert_eq!(from_file.stdout, from_stdin.stdout, "{args:?}");
        match refusal {
            None => assert_eq!(from_file.status.code(), Some(0), "{args:?}"),
            Some(code) => {
                refused_with(&from_file, code);
                refused_with(&from_stdin, code);
            }
        }
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

/// `--max-bytes` bounds the input; a vector of output longer than the input
/// is still written.
#[test]
fn vector_output_may_exceed_the_input_limit() {
    let out = canon(&["jcs", "--vector", "--max-bytes", "4"], b"1e20");
    let text = String::from_utf8(stdout_of(&out).to_vec()).unwrap();
    assert!(
        text.starts_with(r#"{"byte_length":21,"canonical":"100000000000000000000","#),
        "{text}"
    );
    refused_with(
        &canon(&["jcs", "--vector", "--max-bytes", "3"], b"1e20"),
        "too_large",
    );
}

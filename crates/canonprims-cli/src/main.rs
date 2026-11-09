// SPDX-License-Identifier: MIT OR Apache-2.0

//! `canonprims`: canonical serialization from the command line.
//!
//! Data goes to stdout; diagnostics go to stderr. Output is the canonical
//! bytes (no trailing newline), a digest line, a vector, a scheme
//! description, a version line, or nothing (`--check`). The JSON documents
//! (`--vector`, `info`, `version --extended`) are themselves RFC 8785
//! canonical, plus a newline.
//!
//! Exit codes:
//! - 0: success (canonical bytes written, or `--check` found canonical input)
//! - 1: the input has no canonical form, or `--check` found it not canonical
//! - 2: usage error
//! - 4: input could not be read
//! - 5: output could not be written

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::process::ExitCode;

use canonprims_core::{DigestAlg, Limits, Refusal};
use clap::{Args, Parser, Subcommand};

const EXIT_REFUSED: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_INPUT: u8 = 4;
const EXIT_OUTPUT: u8 = 5;

#[derive(Parser)]
#[command(
    name = "canonprims",
    version,
    about = "Canonical serialization for structured data (RFC 8785 and successors)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// RFC 8785 JSON Canonicalization Scheme (scheme jcs/rfc8785).
    Jcs(JcsArgs),
    /// Describe a scheme and the corpus it was gated against, as JSON.
    Info {
        /// Scheme identifier.
        #[arg(default_value = "jcs/rfc8785")]
        scheme: String,
    },
    /// Print the version; `--extended` prints the build identity as JSON.
    Version {
        /// Name, version, built-in schemes and their corpus digests, as JSON.
        #[arg(long)]
        extended: bool,
    },
}

#[derive(Args)]
struct JcsArgs {
    /// Input file, or `-` for stdin.
    #[arg(default_value = "-")]
    file: PathBuf,
    /// Write nothing; exit 0 only if the input is already canonical.
    #[arg(long, conflicts_with_all = ["digest", "vector", "ndjson_array"])]
    check: bool,
    /// Write `sha256:<hex>` of the canonical bytes, then a newline.
    #[arg(long, conflicts_with = "vector")]
    digest: bool,
    /// Write one canonical JSON object, then a newline: the canonical bytes
    /// as a string, their byte length, their digest and the scheme.
    #[arg(long)]
    vector: bool,
    /// Read the input as LF-terminated NDJSON lines and canonicalize them as
    /// one array, in order. No CR LF, no blank lines, no unterminated line.
    #[arg(long)]
    ndjson_array: bool,
    /// With `--ndjson-array`, use exactly the first N lines (N >= 1).
    #[arg(long, value_name = "N", requires = "ndjson_array", value_parser = positive_decimal)]
    head: Option<NonZeroUsize>,
    /// Treat the array as a set: sort elements by their canonical bytes and
    /// refuse duplicates. With `--check`, require it already sorted.
    #[arg(long)]
    sort_set: bool,
    /// Largest input, in bytes.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_BYTES, value_parser = decimal)]
    max_bytes: usize,
    /// Deepest array/object nesting.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_DEPTH, value_parser = decimal)]
    max_depth: usize,
    /// Most members in one object.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_OBJECT_MEMBERS, value_parser = decimal)]
    max_object_members: usize,
    /// Largest decoded string, in bytes.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_STRING_BYTES, value_parser = decimal)]
    max_string_bytes: usize,
}

/// A count written as plain ASCII decimal digits: no sign, no space, no `_`.
fn decimal(s: &str) -> Result<usize, String> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err("expected decimal digits".to_owned());
    }
    s.parse().map_err(|e| format!("{e}"))
}

/// A [`decimal`] count of at least 1.
fn positive_decimal(s: &str) -> Result<NonZeroUsize, String> {
    NonZeroUsize::new(decimal(s)?).ok_or_else(|| "must be at least 1".to_owned())
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(e) => {
            let _ = e.print();
            return if e.use_stderr() {
                ExitCode::from(EXIT_USAGE)
            } else {
                ExitCode::SUCCESS
            };
        }
    };
    match cli.command {
        Command::Jcs(args) => jcs(&args),
        Command::Info { scheme } => info(&scheme),
        Command::Version { extended } => version(extended),
    }
}

fn jcs(args: &JcsArgs) -> ExitCode {
    let limits = Limits {
        max_bytes: args.max_bytes,
        max_depth: args.max_depth,
        max_object_members: args.max_object_members,
        max_string_bytes: args.max_string_bytes,
    };
    let input = match read_input(args, limits.max_bytes) {
        Ok(input) => input,
        Err(e) => {
            eprintln!("canonprims: cannot read {}: {e}", args.file.display());
            return ExitCode::from(EXIT_INPUT);
        }
    };
    if args.check {
        let checked = if args.sort_set {
            canonprims_json::check_canonical_set(&input, &limits)
        } else {
            canonprims_json::check(&input, &limits)
        };
        return match checked {
            Ok(()) => ExitCode::SUCCESS,
            Err(r) => refused(&r),
        };
    }
    let canonical = match canonical_output(args, &input, &limits) {
        Ok(bytes) => bytes,
        Err(r) => return refused(&r),
    };
    let written = if args.vector {
        // The input was bounded when it was read; the assembled output may be
        // a few bytes longer than it, so only the size limit is lifted here.
        let unbounded = Limits {
            max_bytes: usize::MAX,
            ..limits
        };
        match canonprims_json::Vector::from_canonical(canonical, &unbounded) {
            Ok(v) => {
                let mut doc = v.to_json();
                doc.push(b'\n');
                write_out(&doc)
            }
            Err(r) => return refused(&r),
        }
    } else if args.digest {
        write_out(format!("{}\n", DigestAlg::Sha256.format(&canonical)).as_bytes())
    } else {
        write_out(&canonical)
    };
    output_status(written)
}

/// The canonical bytes for the selected input and transform modes.
fn canonical_output(args: &JcsArgs, input: &[u8], limits: &Limits) -> Result<Vec<u8>, Refusal> {
    match (args.ndjson_array, args.sort_set) {
        (false, false) => canonprims_json::canonicalize(input, limits),
        (false, true) => canonprims_json::sort_canonical_set(input, limits),
        (true, false) => canonprims_json::canonicalize_ndjson(input, args.head, limits),
        (true, true) => {
            let elements = canonprims_json::ndjson_elements(input, args.head, limits)?;
            // Each element was bounded as a line of the input.
            let unbounded = Limits {
                max_bytes: usize::MAX,
                ..*limits
            };
            canonprims_json::assemble_canonical_set(&elements, &unbounded)
        }
    }
}

fn info(scheme: &str) -> ExitCode {
    match canonprims_core::Scheme::from_id(scheme) {
        Ok(canonprims_core::Scheme::JcsRfc8785) => {
            let i = canonprims_json::scheme_info();
            let doc = format!(
                "{{\"corpus\":\"{}\",\"corpus_digest\":\"{}\",\"scheme\":\"{}\",\"spec\":\"{}\"}}\n",
                i.corpus, i.corpus_digest, i.scheme, i.spec
            );
            output_status(write_out(doc.as_bytes()))
        }
        Ok(other) => {
            eprintln!("canonprims: scheme {other} is not built into this binary");
            ExitCode::from(EXIT_USAGE)
        }
        Err(e) => {
            eprintln!("canonprims: {e}");
            ExitCode::from(EXIT_USAGE)
        }
    }
}

fn version(extended: bool) -> ExitCode {
    let version = env!("CARGO_PKG_VERSION");
    let doc = if extended {
        // Members in RFC 8785 order; every value is a build-time constant
        // with no character that needs escaping.
        let i = canonprims_json::scheme_info();
        format!(
            "{{\"name\":\"canonprims\",\"schemes\":[{{\"corpus\":\"{}\",\"corpus_digest\":\"{}\",\"scheme\":\"{}\",\"spec\":\"{}\"}}],\"version\":\"{version}\"}}\n",
            i.corpus, i.corpus_digest, i.scheme, i.spec
        )
    } else {
        format!("canonprims {version}\n")
    };
    output_status(write_out(doc.as_bytes()))
}

/// Read at most `max_bytes + 1` bytes, so an oversized input is refused by
/// the library as `too_large` without reading it all. With `--ndjson-array`
/// and `--head`, the command stops asking for input once the selected lines
/// have arrived (a buffered read may already hold bytes after them), so a
/// writer that keeps the stream open after them does not hold the command.
fn read_input(args: &JcsArgs, max_bytes: usize) -> io::Result<Vec<u8>> {
    let cap = u64::try_from(max_bytes)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    let lines = if args.ndjson_array { args.head } else { None };
    if args.file.as_os_str() == "-" {
        read_bounded(io::stdin().lock(), cap, lines)
    } else {
        read_bounded(BufReader::new(File::open(&args.file)?), cap, lines)
    }
}

/// Up to `cap` bytes of `reader`: to its end, or through the `lines`-th LF.
fn read_bounded<R: BufRead>(
    reader: R,
    cap: u64,
    lines: Option<NonZeroUsize>,
) -> io::Result<Vec<u8>> {
    let mut reader = reader.take(cap);
    let mut buf = Vec::new();
    let Some(lines) = lines else {
        reader.read_to_end(&mut buf)?;
        return Ok(buf);
    };
    for _ in 0..lines.get() {
        if reader.read_until(b'\n', &mut buf)? == 0 || buf.last() != Some(&b'\n') {
            break;
        }
    }
    Ok(buf)
}

fn refused(r: &Refusal) -> ExitCode {
    eprintln!("canonprims: {}: {r}", canonprims_json::SCHEME);
    ExitCode::from(EXIT_REFUSED)
}

fn write_out(bytes: &[u8]) -> io::Result<()> {
    let mut out = io::stdout().lock();
    out.write_all(bytes)?;
    out.flush()
}

fn output_status(result: io::Result<()>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        // A closed pipe (`canonprims jcs f | head -c1`) is the reader's choice.
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("canonprims: cannot write output: {e}");
            ExitCode::from(EXIT_OUTPUT)
        }
    }
}

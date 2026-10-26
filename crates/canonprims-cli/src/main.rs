// SPDX-License-Identifier: MIT OR Apache-2.0

//! `canon`: canonical serialization from the command line.
//!
//! Data goes to stdout; diagnostics go to stderr. Output is the canonical
//! bytes (no trailing newline), a digest line, a scheme description, a
//! version line, or nothing (`--check`). The JSON documents (`info`,
//! `version --extended`) are themselves RFC 8785 canonical, plus a newline.
//!
//! Exit codes:
//! - 0: success (canonical bytes written, or `--check` found canonical input)
//! - 1: the input has no canonical form, or `--check` found it not canonical
//! - 2: usage error
//! - 4: input could not be read
//! - 5: output could not be written

use std::fs::File;
use std::io::{self, Read, Write};
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
    name = "canon",
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
    #[arg(long, conflicts_with = "digest")]
    check: bool,
    /// Write `sha256:<hex>` of the canonical bytes, then a newline.
    #[arg(long)]
    digest: bool,
    /// Largest input, in bytes.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_BYTES)]
    max_bytes: usize,
    /// Deepest array/object nesting.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_DEPTH)]
    max_depth: usize,
    /// Most members in one object.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_OBJECT_MEMBERS)]
    max_object_members: usize,
    /// Largest decoded string, in bytes.
    #[arg(long, default_value_t = Limits::DEFAULT_MAX_STRING_BYTES)]
    max_string_bytes: usize,
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
            eprintln!("canon: cannot read {}: {e}", args.file.display());
            return ExitCode::from(EXIT_INPUT);
        }
    };
    if args.check {
        return match canonprims_json::check(&input, &limits) {
            Ok(()) => ExitCode::SUCCESS,
            Err(r) => refused(&r),
        };
    }
    let canonical = match canonprims_json::canonicalize(&input, &limits) {
        Ok(bytes) => bytes,
        Err(r) => return refused(&r),
    };
    let written = if args.digest {
        write_out(format!("{}\n", DigestAlg::Sha256.format(&canonical)).as_bytes())
    } else {
        write_out(&canonical)
    };
    output_status(written)
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
            eprintln!("canon: scheme {other} is not built into this binary");
            ExitCode::from(EXIT_USAGE)
        }
        Err(e) => {
            eprintln!("canon: {e}");
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
            "{{\"name\":\"canon\",\"schemes\":[{{\"corpus\":\"{}\",\"corpus_digest\":\"{}\",\"scheme\":\"{}\",\"spec\":\"{}\"}}],\"version\":\"{version}\"}}\n",
            i.corpus, i.corpus_digest, i.scheme, i.spec
        )
    } else {
        format!("canon {version}\n")
    };
    output_status(write_out(doc.as_bytes()))
}

/// Read at most `max_bytes + 1` bytes, so an oversized input is refused by
/// the library as `too_large` without reading it all.
fn read_input(args: &JcsArgs, max_bytes: usize) -> io::Result<Vec<u8>> {
    let cap = u64::try_from(max_bytes)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    let mut buf = Vec::new();
    if args.file.as_os_str() == "-" {
        io::stdin().lock().take(cap).read_to_end(&mut buf)?;
    } else {
        File::open(&args.file)?.take(cap).read_to_end(&mut buf)?;
    }
    Ok(buf)
}

fn refused(r: &Refusal) -> ExitCode {
    eprintln!("canon: {}: {r}", canonprims_json::SCHEME);
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
        // A closed pipe (`canon jcs f | head -c1`) is the reader's choice.
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("canon: cannot write output: {e}");
            ExitCode::from(EXIT_OUTPUT)
        }
    }
}

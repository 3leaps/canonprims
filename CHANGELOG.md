# Changelog

All notable changes to this project are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-26

- RFC 8785 JSON Canonicalization Scheme (`jcs/rfc8785`) over a strict I-JSON
  loader, in Rust (`canonprims-core`, `canonprims-json`) and in pure Go
  (`github.com/3leaps/canonprims/canon`), with the same refusal codes and explicit limits
- `canon` command: `canon jcs [--check] [--digest] FILE|-`, `canon info` and
  `canon version [--extended]`
- Conformance corpus `canonical-json/v0`, whose file-based accept cases are
  witnessed against ECMAScript and a separate Python checker
- Rust/Go byte-for-byte agreement gate on the corpus and on generated input
- Release process: one signed tag per release (`vX.Y.Z`) for the Rust crates
  and the root Go module, committed public signing pins and
  fingerprint anchors read from the tagged commit, a read-only tag workflow
  that builds the `canon` CLI for five platforms, and crates.io publication
  in which package verification is compiled only in credential-free CI and
  the registry token is released only for the verified package's checksum
- Public-surface checks: a vocabulary-free content check of tracked files in
  `make check`, and a maintainer-only limensafe scan in `make pr-final`

[Unreleased]: https://github.com/3leaps/canonprims/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/3leaps/canonprims/releases/tag/v0.1.0

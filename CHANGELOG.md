# Changelog

All notable changes to this project are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- RFC 8785 JSON Canonicalization Scheme (`jcs/rfc8785`) over a strict I-JSON
  loader, in Rust (`canonprims-core`, `canonprims-json`) and in pure Go
  (`github.com/3leaps/canonprims/canon`), with the same refusal codes and explicit limits
- `canon` command: `canon jcs [--check] [--digest] FILE|-`, `canon info` and
  `canon version [--extended]`
- Conformance corpus `canonical-json/v0`, witnessed against ECMAScript and a
  separate Python checker
- Rust/Go byte-for-byte agreement gate on the corpus and on generated input
- Release process: one signed tag per release (`vX.Y.Z`) for the Rust crates
  and the root Go module, committed public signing pins and
  fingerprint anchors read from the tagged commit, a read-only tag workflow
  that builds the `canon` CLI for five platforms, and crates.io publication
  in which package verification is compiled only in credential-free CI and
  the registry token is released only for the verified package's checksum

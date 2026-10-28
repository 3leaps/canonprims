# Changelog

All notable changes to this project are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-10-28

- Python binding `canonprims` (`bindings/python`, PyO3): one abi3 wheel per
  platform for CPython 3.10 and later, on linux amd64/arm64 (manylinux2014),
  darwin arm64 and windows amd64/arm64. The four verbs over any buffer with
  explicit `Limits` (a negative limit behaves as 0); refusals raised as
  `canonprims.Refusal` with the normative code and byte offset
- TypeScript binding `@3leaps/canonprims` (`bindings/typescript`): one
  WebAssembly module with no imports, embedded in an ES module with no runtime
  dependencies, tested in CI on Node.js 20 and 22. The four verbs over
  `Uint8Array` or any `ArrayBufferView` with explicit limits; refusals thrown
  as `Refusal`. A string with an unpaired surrogate is a `TypeError`, and an
  input longer than `maxBytes` is refused before it reaches the module
- Both bindings pass the `canonical-json/v0` corpus and agree with Rust byte
  for byte on the corpus and the crosscheck seeds (`make python-check`,
  `make ts-check`)
- The wheels and the npm package are release assets, built and tested in the
  tag workflow and covered by the release checksums and both signatures
- The WebAssembly crate allows unsafe code only on its exported functions
  ([SecDR-0001](docs/security/SecDR-0001-wasm-export-unsafe-allowance.md))
- The release tag restore confirms origin's tag object even when the checkout
  already holds it
- Built bindings carry no build-host path
- The trademark notice names 3 Leaps, LLC as a North Carolina LLC

## [0.1.1] - 2026-10-27

The first published release. A `v0.1.0` tag was created but never released:
its tag workflow could not read the tag on a private repository. Everything
listed here ships in 0.1.1.

- The release workflow looks up its tag through the GitHub API with the
  read-only job token, so it runs on a private repository
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

[Unreleased]: https://github.com/3leaps/canonprims/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/3leaps/canonprims/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/3leaps/canonprims/releases/tag/v0.1.1

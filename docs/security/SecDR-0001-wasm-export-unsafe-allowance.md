---
id: "SecDR-0001"
title: "The WebAssembly crate allows unsafe code only on its exported functions"
status: "accepted"
date: "2026-10-28"
relates-to:
  - "../../bindings/typescript/Cargo.toml"
  - "../../bindings/typescript/src/lib.rs"
  - "../../scripts/ts-check.sh"
---

# SecDR-0001: The WebAssembly Crate Allows Unsafe Code Only on Its Exported Functions

## Context

Every canonprims crate sets `unsafe_code = "forbid"`. The TypeScript package
is `canonprims-json` compiled to one WebAssembly module, `bindings/typescript`,
which exports plain functions for JavaScript to call. Exporting a function by
name (`#[no_mangle]`, or `#[unsafe(no_mangle)]`) is itself `unsafe_code`, and
under `forbid` it cannot be allowed locally: the crate does not compile
(rustc 1.88.0 and 1.98.0, edition 2021).

The alternative is `wasm-bindgen`, which generates the exports so the crate
could keep `forbid`. It adds a dependency, a CLI version-locked to it, and
generated JavaScript in the published package.

## Decision

The WebAssembly crate sets `unsafe_code = "deny"` and allows it only on its
exported functions: each `#[allow(unsafe_code)]` sits directly above a
`#[no_mangle]` export, and nothing else in the crate uses unsafe code. Every
other crate, including the Python binding, keeps `forbid`.

The compiler does not confine the allowance to the export attribute: it covers
the whole function, so an `unsafe` block in an exported function's body would
compile. The text check below, not the compiler, is the control that keeps
those bodies free of unsafe code.

## Consequences

**Mitigations.**

- The crate is its own Cargo workspace outside `crates/`, with
  `publish = false`. It is never a release crate.
- No function dereferences a pointer from the caller. The module owns its
  input and output buffers (`Vec`s in thread-local state); the exports return
  the addresses of those buffers, and JavaScript writes the input and copies
  the output.
- The module has no imports: it calls no host function and is granted no
  capability.
- An input longer than `maxBytes` is refused in JavaScript before any module
  memory is reserved.

**Residual risk.** A caller that writes through a stale address (for example,
one kept across a later call that replaced the buffer) can corrupt the
module's own memory. With no imports, that corruption stays inside the
instance. The package's own wrapper does not keep addresses across calls.

**Enforcement.** `make ts-check` (`scripts/ts-check.sh`) fails when any
non-comment line in any Rust file of the crate mentions `unsafe`, other than
an `#[allow(unsafe_code)]` directly above `#[no_mangle]`, and when the built
module has any import. CI runs it on every change.

**Revisit** and remove the exception if a later Rust accepts a named export
under `forbid`. Also revisit if the module gains an import or a thread, or if
the crate's `publish` becomes `true`.

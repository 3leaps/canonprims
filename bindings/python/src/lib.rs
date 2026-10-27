// SPDX-License-Identifier: MIT OR Apache-2.0

//! The `canonprims._canonprims` extension: the four verbs of
//! `canonprims-json` over `bytes`. The Python package (`python/canonprims`)
//! adds the typed `Refusal` exception, `Limits` and the str convenience; this
//! module only converts. A refusal is raised as the internal `RawRefusal` with
//! args `(code, offset)`, the code being the crate's own wire name, and the
//! Python layer re-raises it as `canonprims.Refusal`.

use canonprims_json::canonprims_core::{DigestAlg, Limits, Refusal};
use pyo3::create_exception;
use pyo3::exceptions::{PyException, PyValueError};
use pyo3::prelude::*;
use pyo3::types::PyBytes;

create_exception!(_canonprims, RawRefusal, PyException);

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

fn refused(r: Refusal) -> PyErr {
    RawRefusal::new_err((r.code.as_str(), r.offset))
}

#[pyfunction]
fn canonicalize<'py>(
    py: Python<'py>,
    input: &[u8],
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
) -> PyResult<Bound<'py, PyBytes>> {
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    canonprims_json::canonicalize(input, &l)
        .map(|out| PyBytes::new(py, &out))
        .map_err(refused)
}

#[pyfunction]
fn check(
    input: &[u8],
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
) -> PyResult<()> {
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    canonprims_json::check(input, &l).map_err(refused)
}

#[pyfunction]
fn digest(
    input: &[u8],
    max_bytes: usize,
    max_depth: usize,
    max_object_members: usize,
    max_string_bytes: usize,
    alg: &str,
) -> PyResult<String> {
    let alg = DigestAlg::from_id(alg).map_err(|e| PyValueError::new_err(e.to_string()))?;
    let l = limits(max_bytes, max_depth, max_object_members, max_string_bytes);
    canonprims_json::digest(input, &l, alg).map_err(refused)
}

#[pyfunction]
fn scheme_info() -> (&'static str, &'static str, &'static str, &'static str) {
    let i = canonprims_json::scheme_info();
    (i.scheme.id(), i.spec, i.corpus, i.corpus_digest)
}

#[pymodule]
fn _canonprims(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("RawRefusal", m.py().get_type::<RawRefusal>())?;
    m.add_function(wrap_pyfunction!(canonicalize, m)?)?;
    m.add_function(wrap_pyfunction!(check, m)?)?;
    m.add_function(wrap_pyfunction!(digest, m)?)?;
    m.add_function(wrap_pyfunction!(scheme_info, m)?)?;
    m.add("DEFAULT_MAX_BYTES", Limits::DEFAULT_MAX_BYTES)?;
    m.add("DEFAULT_MAX_DEPTH", Limits::DEFAULT_MAX_DEPTH)?;
    m.add(
        "DEFAULT_MAX_OBJECT_MEMBERS",
        Limits::DEFAULT_MAX_OBJECT_MEMBERS,
    )?;
    m.add("DEFAULT_MAX_STRING_BYTES", Limits::DEFAULT_MAX_STRING_BYTES)?;
    m.add("VERSION", env!("CARGO_PKG_VERSION"))?;
    Ok(())
}

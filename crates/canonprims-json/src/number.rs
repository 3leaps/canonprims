// SPDX-License-Identifier: MIT OR Apache-2.0

//! I-JSON number domain and ECMAScript `Number::toString`.

/// The value of an integer token when the I-JSON domain admits it.
///
/// Admitted when the token's exact value is a binary64 value (compared
/// against the exact decimal expansion, so there is no width ceiling: `2^128`
/// is admitted and `2^127 - 1` is not), or when the token is already the
/// ECMAScript spelling of its nearest binary64 (`18446744073709552000`), so
/// that canonical output is always admissible input.
pub(crate) fn admit_integer(token: &str) -> Option<f64> {
    let digits = token.strip_prefix('-').unwrap_or(token);
    // The largest finite binary64 has 309 integer digits.
    if digits.len() > 309 {
        return None;
    }
    let nearest: f64 = token.parse().ok()?;
    if !nearest.is_finite() {
        return None;
    }
    if digits == exact_integer_decimal(nearest.abs()) {
        return Some(nearest);
    }
    let mut spelled = Vec::with_capacity(token.len());
    write_es6(nearest, &mut spelled);
    (spelled == token.as_bytes()).then_some(nearest)
}

/// Exact decimal digits of a finite, non-negative, integral binary64.
fn exact_integer_decimal(value: f64) -> String {
    const BASE: u64 = 1_000_000_000;
    let bits = value.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as i32;
    let fraction = bits & ((1 << 52) - 1);
    let (mantissa, shift) = if exponent == 0 {
        (fraction, -1074)
    } else {
        (fraction | (1 << 52), exponent - 1075)
    };
    if shift < 0 {
        // Integral values below 2^53 are exact in a u64.
        return (mantissa >> shift.unsigned_abs().min(63)).to_string();
    }
    // Little-endian base-1e9 limbs, doubled `shift` times.
    let mut limbs = vec![
        mantissa % BASE,
        mantissa / BASE % BASE,
        mantissa / BASE / BASE,
    ];
    for _ in 0..shift {
        let mut carry = 0;
        for limb in &mut limbs {
            let v = *limb * 2 + carry;
            *limb = v % BASE;
            carry = v / BASE;
        }
        if carry > 0 {
            limbs.push(carry);
        }
    }
    while limbs.len() > 1 && limbs.last() == Some(&0) {
        limbs.pop();
    }
    let mut out = limbs.last().copied().unwrap_or(0).to_string();
    for limb in limbs.iter().rev().skip(1) {
        out.push_str(&format!("{limb:09}"));
    }
    out
}

/// Append a finite binary64 as ECMAScript `Number::toString` writes it.
pub(crate) fn write_es6(value: f64, out: &mut Vec<u8>) {
    if value == 0.0 {
        // Covers -0.
        out.push(b'0');
        return;
    }
    let mut buffer = ryu_js::Buffer::new();
    out.extend_from_slice(buffer.format_finite(value).as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_decimal_matches_known_powers() {
        assert_eq!(exact_integer_decimal(0.0), "0");
        assert_eq!(exact_integer_decimal(1.0), "1");
        assert_eq!(exact_integer_decimal(2f64.powi(64)), "18446744073709551616");
        assert_eq!(
            exact_integer_decimal(2f64.powi(127)),
            "170141183460469231731687303715884105728"
        );
        assert_eq!(exact_integer_decimal(f64::MAX).len(), 309);
    }

    #[test]
    fn integer_domain() {
        assert_eq!(admit_integer("9007199254740992"), Some(9007199254740992.0));
        assert_eq!(admit_integer("9007199254740993"), None);
        assert_eq!(admit_integer("18446744073709552000"), Some(2f64.powi(64)));
        assert_eq!(
            admit_integer("-18446744073709552000"),
            Some(-(2f64.powi(64)))
        );
        assert_eq!(admit_integer("18446744073709552001"), None);
        // -0 is exact; its ES6 spelling is "0", which is also admitted.
        assert_eq!(admit_integer("-0"), Some(-0.0));
        assert_eq!(admit_integer(&"9".repeat(310)), None);
        assert_eq!(admit_integer(&"1".repeat(1 << 20)), None);
    }

    #[test]
    fn es6_spellings() {
        let mut out = Vec::new();
        for v in [1e21, 1e-7, 1e20, 0.000001, -0.0, 5e-324, 123.0] {
            write_es6(v, &mut out);
            out.push(b' ');
        }
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "1e+21 1e-7 100000000000000000000 0.000001 0 5e-324 123 "
        );
    }
}

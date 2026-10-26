// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"math"
	"math/big"
	"strconv"
)

// maxIntDigits bounds integer tokens: the largest finite binary64 has 309
// decimal digits, so any longer integer token is outside binary64.
const maxIntDigits = 309

// number scans the longest prefix matching the JSON number grammar,
// classifies it, and appends its canonical form.
func (p *parser) number() *Refusal {
	in := p.in
	start := p.pos
	i := start
	if in[i] == '-' {
		i++
	}
	if i >= len(in) || in[i] < '0' || in[i] > '9' {
		return refuse(InvalidJSON, i)
	}
	if in[i] == '0' {
		i++
		if i < len(in) && in[i] >= '0' && in[i] <= '9' {
			return refuse(InvalidJSON, i) // leading zero
		}
	} else {
		for i < len(in) && in[i] >= '0' && in[i] <= '9' {
			i++
		}
	}
	intEnd := i
	isInt := true
	if i < len(in) && in[i] == '.' {
		isInt = false
		i++
		d := i
		for i < len(in) && in[i] >= '0' && in[i] <= '9' {
			i++
		}
		if i == d {
			return refuse(InvalidJSON, i)
		}
	}
	if i < len(in) && (in[i] == 'e' || in[i] == 'E') {
		isInt = false
		i++
		if i < len(in) && (in[i] == '+' || in[i] == '-') {
			i++
		}
		d := i
		for i < len(in) && in[i] >= '0' && in[i] <= '9' {
			i++
		}
		if i == d {
			return refuse(InvalidJSON, i)
		}
	}
	tok := string(in[start:i])
	p.pos = i

	if isInt {
		digits := intEnd - start
		if in[start] == '-' {
			digits--
		}
		if digits > maxIntDigits {
			return refuse(IntegerOutsideBinary64, start)
		}
		f, _ := strconv.ParseFloat(tok, 64)
		if math.IsInf(f, 0) {
			return refuse(IntegerOutsideBinary64, start)
		}
		s := formatNumber(f)
		if s != tok && !integerExact(tok, f, digits) {
			return refuse(IntegerOutsideBinary64, start)
		}
		p.out = append(p.out, s...)
		return nil
	}

	// ParseFloat is correctly rounded (ties to even). Underflow yields 0 or
	// a subnormal and is admitted; only overflow to infinity is refused.
	f, _ := strconv.ParseFloat(tok, 64)
	if math.IsInf(f, 0) || math.IsNaN(f) {
		return refuse(NonFiniteNumber, start)
	}
	p.out = append(p.out, formatNumber(f)...)
	return nil
}

// integerExact reports whether the integer token tok (with digits decimal
// digits) has exactly the value f, its nearest binary64.
func integerExact(tok string, f float64, digits int) bool {
	abs := tok
	if abs[0] == '-' {
		abs = abs[1:]
	}
	if digits <= 15 {
		// Every integer below 10^15 < 2^53 is a binary64 value.
		return true
	}
	bf := new(big.Float).SetFloat64(math.Abs(f))
	bi, acc := bf.Int(nil)
	if acc != big.Exact {
		return false
	}
	return bi.String() == abs
}

// formatNumber serializes a finite binary64 as ECMAScript Number::toString
// does (RFC 8785 section 3.2.2.3).
func formatNumber(f float64) string {
	if f == 0 {
		return "0" // covers -0
	}
	var b []byte
	if f < 0 {
		b = append(b, '-')
		f = -f
	}
	// Shortest round-trip digits: "d.ddde±XX" or "de±XX".
	e := strconv.FormatFloat(f, 'e', -1, 64)
	mant := e
	exp := 0
	for i := 0; i < len(e); i++ {
		if e[i] == 'e' {
			mant = e[:i]
			x, _ := strconv.Atoi(e[i+1:])
			exp = x
			break
		}
	}
	digits := make([]byte, 0, len(mant))
	for i := 0; i < len(mant); i++ {
		if mant[i] != '.' {
			digits = append(digits, mant[i])
		}
	}
	k := len(digits)
	n := exp + 1 // decimal point position: value = 0.digits * 10^n
	switch {
	case k <= n && n <= 21:
		b = append(b, digits...)
		for i := 0; i < n-k; i++ {
			b = append(b, '0')
		}
	case 0 < n && n <= 21:
		b = append(b, digits[:n]...)
		b = append(b, '.')
		b = append(b, digits[n:]...)
	case -6 < n && n <= 0:
		b = append(b, '0', '.')
		for i := 0; i < -n; i++ {
			b = append(b, '0')
		}
		b = append(b, digits...)
	default:
		b = append(b, digits[0])
		if k > 1 {
			b = append(b, '.')
			b = append(b, digits[1:]...)
		}
		b = append(b, 'e')
		if n-1 >= 0 {
			b = append(b, '+')
		}
		b = strconv.AppendInt(b, int64(n-1), 10)
	}
	return string(b)
}

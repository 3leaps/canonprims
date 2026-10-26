// SPDX-License-Identifier: MIT OR Apache-2.0

package canon

import (
	"sort"
	"unicode/utf8"
)

// frame is one open container. Both arrays and objects are written straight
// into the output. Each object member is written as `"name":value` (with a
// leading comma after the first); when the object closes, members that are
// out of order are re-emitted in sorted order.
type frame struct {
	obj    bool
	names  []string // decoded member names, input order
	spans  [][2]int // output spans of `"name":value`, parallel to names
	sorted bool     // names so far are in strictly ascending order
	seen   map[string]struct{}
}

type parser struct {
	in      []byte
	pos     int
	lim     Limits
	out     []byte
	stack   []frame
	scratch []byte // decoded string data
	reorder []byte // reused by closeObject
}

func refuse(c Code, off int) *Refusal { return &Refusal{Code: c, Offset: off} }

// canonicalize implements the order of detection: size, encoding, then one
// left-to-right parse in which the first defect reached wins.
func canonicalize(in []byte, l Limits) ([]byte, *Refusal) {
	l.MaxBytes = nonNeg(l.MaxBytes)
	l.MaxDepth = nonNeg(l.MaxDepth)
	l.MaxObjectMembers = nonNeg(l.MaxObjectMembers)
	l.MaxStringBytes = nonNeg(l.MaxStringBytes)
	if len(in) > l.MaxBytes {
		return nil, refuse(TooLarge, l.MaxBytes)
	}
	if !utf8.Valid(in) {
		return nil, refuse(InvalidUTF8, firstInvalidUTF8(in))
	}
	p := &parser{in: in, lim: l, out: make([]byte, 0, len(in))}
	if r := p.run(); r != nil {
		return nil, r
	}
	return p.out, nil
}

func nonNeg(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

func firstInvalidUTF8(b []byte) int {
	i := 0
	for i < len(b) {
		r, n := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && n <= 1 {
			return i
		}
		i += n
	}
	return i
}

func (p *parser) skipWS() {
	for p.pos < len(p.in) {
		switch p.in[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) run() *Refusal {
	p.skipWS()
	needValue := true
	for {
		if needValue {
			if p.pos >= len(p.in) {
				return refuse(InvalidJSON, p.pos)
			}
			switch c := p.in[p.pos]; c {
			case '{', '[':
				if len(p.stack) >= p.lim.MaxDepth {
					return refuse(TooDeep, p.pos)
				}
				p.pos++
				p.skipWS()
				if c == '{' {
					if p.pos < len(p.in) && p.in[p.pos] == '}' {
						p.pos++
						p.out = append(p.out, '{', '}')
						needValue = false
						continue
					}
					p.out = append(p.out, '{')
					p.stack = append(p.stack, frame{obj: true, sorted: true})
					if r := p.member(); r != nil {
						return r
					}
				} else {
					if p.pos < len(p.in) && p.in[p.pos] == ']' {
						p.pos++
						p.out = append(p.out, '[', ']')
						needValue = false
						continue
					}
					p.stack = append(p.stack, frame{})
					p.out = append(p.out, '[')
				}
				continue
			case '"':
				s, r := p.str()
				if r != nil {
					return r
				}
				p.out = appendString(p.out, s)
			case 't':
				if r := p.literal("true"); r != nil {
					return r
				}
			case 'f':
				if r := p.literal("false"); r != nil {
					return r
				}
			case 'n':
				if r := p.literal("null"); r != nil {
					return r
				}
			default:
				if c == '-' || (c >= '0' && c <= '9') {
					if r := p.number(); r != nil {
						return r
					}
				} else {
					return refuse(InvalidJSON, p.pos)
				}
			}
			needValue = false
			continue
		}

		// A value has just been completed.
		if len(p.stack) == 0 {
			p.skipWS()
			if p.pos != len(p.in) {
				return refuse(InvalidJSON, p.pos)
			}
			return nil
		}
		top := &p.stack[len(p.stack)-1]
		if top.obj {
			top.spans[len(top.spans)-1][1] = len(p.out)
		}
		p.skipWS()
		if p.pos >= len(p.in) {
			return refuse(InvalidJSON, p.pos)
		}
		c := p.in[p.pos]
		switch {
		case c == ',':
			p.pos++
			p.skipWS()
			if top.obj {
				if r := p.member(); r != nil {
					return r
				}
			} else {
				p.out = append(p.out, ',')
			}
			needValue = true
		case c == '}' && top.obj:
			p.pos++
			p.closeObject()
		case c == ']' && !top.obj:
			p.pos++
			p.out = append(p.out, ']')
			p.stack = p.stack[:len(p.stack)-1]
		default:
			return refuse(InvalidJSON, p.pos)
		}
	}
}

// member reads one object member's name and colon, leaving the parser at
// the start of the value. The steps follow the spec's order exactly.
func (p *parser) member() *Refusal {
	top := &p.stack[len(p.stack)-1]
	if p.pos >= len(p.in) || p.in[p.pos] != '"' {
		return refuse(InvalidJSON, p.pos)
	}
	if len(top.names) >= p.lim.MaxObjectMembers {
		return refuse(TooLarge, p.pos)
	}
	at := p.pos
	b, r := p.str()
	if r != nil {
		return r
	}
	name := string(b)
	if top.seen == nil {
		top.seen = make(map[string]struct{})
	}
	if _, dup := top.seen[name]; dup {
		return refuse(DuplicateMember, at)
	}
	top.seen[name] = struct{}{}
	p.skipWS()
	if p.pos >= len(p.in) || p.in[p.pos] != ':' {
		return refuse(InvalidJSON, p.pos)
	}
	p.pos++
	p.skipWS()
	if n := len(top.names); n > 0 {
		p.out = append(p.out, ',')
		if top.sorted && !utf16Less(top.names[n-1], name) {
			top.sorted = false
		}
	}
	start := len(p.out)
	p.out = appendString(p.out, name)
	p.out = append(p.out, ':')
	top.names = append(top.names, name)
	top.spans = append(top.spans, [2]int{start, len(p.out)})
	return nil
}

// closeObject finishes the innermost object, reordering its members by
// UTF-16 code units when the input did not already have them in order.
func (p *parser) closeObject() {
	top := &p.stack[len(p.stack)-1]
	if !top.sorted {
		base := top.spans[0][0]
		p.reorder = append(p.reorder[:0], p.out[base:]...)
		idx := make([]int, len(top.names))
		for i := range idx {
			idx[i] = i
		}
		names := top.names
		sort.Slice(idx, func(a, b int) bool { return utf16Less(names[idx[a]], names[idx[b]]) })
		out := p.out[:base]
		for i, k := range idx {
			if i > 0 {
				out = append(out, ',')
			}
			sp := top.spans[k]
			out = append(out, p.reorder[sp[0]-base:sp[1]-base]...)
		}
		p.out = out
	}
	p.out = append(p.out, '}')
	p.stack[len(p.stack)-1] = frame{}
	p.stack = p.stack[:len(p.stack)-1]
}

func (p *parser) literal(word string) *Refusal {
	if len(p.in)-p.pos < len(word) || string(p.in[p.pos:p.pos+len(word)]) != word {
		return refuse(InvalidJSON, p.pos)
	}
	p.pos += len(word)
	p.out = append(p.out, word...)
	return nil
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// hex4 reads four hex digits at p.pos.
func (p *parser) hex4() (rune, bool) {
	if len(p.in)-p.pos < 4 {
		return 0, false
	}
	var v rune
	for i := 0; i < 4; i++ {
		h := hexVal(p.in[p.pos+i])
		if h < 0 {
			return 0, false
		}
		v = v<<4 | rune(h)
	}
	p.pos += 4
	return v, true
}

// str decodes the string starting at the opening quote at p.pos. The result
// aliases p.scratch and is valid until the next call.
func (p *parser) str() ([]byte, *Refusal) {
	p.pos++ // opening quote
	buf := p.scratch[:0]
	max := p.lim.MaxStringBytes
	for {
		if p.pos >= len(p.in) {
			return nil, refuse(InvalidJSON, p.pos)
		}
		c := p.in[p.pos]
		switch {
		case c == '"':
			p.pos++
			p.scratch = buf
			return buf, nil
		case c < 0x20:
			return nil, refuse(InvalidJSON, p.pos)
		case c != '\\':
			// Input is valid UTF-8, so copy one whole code point.
			n := 1
			if c >= 0x80 {
				var r rune
				r, n = utf8.DecodeRune(p.in[p.pos:])
				if isNoncharacter(r) {
					return nil, refuse(Noncharacter, p.pos)
				}
			}
			buf = append(buf, p.in[p.pos:p.pos+n]...)
			p.pos += n
			if len(buf) > max {
				return nil, refuse(TooLarge, p.pos-n)
			}
			continue
		}
		at := p.pos
		p.pos++
		if p.pos >= len(p.in) {
			return nil, refuse(InvalidJSON, p.pos)
		}
		e := p.in[p.pos]
		p.pos++
		var r rune
		switch e {
		case '"', '\\', '/':
			r = rune(e)
		case 'b':
			r = '\b'
		case 'f':
			r = '\f'
		case 'n':
			r = '\n'
		case 'r':
			r = '\r'
		case 't':
			r = '\t'
		case 'u':
			u, ok := p.hex4()
			if !ok {
				return nil, refuse(InvalidJSON, at)
			}
			switch {
			case u >= 0xDC00 && u <= 0xDFFF:
				return nil, refuse(LoneSurrogate, at)
			case u >= 0xD800 && u <= 0xDBFF:
				if len(p.in)-p.pos < 2 || p.in[p.pos] != '\\' || p.in[p.pos+1] != 'u' {
					return nil, refuse(LoneSurrogate, at)
				}
				p.pos += 2
				lo, ok := p.hex4()
				if !ok {
					return nil, refuse(InvalidJSON, p.pos-2)
				}
				if lo < 0xDC00 || lo > 0xDFFF {
					return nil, refuse(LoneSurrogate, at)
				}
				r = 0x10000 + (u-0xD800)<<10 + (lo - 0xDC00)
			default:
				r = u
			}
		default:
			return nil, refuse(InvalidJSON, at)
		}
		if isNoncharacter(r) {
			return nil, refuse(Noncharacter, at)
		}
		buf = utf8.AppendRune(buf, r)
		if len(buf) > max {
			return nil, refuse(TooLarge, at)
		}
	}
}

// appendString serializes decoded UTF-8 string data as ECMAScript
// JSON.stringify does (RFC 8785 section 3.2.2.2).
func appendString[T string | []byte](out []byte, s T) []byte {
	const hexd = "0123456789abcdef"
	out = append(out, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			out = append(out, '\\', '"')
		case '\\':
			out = append(out, '\\', '\\')
		case '\b':
			out = append(out, '\\', 'b')
		case '\t':
			out = append(out, '\\', 't')
		case '\n':
			out = append(out, '\\', 'n')
		case '\f':
			out = append(out, '\\', 'f')
		case '\r':
			out = append(out, '\\', 'r')
		default:
			if c < 0x20 {
				out = append(out, '\\', 'u', '0', '0', hexd[c>>4], hexd[c&0xf])
			} else {
				out = append(out, c)
			}
		}
	}
	return append(out, '"')
}

// utf16Less orders two valid UTF-8 strings by their UTF-16 code units,
// unsigned, unit by unit; a prefix sorts first.
func utf16Less(a, b string) bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		ra, na := utf8.DecodeRuneInString(a[i:])
		rb, nb := utf8.DecodeRuneInString(b[j:])
		if ra != rb {
			ha, la := utf16Units(ra)
			hb, lb := utf16Units(rb)
			if ha != hb {
				return ha < hb
			}
			return la < lb
		}
		i += na
		j += nb
	}
	return len(a)-i < len(b)-j
}

// utf16Units returns the first code unit of r and, for a supplementary code
// point, the second (else 0).
func utf16Units(r rune) (uint16, uint16) {
	if r < 0x10000 {
		return uint16(r), 0
	}
	r -= 0x10000
	return uint16(0xD800 + r>>10), uint16(0xDC00 + r&0x3FF)
}

// isNoncharacter reports U+FDD0..U+FDEF and every code point ending in FFFE
// or FFFF (RFC 7493 section 2.1).
func isNoncharacter(r rune) bool {
	return (r >= 0xFDD0 && r <= 0xFDEF) || r&0xFFFE == 0xFFFE
}

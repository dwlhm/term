package graphics

import "base:runtime"

// _b64_value maps one base64 character to its 6-bit value.
// Returns -1 for characters outside the standard alphabet.
_b64_value :: proc(c: u8) -> int {
	if c >= 'A' && c <= 'Z' { return int(c - 'A') }
	if c >= 'a' && c <= 'z' { return int(c - 'a' + 26) }
	if c >= '0' && c <= '9' { return int(c - '0' + 52) }
	if c == '+' { return 62 }
	if c == '/' { return 63 }
	return -1
}

// base64_decode decodes standard base64 src into dst.
// Stops at '=' padding or the first invalid character. Returns the decoded
// length and false when the input is malformed or dst is too small.
base64_decode :: proc(dst: []u8, src: []u8) -> (n: int, ok: bool) {
	n = 0
	i := 0
	for i < len(src) {
		// Need a full quantum of 4 characters
		if i + 4 > len(src) {
			return 0, false
		}
		pad := 0
		vals: [4]int
		for k in 0..<4 {
			c := src[i + k]
			if c == '=' {
				pad += 1
				vals[k] = 0
			} else {
				if pad > 0 {
					return 0, false // data after padding
				}
				v := _b64_value(c)
				if v < 0 {
					return 0, false
				}
				vals[k] = v
			}
		}
		if pad > 2 {
			return 0, false
		}
		b0 := u8((vals[0] << 2) | (vals[1] >> 4))
		b1 := u8(((vals[1] & 0xF) << 4) | (vals[2] >> 2))
		b2 := u8(((vals[2] & 0x3) << 6) | vals[3])
		if n + 3 - pad > len(dst) {
			return 0, false
		}
		dst[n] = b0
		n += 1
		if pad < 2 {
			dst[n] = b1
			n += 1
		}
		if pad < 1 {
			dst[n] = b2
			n += 1
		}
		i += 4
		if pad > 0 {
			// Padding must terminate the input
			if i != len(src) {
				return 0, false
			}
			break
		}
	}
	return n, true
}

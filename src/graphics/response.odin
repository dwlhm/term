package graphics

KGP_RESPONSE_PREFIX :: "\x1b_Gi="
KGP_RESPONSE_SUFFIX :: "\x1b\\"
KGP_RESPONSE_OK :: "OK"
KGP_RESPONSE_NOT_FOUND :: "ENOENT:image not found"
KGP_RESPONSE_INVALID :: "EINVAL"
KGP_RESPONSE_UNSUPPORTED :: "EINVAL:unsupported"
KGP_RESPONSE_NO_SPACE :: "ENOSPC"
KGP_U32_DECIMAL_DIGITS :: 10

_kgp_response_token :: proc(res: Feed_Result) -> string {
	switch res {
	case .Ok:
		return KGP_RESPONSE_OK
	case .NotFound:
		return KGP_RESPONSE_NOT_FOUND
	case .Invalid:
		return KGP_RESPONSE_INVALID
	case .Unsupported:
		return KGP_RESPONSE_UNSUPPORTED
	case .No_Space:
		return KGP_RESPONSE_NO_SPACE
	}
	return KGP_RESPONSE_INVALID
}

// _kgp_write_u32 writes value as decimal and returns the number of bytes
// written, or zero when dst is too small.
_kgp_write_u32 :: proc(dst: []u8, value: u32) -> int {
	digits: [KGP_U32_DECIMAL_DIGITS]u8
	count := 0
	if value == 0 {
		digits[0] = '0'
		count = 1
	} else {
		remaining := value
		for remaining > 0 {
			digits[count] = u8(remaining % 10) + '0'
			remaining /= 10
			count += 1
		}
	}

	if len(dst) < count do return 0
	for i := 0; i < count; i += 1 {
		dst[i] = digits[count - i - 1]
	}
	return count
}

// kgp_format_response formats a KGP response into the caller-provided buffer.
// It returns an empty slice when the buffer cannot hold the complete response.
kgp_format_response :: proc(buf: []u8, id: u32, res: Feed_Result) -> []u8 {
	token := _kgp_response_token(res)
	id_buf: [KGP_U32_DECIMAL_DIGITS]u8
	id_len := _kgp_write_u32(id_buf[:], id)
	needed := len(KGP_RESPONSE_PREFIX) + id_len + 1 + len(token) + len(KGP_RESPONSE_SUFFIX)
	if len(buf) < needed do return buf[:0]

	pos := 0
	prefix := string(KGP_RESPONSE_PREFIX)
	copy(buf[pos:], prefix)
	pos += len(prefix)
	copy(buf[pos:], id_buf[:id_len])
	pos += id_len
	buf[pos] = ';'
	pos += 1
	copy(buf[pos:], transmute([]u8)token)
	pos += len(token)
	suffix := string(KGP_RESPONSE_SUFFIX)
	copy(buf[pos:], suffix)
	pos += len(suffix)
	return buf[:pos]
}

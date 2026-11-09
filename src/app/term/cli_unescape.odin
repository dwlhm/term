package term

// Raw string unescaping for CLI arguments (spec S25, S26).
// Resolves \e, \n, \r, \t, \\, and \xHH; reports the exact bad escape
// on failure.

import "core:strings"

app_cli_unescape_raw :: proc(
	s: string,
	allocator := context.temp_allocator,
) -> (res: string, bad_esc: string, ok: bool) {
	buf := make([dynamic]u8, allocator)
	i := 0
	for i < len(s) {
		ch := s[i]
		i += 1
		if ch != '\\' {
			append(&buf, ch)
			continue
		}
		if i >= len(s) do return "", "\\", false
		esc := s[i]
		i += 1
		switch esc {
		case 'n':  append(&buf, '\n')
		case 'r':  append(&buf, '\r')
		case 't':  append(&buf, '\t')
		case 'e':  append(&buf, 0x1b)
		case '\\': append(&buf, '\\')
		case 'x':
			if i + 2 > len(s) do return "", s[i - 2:], false
			hi := _hex_val(s[i])
			lo := _hex_val(s[i + 1])
			if hi < 0 || lo < 0 do return "", s[i - 2:i + 2], false
			append(&buf, u8(hi << 4 | lo))
			i += 2
		case:
			return "", s[i - 2:i], false
		}
	}
	return string(buf[:]), "", true
}

@(private = "file")
_hex_val :: proc(b: u8) -> int {
	switch b {
	case '0' ..= '9': return int(b - '0')
	case 'a' ..= 'f': return int(b - 'a' + 10)
	case 'A' ..= 'F': return int(b - 'A' + 10)
	}
	return -1
}

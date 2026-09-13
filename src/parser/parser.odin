package parser

import "base:runtime"
import termgrid "../terminal"

// Parser_Response_Cb is called when the parser needs to send a response
// back through the PTY (e.g., Device Attributes, cursor position report).
Parser_Response_Cb :: proc(data: []u8)

// Parser_Clipboard_Cb is called when an OSC 52 clipboard write arrives.
// The callee owns delivery to the system clipboard.
Parser_Clipboard_Cb :: proc(data: []u8)

// Parser is the top-level VT parser state.
Parser :: struct {
	state:             Parser_State,
	csi_count:         u8,
	csi_subparam_mask: u16, // bit i = 1 when param i was introduced by ':' (sub-parameter)

	// CSI parameter storage
	csi_values:        [16]u32,

	// UTF-8 decoder state
	utf8_state:  UTF8_State,
	utf8_len:    u8,
	utf8_buffer: [4]u8,

	// Small persistent state & flags
	intermediate:       u8,
	string_esc_pending: bool,
	osc_truncated:      bool, // true when the OSC payload exceeded osc_buffer

	// String buffers (OSC / DCS)
	osc_len:    int,
	osc_buffer: [512]u8,
	dcs_len:    int,
	dcs_buffer: [512]u8,
	
	// Print run accumulator (for Level 1 fast path)
	print_run_start: int,
	print_run_len:   int,
	
	// Response callback for sending data back to PTY
	response_cb: Parser_Response_Cb,

	// Clipboard callback for OSC 52 clipboard writes
	clipboard_cb: Parser_Clipboard_Cb,

	// Clipboard read callback for OSC 52 clipboard queries
	clipboard_read_cb: #type proc(user_data: rawptr, out: []u8) -> int,
	clipboard_read_user_data: rawptr,
}

// parser_init initializes a parser.
parser_init :: proc(p: ^Parser) {
	// Initialize global tables (idempotent)
	init()
	
	p.state = .Ground
	p.csi_count = 0
	p.utf8_state = .Ground
	p.utf8_len = 0
	p.intermediate = 0
	p.string_esc_pending = false
	p.print_run_start = 0
	p.print_run_len = 0
	p.osc_len = 0
	p.osc_truncated = false
	p.dcs_len = 0

	// Clear CSI values
	for i in 0..<16 {
		p.csi_values[i] = 0
	}
	p.csi_subparam_mask = 0
	
	// Clear UTF-8 buffer
	for i in 0..<4 {
		p.utf8_buffer[i] = 0
	}

	p.response_cb = nil
	p.clipboard_cb = nil
	p.clipboard_read_cb = nil
	p.clipboard_read_user_data = nil
}

// parser_destroy frees parser state (currently no-op, but future-proof).
parser_destroy :: proc(p: ^Parser) {
	// No-op: Parser is stack-allocated, no heap allocations to free
}

// parse_chunk parses a chunk of bytes and mutates terminal state.
// This is the main entry point called by the I/O layer.
parse_chunk :: proc(p: ^Parser, t: ^termgrid.Terminal, input: []u8) {
	pos := 0
	
	for pos < len(input) {
		// OSC/DCS strings are opaque to the terminal but their terminators
		// are part of the parser state, including when split across reads.
		if p.state == .OSC || p.state == .DCS {
			byte := input[pos]
			if p.string_esc_pending {
				p.string_esc_pending = false
				if byte == '\\' {
					is_osc := p.state == .OSC
					p.state = .Ground
					if is_osc {
						osc_dispatch(p, t, p.osc_buffer[:p.osc_len])
						p.osc_len = 0
						p.osc_truncated = false
					} else {
						dcs_dispatch(p, t, p.dcs_buffer[:p.dcs_len])
						p.dcs_len = 0
					}
					pos += 1
					continue
				}
				if byte == 0x1B {
					p.string_esc_pending = true
				}
				pos += 1
				continue
			}
			if byte == 0x07 || byte == 0x9C {
				is_osc := p.state == .OSC
				p.state = .Ground
				if is_osc {
					osc_dispatch(p, t, p.osc_buffer[:p.osc_len])
					p.osc_len = 0
					p.osc_truncated = false
				} else {
					dcs_dispatch(p, t, p.dcs_buffer[:p.dcs_len])
					p.dcs_len = 0
				}
				pos += 1
				continue
			}
			if byte == 0x18 || byte == 0x1A {
				parser_reset(p)
				pos += 1
				continue
			}
			if byte == 0x1B {
				p.string_esc_pending = true
				pos += 1
				continue
			}
			if p.state == .OSC {
				if p.osc_len < len(p.osc_buffer) {
					p.osc_buffer[p.osc_len] = byte
					p.osc_len += 1
				} else {
					p.osc_truncated = true
				}
			} else {
				if p.dcs_len < len(p.dcs_buffer) {
					p.dcs_buffer[p.dcs_len] = byte
					p.dcs_len += 1
				}
			}
			pos += 1
			continue
		}
		// Level 1: Block Scanner (ASCII fast path)
		if p.state == .Ground {
			run := scan_ascii_run(input[pos:])
			if run.length > 0 {
				terminal_print_run(t, run.data, t.current_style)
				pos += run.length
				continue
			}
		}
		
		// Level 2: VT State Machine
		byte := input[pos]
		transition := TRANSITION_TABLE[p.state][byte]
		
		// Execute the action
		#partial switch transition.action {
		case .Print:
			// Accumulate print run (for non-fast-path cases)
			accumulate_print_run(p, byte)
		case .Execute:
			execute_c0(t, byte)
		case .Clear:
			clear_parser_state(p)
		case .Collect:
			p.intermediate = byte
		case .Param:
			csi_collect_param(p, byte)
		case .CsiDispatch:
			csi_dispatch(p, t, byte)
		case .EscDispatch:
			esc_dispatch(p, t, byte)
		case .OscStart:
			p.state = .OSC
			p.string_esc_pending = false
			p.osc_len = 0
			p.osc_truncated = false
		case .OscPut:
			// Discard OSC payload
		case .OscEnd:
			p.state = .Ground
		case .DcsHook:
			p.state = .DCS
			p.string_esc_pending = false
			p.dcs_len = 0
		case .DcsPut:
			// Discard DCS payload
		case .DcsUnhook:
			p.state = .Ground
		case .Utf8:
			utf8_feed(p, t, byte)
		case .Ignore:
			// Do nothing
		case .Error:
			// Invalid transition - reset to Ground
			p.state = .Ground
		}
		
		// Update state (unless action already changed it)
		if transition.action != .OscStart &&
		   transition.action != .OscEnd &&
		   transition.action != .DcsHook &&
		   transition.action != .DcsUnhook {
			p.state = transition.next_state
		}

		// UTF-8 completion sync: utf8_feed consumes the byte and returns the
		// decoder to Ground on completion (valid rune, FFFD, or invalid
		// lead). The parser must follow, or the next byte would be handled
		// in the stale Utf8 state (ASCII would hit Print/accumulate and be
		// dropped). A re-fed new lead leaves the decoder pending, so the
		// parser correctly stays in Utf8.
		if transition.action == .Utf8 && p.utf8_state == .Ground {
			p.state = .Ground
		}
		
		pos += 1
	}
}

// parser_get_state returns the current parser state (for testing/debugging).
parser_get_state :: proc(p: ^Parser) -> Parser_State {
	return p.state
}

// parser_reset resets the parser to Ground state.
parser_reset :: proc(p: ^Parser) {
	p.state = .Ground
	csi_reset(p)
	utf8_reset(p)
	p.intermediate = 0
	p.string_esc_pending = false
	p.print_run_start = 0
	p.print_run_len = 0
	p.osc_len = 0
	p.osc_truncated = false
	p.dcs_len = 0
}

// accumulate_print_run accumulates a byte into the print run buffer.
accumulate_print_run :: proc(p: ^Parser, b: u8) {
	// For now, we don't accumulate - just emit directly
	// Future optimization: batch ASCII runs
	_ = p
	_ = b
}

// clear_parser_state clears the parser state (called on ESC or CAN).
clear_parser_state :: proc(p: ^Parser) {
	csi_reset(p)
	p.intermediate = 0
}

// terminal_print_run writes a run of bytes to the terminal.
terminal_print_run :: proc(t: ^termgrid.Terminal, data: []u8, style: termgrid.Style_Id) {
	termgrid.terminal_print_span(t, data, style)
}

// execute_c0 executes a C0 control character.
execute_c0 :: proc(t: ^termgrid.Terminal, b: u8) {
	switch b {
	case 0x08: // BS (Backspace)
		termgrid.terminal_backspace(t)
	case 0x09: // TAB
		// Advance to next tab stop (simplified: advance 8 columns)
		tab_stop := 8 - (t.cursor.col % 8)
		termgrid.terminal_cursor_right(t, tab_stop)
	case 0x0A: // LF (Line Feed)
		termgrid.terminal_linefeed(t)
	case 0x0D: // CR (Carriage Return)
		t.cursor.col = 0
		t.cursor.pending_wrap = false
	}
}

// esc_dispatch dispatches an escape sequence.
esc_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8) {
	_ = p
	switch final_byte {
	case '7':
		termgrid.terminal_save_cursor(t)
	case '8':
		termgrid.terminal_restore_cursor(t)
	case 'c':
		termgrid.terminal_reset(t)
	case 'M':
		termgrid.terminal_reverse_index(t)
	case 'D':
		termgrid.terminal_index(t)
	case 'E':
		termgrid.terminal_next_line(t)
	}
}

// _osc_number parses a leading decimal OSC number (0, 1, 2, 7, 11, 52,
// 133, ...). Returns the number and the index just past it.
_osc_number :: proc(payload: []u8) -> (num: int, next: int) {
	num = 0
	i := 0
	for i < len(payload) && payload[i] >= '0' && payload[i] <= '9' {
		num = num * 10 + int(payload[i] - '0')
		i += 1
	}
	return num, i
}

// _osc_base64_value maps one base64 character to its 6-bit value.
// Returns -1 for characters outside the standard alphabet.
_osc_base64_value :: proc(c: u8) -> int {
	if c >= 'A' && c <= 'Z' { return int(c - 'A') }
	if c >= 'a' && c <= 'z' { return int(c - 'a' + 26) }
	if c >= '0' && c <= '9' { return int(c - '0' + 52) }
	if c == '+' { return 62 }
	if c == '/' { return 63 }
	return -1
}

// _BASE64_TABLE is the standard RFC 4648 base64 alphabet.
_BASE64_TABLE :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// _osc_base64_encode encodes bytes in src using standard base64 table (A-Za-z0-9+/)
// with '=' padding into dst.
_osc_base64_encode :: proc(src: []u8, dst: []u8) -> (n: int, ok: bool) {
	table := _BASE64_TABLE
	out_len := ((len(src) + 2) / 3) * 4
	if len(dst) < out_len {
		return 0, false
	}
	n = 0
	i := 0
	for i + 3 <= len(src) {
		b0 := src[i]
		b1 := src[i + 1]
		b2 := src[i + 2]
		dst[n]     = table[(b0 >> 2) & 0x3F]
		dst[n + 1] = table[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)]
		dst[n + 2] = table[((b1 & 0x0F) << 2) | ((b2 >> 6) & 0x03)]
		dst[n + 3] = table[b2 & 0x3F]
		n += 4
		i += 3
	}
	rem := len(src) - i
	if rem == 1 {
		b0 := src[i]
		dst[n]     = table[(b0 >> 2) & 0x3F]
		dst[n + 1] = table[(b0 & 0x03) << 4]
		dst[n + 2] = '='
		dst[n + 3] = '='
		n += 4
	} else if rem == 2 {
		b0 := src[i]
		b1 := src[i + 1]
		dst[n]     = table[(b0 >> 2) & 0x3F]
		dst[n + 1] = table[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)]
		dst[n + 2] = table[(b1 & 0x0F) << 2]
		dst[n + 3] = '='
		n += 4
	}
	return n, true
}

// _osc_base64_decode decodes standard base64 src into dst.
// Stops at '=' padding or the first invalid character. Returns the decoded
// length and false when the input is malformed or dst is too small.
_osc_base64_decode :: proc(src: []u8, dst: []u8) -> (n: int, ok: bool) {
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
				v := _osc_base64_value(c)
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

// _osc_write_hex4 writes v as 4 lowercase hex digits into dst at off.
_osc_write_hex4 :: proc(dst: []u8, off: int, v: u32) {
	for k in 0..<4 {
		shift := u32(12 - k * 4)
		d := (v >> shift) & 0xF
		if d < 10 {
			dst[off + k] = '0' + u8(d)
		} else {
			dst[off + k] = 'a' + u8(d - 10)
		}
	}
}

// osc_dispatch dispatches an Operating System Command sequence.
// Handled numbers: 0/1/2 (window title, stored + applied by the app layer),
// 4 (palette color query, answered), 7 (working directory, retained),
// 8 (hyperlinks), 10 (foreground color query, answered),
// 11 (background color query, answered),
// 52 (clipboard write AND query), 133 (prompt marks).
// Unknown numbers are ignored per the fish terminal-compatibility contract.
osc_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, payload: []u8) {
	if t == nil || len(payload) == 0 { return }
	num, next := _osc_number(payload)
	if next >= len(payload) || payload[next] != ';' { return }
	body := payload[next + 1:]

	switch num {
	case 0, 1, 2:
		// Window/tab title. Skip when truncated: a partial title would
		// flicker a wrong value on every prompt render.
		if p.osc_truncated { return }
		termgrid.terminal_osc_set_title(t, body)
	case 4:
		// Palette color query ("4;<idx>;?"): respond rgb:rrrr/gggg/bbbb
		// with 16-bit channels scaled from the theme palette.
		if p.response_cb == nil { return }
		idx_val := 0
		i := 0
		for i < len(body) && body[i] >= '0' && body[i] <= '9' {
			idx_val = idx_val * 10 + int(body[i] - '0')
			i += 1
		}
		if i > 0 && i + 2 == len(body) && body[i] == ';' && body[i + 1] == '?' && idx_val >= 0 && idx_val <= 255 {
			col := termgrid.theme_palette_256(t.grid.style_table.theme, idx_val)
			r16 := u32(((col >> 16) & 0xFF) * 257)
			g16 := u32(((col >> 8) & 0xFF) * 257)
			b16 := u32((col & 0xFF) * 257)
			resp: [64]u8
			n := 0
			resp[n] = 0x1B; n += 1
			resp[n] = ']'; n += 1
			resp[n] = '4'; n += 1
			resp[n] = ';'; n += 1
			for k in 0..<i {
				resp[n] = body[k]
				n += 1
			}
			resp[n] = ';'; n += 1
			resp[n] = 'r'; n += 1
			resp[n] = 'g'; n += 1
			resp[n] = 'b'; n += 1
			resp[n] = ':'; n += 1
			_osc_write_hex4(resp[:], n, r16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, g16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, b16); n += 4
			resp[n] = 0x1B; n += 1
			resp[n] = '\\'; n += 1
			p.response_cb(resp[:n])
		}
	case 7:
		termgrid.terminal_osc_set_cwd(t, body)
	case 8:
		// Hyperlink ("8;<params>;<url>")
		semicolon_pos := -1
		for b, idx in body {
			if b == ';' {
				semicolon_pos = idx
				break
			}
		}
		if semicolon_pos >= 0 {
			url := body[semicolon_pos + 1:]
			if len(url) > 0 {
				termgrid.terminal_osc_8_set_url(t, url)
			} else {
				termgrid.terminal_osc_8_clear_url(t)
			}
		}
	case 10:
		// Foreground color query ("10;?"): respond rgb:RRRR/GGGG/BBBB
		// with 16-bit channels scaled from the theme foreground.
		if len(body) == 1 && body[0] == '?' && p.response_cb != nil {
			fg := t.grid.style_table.theme.foreground
			r16 := u32(((fg >> 16) & 0xFF) * 257)
			g16 := u32(((fg >> 8) & 0xFF) * 257)
			b16 := u32((fg & 0xFF) * 257)
			resp: [32]u8
			n := 0
			resp[n] = 0x1B; n += 1
			resp[n] = ']'; n += 1
			resp[n] = '1'; n += 1
			resp[n] = '0'; n += 1
			resp[n] = ';'; n += 1
			resp[n] = 'r'; n += 1
			resp[n] = 'g'; n += 1
			resp[n] = 'b'; n += 1
			resp[n] = ':'; n += 1
			_osc_write_hex4(resp[:], n, r16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, g16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, b16); n += 4
			resp[n] = 0x1B; n += 1
			resp[n] = '\\'; n += 1
			p.response_cb(resp[:n])
		}
	case 11:
		// Background color query ("11;?"): respond rgb:RRRR/GGGG/BBBB
		// with 16-bit channels scaled from the theme background.
		if len(body) == 1 && body[0] == '?' && p.response_cb != nil {
			bg := t.grid.style_table.theme.background
			r16 := u32(((bg >> 16) & 0xFF) * 257)
			g16 := u32(((bg >> 8) & 0xFF) * 257)
			b16 := u32((bg & 0xFF) * 257)
			resp: [32]u8
			n := 0
			resp[n] = 0x1B; n += 1
			resp[n] = ']'; n += 1
			resp[n] = '1'; n += 1
			resp[n] = '1'; n += 1
			resp[n] = ';'; n += 1
			resp[n] = 'r'; n += 1
			resp[n] = 'g'; n += 1
			resp[n] = 'b'; n += 1
			resp[n] = ':'; n += 1
			_osc_write_hex4(resp[:], n, r16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, g16); n += 4
			resp[n] = '/'; n += 1
			_osc_write_hex4(resp[:], n, b16); n += 4
			resp[n] = 0x1B; n += 1
			resp[n] = '\\'; n += 1
			p.response_cb(resp[:n])
		}
	case 52:
		// Clipboard query ("52;c;?") and write ("52;c;<base64>").
		if len(body) >= 3 && body[0] == 'c' && body[1] == ';' && body[2] == '?' {
			if p.clipboard_read_cb != nil && p.response_cb != nil {
				raw_buf: [512]u8
				raw_len := p.clipboard_read_cb(p.clipboard_read_user_data, raw_buf[:])
				if raw_len >= 0 && raw_len <= len(raw_buf) {
					b64_buf: [1024]u8
					b64_len, b64_ok := _osc_base64_encode(raw_buf[:raw_len], b64_buf[:])
					if b64_ok {
						resp: [2048]u8
						n := 0
						resp[n] = 0x1B; n += 1
						resp[n] = ']'; n += 1
						resp[n] = '5'; n += 1
						resp[n] = '2'; n += 1
						resp[n] = ';'; n += 1
						resp[n] = 'c'; n += 1
						resp[n] = ';'; n += 1
						for k in 0..<b64_len {
							resp[n] = b64_buf[k]
							n += 1
						}
						resp[n] = 0x1B; n += 1
						resp[n] = '\\'; n += 1
						p.response_cb(resp[:n])
					}
				}
			}
			return
		}
		// Clipboard write ("52;c;<base64>"). Only the 'c' (clipboard
		// selection) form is honored. Truncated payloads are skipped:
		// a partial base64 quantum would otherwise set a corrupt clipboard.
		if len(body) < 2 || body[0] != 'c' || body[1] != ';' { return }
		if p.osc_truncated || p.clipboard_cb == nil { return }
		decoded: [1024]u8
		n, ok := _osc_base64_decode(body[2:], decoded[:])
		if ok && n > 0 {
			p.clipboard_cb(decoded[:n])
		}
	case 133:
		if len(body) < 1 { return }
		switch body[0] {
		case 'A': termgrid.terminal_osc_133_prompt_start(t)
		case 'B': termgrid.terminal_osc_133_prompt_end(t)
		case 'C': termgrid.terminal_osc_133_command_start(t)
		case 'D': termgrid.terminal_osc_133_command_end(t)
		}
	}
}

// _dcs_hex_eq reports whether hex ASCII bytes a equal the literal b,
// case-insensitively (fish sends lowercase; be lenient).
_dcs_hex_eq :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0..<len(a) {
		ca := a[i]
		if ca >= 'A' && ca <= 'F' { ca += 'a' - 'A' }
		cb := b[i]
		if cb >= 'A' && cb <= 'F' { cb += 'a' - 'A' }
		if ca != cb { return false }
	}
	return true
}

// DCS_XTGETTCAP_INDN is the hex encoding of "indn" (scroll-up). fish queries
// this via DCS + q 696e646e ST; answering it confirms scroll capability and
// enables the ctrl-l scrollback-push binding.
DCS_XTGETTCAP_INDN :: "696e646e"

// DCS_XTGETTCAP_TC is the hex encoding of "Tc" (truecolor support).
DCS_XTGETTCAP_TC :: "5463"

// DCS_XTGETTCAP_RGB is the hex encoding of "RGB" (direct color support).
DCS_XTGETTCAP_RGB :: "524742"

// DCS_XTGETTCAP_OS is the hex encoding of fish's "query-os-name" capability.
DCS_XTGETTCAP_OS :: "71756572792d6f732d6e616d65"

// dcs_dispatch dispatches a Device Control String payload.
// Only XTGETTCAP ("+q<hex>") is answered: "indn", "Tc", and "RGB" as boolean
// true (confirming scroll-up and truecolor capabilities), and "query-os-name"
// with the platform name. Unknown DCS payloads are ignored per ECMA-48.
dcs_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, payload: []u8) {
	_ = t
	if p == nil || p.response_cb == nil { return }
	if len(payload) < 3 || payload[0] != '+' || payload[1] != 'q' { return }
	param := payload[2:]

	if _dcs_hex_eq(param, DCS_XTGETTCAP_INDN) || _dcs_hex_eq(param, DCS_XTGETTCAP_TC) || _dcs_hex_eq(param, DCS_XTGETTCAP_RGB) {
		// Boolean response: DCS 1 + r <param> ST. Note the 'r': per
		// xterm, requests use +q but responses use +r. Echoing +q makes
		// fish reject the response and dump the payload as typed input.
		resp: [1024]u8
		n := 0
		resp[n] = 0x1B; n += 1
		resp[n] = 'P'; n += 1
		resp[n] = '1'; n += 1
		resp[n] = '+'; n += 1
		resp[n] = 'r'; n += 1
		if n + len(param) + 2 > len(resp) { return }
		for b in param {
			resp[n] = b
			n += 1
		}
		resp[n] = 0x1B; n += 1
		resp[n] = '\\'; n += 1
		p.response_cb(resp[:n])
		return
	}

	if _dcs_hex_eq(param, DCS_XTGETTCAP_OS) {
		// String response: DCS 1 + r <param> = <hex-os> ST ('r', not 'q').
		os_hex := "44617277696e" // "Darwin"
		when ODIN_OS != .Darwin {
			os_hex = "4c696e7578" // "Linux"
		}
		resp: [1024]u8
		n := 0
		resp[n] = 0x1B; n += 1
		resp[n] = 'P'; n += 1
		resp[n] = '1'; n += 1
		resp[n] = '+'; n += 1
		resp[n] = 'r'; n += 1
		if n + len(param) + 1 + len(os_hex) + 2 > len(resp) { return }
		for b in param {
			resp[n] = b
			n += 1
		}
		resp[n] = '='; n += 1
		for i in 0..<len(os_hex) {
			resp[n] = os_hex[i]
			n += 1
		}
		resp[n] = 0x1B; n += 1
		resp[n] = '\\'; n += 1
		p.response_cb(resp[:n])
		return
	}
}


package terminal_parser

import "core:strconv"
import "core:strings"
import damage "../damage"
import grid "../grid"

parser_emit_response :: proc(p: ^Parser, data: []u8) -> bool {
	if p == nil || len(data) == 0 do return false
	space := len(p.response_buf) - p.response_len
	to_copy := min(len(data), space)
	if to_copy <= 0 do return false
	copy(p.response_buf[p.response_len : p.response_len + to_copy], data[:to_copy])
	p.response_len += to_copy
	return true
}

parser_drain_response :: proc(p: ^Parser, out: []u8) -> int {
	if p == nil || p.response_len == 0 do return 0
	n := min(len(out), p.response_len)
	copy(out[:n], p.response_buf[:n])
	if n < p.response_len {
		copy(p.response_buf[:p.response_len - n], p.response_buf[n:p.response_len])
		p.response_len -= n
	} else {
		p.response_len = 0
	}
	return n
}

parser_init :: proc(p: ^Parser, rows, cols: int) {
	if p == nil do return
	p.state = .Ground
	p.scroll_top = 0
	p.scroll_bottom = max(0, rows - 1)
	p.cursor = Cursor{
		row          = 0,
		col          = 0,
		saved_row    = 0,
		saved_col    = 0,
		active_fg    = 7,
		active_bg    = 0,
		active_style = {},
		active_flags = {},
		direct_color = {},
		visible      = true,
		pending_wrap = false,
		shape        = .Block,
		blinking     = true,
	}
	p.csi_count = 0
	p.csi_prefix = 0
	p.csi_intermediate = 0
	p.in_alt_screen = false
	p.cursor_key_mode = false
	p.osc_len = 0
	p.response_len = 0
	p.utf8_state = 0
	p.utf8_len = 0
	p.egc_pool = nil
	p.on_osc = nil
	p.on_csi = nil
	p.user_data = nil
}

parser_reset :: proc(p: ^Parser, rows, cols: int) {
	parser_init(p, rows, cols)
}

_parser_dispatch_osc :: proc(p: ^Parser) {
	if p == nil || p.osc_len == 0 do return
	defer p.osc_len = 0

	s := string(p.osc_buf[:p.osc_len])
	semi_idx := strings.index_byte(s, ';')

	osc_id := 0
	payload := ""

	if semi_idx >= 0 {
		num_str := s[:semi_idx]
		parsed_id, ok := strconv.parse_int(num_str)
		if ok {
			osc_id = parsed_id
		}
		if semi_idx + 1 < len(s) {
			payload = s[semi_idx + 1 :]
		}
	} else {
		parsed_id, ok := strconv.parse_int(s)
		if ok {
			osc_id = parsed_id
		}
	}

	if p.on_osc != nil {
		p.on_osc(p.user_data, osc_id, payload)
	}
}

parser_parse_byte :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, b: u8) {
	if p == nil do return

	switch p.state {
	case .Ground:
		if b >= 0x80 {
			_parser_feed_utf8(p, g, d, b)
			return
		}

		if p.utf8_state != 0 {
			p.utf8_state = 0
			p.utf8_len = 0
		}

		switch b {
		case 0x1B: // ESC
			p.state = .Escape
		case '\r': // Carriage Return
			p.cursor.col = 0
			p.cursor.pending_wrap = false
		case '\n', 0x0B, 0x0C: // Line Feed, VT, FF
			if p.cursor.row == p.scroll_bottom {
				erase_c, erase_dc := _parser_erase_cell(p)
				grid.grid_scroll_up(g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else if p.cursor.row < g.row_count - 1 {
				p.cursor.row += 1
			}
			p.cursor.pending_wrap = false
		case '\t': // Tab
			next_tab := (p.cursor.col / 8 + 1) * 8
			p.cursor.col = min(g.col_count - 1, next_tab)
			p.cursor.pending_wrap = false
		case 0x08: // Backspace
			p.cursor.col = max(0, p.cursor.col - 1)
			p.cursor.pending_wrap = false
		case 0x07: // BEL
			// Bell ignored in core
		case 0x20..=0x7E: // Printable ASCII Fast Path
			_parser_put_char(p, g, d, rune(b))
		}

	case .Escape:
		p.utf8_state = 0
		p.utf8_len = 0
		switch b {
		case '[':
			p.state = .Csi_Entry
			p.csi_count = 0
			p.csi_prefix = 0
			p.csi_intermediate = 0
			for i in 0..<MAX_CSI_PARAMS {
				p.csi_params[i] = 0
			}
		case ']':
			p.state = .Osc_String
			p.osc_len = 0
		case '(', ')', '*', '+', '-', '.', '/':
			p.state = .Esc_Charset
		case 'P': // DCS - Device Control String
			p.state = .Dcs_String
		case '_': // APC - Application Program Command
			p.state = .Apc_String
		case '^', 'X': // PM / SOS
			p.state = .Dcs_String
		case 'M': // Reverse Index (scroll down if at top margin)
			if p.cursor.row == p.scroll_top {
				erase_c, erase_dc := _parser_erase_cell(p)
				grid.grid_scroll_down(g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else {
				p.cursor.row = max(0, p.cursor.row - 1)
			}
			p.state = .Ground
		case '7': // Save Cursor
			p.cursor.saved_row = p.cursor.row
			p.cursor.saved_col = p.cursor.col
			p.state = .Ground
		case '8': // Restore Cursor
			p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
			p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
			p.state = .Ground
		case '=', '>': // DECKPAM / DECKPNM
			p.state = .Ground
		case:
			p.state = .Ground
		}

	case .Esc_Charset:
		// ISO 2022 Character Set Designator: consume the charset byte ('B', '0', etc.)
		p.state = .Ground

	case .Dcs_String:
		if b == 0x07 { // BEL terminates DCS
			p.state = .Ground
		} else if b == 0x1B {
			p.state = .Esc_In_Dcs
		}

	case .Esc_In_Dcs:
		if b == '\\' { // String Terminator (ST)
			p.state = .Ground
		} else if b == 0x1B {
			// Stay in Esc_In_Dcs
		} else {
			p.state = .Ground
		}

	case .Apc_String:
		if b == 0x07 { // BEL terminates APC
			p.state = .Ground
		} else if b == 0x1B {
			p.state = .Esc_In_Apc
		}

	case .Esc_In_Apc:
		if b == '\\' { // ST
			p.state = .Ground
		} else if b == 0x1B {
			// Stay in Esc_In_Apc
		} else {
			p.state = .Ground
		}

	case .Csi_Entry:
		if b == '?' || b == '>' || b == '<' || b == '=' {
			p.csi_prefix = b
			p.state = .Csi_Param
		} else if b >= '0' && b <= '9' {
			p.csi_params[0] = int(b - '0')
			p.csi_count = 1
			p.state = .Csi_Param
		} else if b == ';' || b == ':' {
			p.csi_count = 2
			p.state = .Csi_Param
		} else if b >= 0x20 && b <= 0x2F {
			p.csi_intermediate = b
			p.state = .Csi_Param
		} else if b >= 0x40 && b <= 0x7E {
			// Instant CSI command with 0 parameters
			_parser_handle_csi(p, g, d, b)
			p.state = .Ground
		} else {
			p.state = .Ground
		}

	case .Csi_Param:
		if b >= '0' && b <= '9' {
			idx := max(0, p.csi_count - 1)
			if p.csi_count == 0 {
				idx = 0
				p.csi_count = 1
			}
			p.csi_params[idx] = p.csi_params[idx] * 10 + int(b - '0')
		} else if b == ';' || b == ':' {
			if p.csi_count < MAX_CSI_PARAMS {
				p.csi_count += 1
				p.csi_params[p.csi_count - 1] = 0
			}
		} else if b >= 0x20 && b <= 0x2F {
			p.csi_intermediate = b
		} else if b >= 0x40 && b <= 0x7E {
			// End of CSI command
			_parser_handle_csi(p, g, d, b)
			p.state = .Ground
		} else {
			p.state = .Ground
		}

	case .Osc_String:
		if b == 0x07 { // BEL terminates OSC
			_parser_dispatch_osc(p)
			p.state = .Ground
		} else if b == 0x1B { // ESC inside OSC might be ST (ESC \)
			p.state = .Esc_In_Osc
		} else {
			if p.osc_len < MAX_OSC_BUFFER - 1 {
				p.osc_buf[p.osc_len] = b
				p.osc_len += 1
			}
		}

	case .Esc_In_Osc:
		if b == '\\' { // String Terminator (ST)
			_parser_dispatch_osc(p)
			p.state = .Ground
		} else {
			// Aborted OSC sequence
			p.osc_len = 0
			p.state = .Ground
		}
	}
}

parser_parse_bytes :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, data: []u8) {
	if p == nil || len(data) == 0 do return

	i := 0
	for i < len(data) {
		// Fast ASCII run scanner in Ground state (only when not in middle of UTF-8 sequence)
		if p.state == .Ground && p.utf8_state == 0 {
			start := i
			for i < len(data) && data[i] >= 0x20 && data[i] <= 0x7E && !p.cursor.pending_wrap {
				_parser_put_char(p, g, d, rune(data[i]))
				i += 1
			}
			if i > start && i < len(data) && (data[i] < 0x20 || data[i] > 0x7E) {
				// Process next byte
				parser_parse_byte(p, g, d, data[i])
				i += 1
				continue
			}
			if i >= len(data) do break
		}

		parser_parse_byte(p, g, d, data[i])
		i += 1
	}
}

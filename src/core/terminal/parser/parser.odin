package terminal_parser

import "core:strconv"
import "core:strings"
import cell "../cell"
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
		saved_row         = 0,
		saved_col         = 0,
		saved_origin_mode = false,
		saved_autowrap    = true,
		active_fg         = 7,
		active_bg    = 0,
		active_style = {},
		active_flags = {},
		underline_style = .None,
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
	p.sync_output = false
	p.active_link = 0
	p.kbd_depth = 0
	for i in 0..<len(p.kbd_flags) do p.kbd_flags[i] = 0
	p.last_print = 0
	for i in 0..<len(p.tab_stops) do p.tab_stops[i] = (i % 8 == 0)
	p.charsets = [4]u8{CHARSET_ASCII, CHARSET_ASCII, CHARSET_ASCII, CHARSET_ASCII}
	p.gl = 0
	p.gl_single = 0
	p.esc_charset_slot = 0
	p.cursor_key_mode = false
	p.keypad_app = false
	p.origin_mode = false
	p.autowrap = true
	p.bracketed_paste = false
	p.alternate_scroll_mode = false
	p.mouse_mode = .None
	p.mouse_format = .X10
	p.report_focus = false
	p.osc_overflow = false
	if p.osc_buf == nil {
		p.osc_buf = make([dynamic]u8, 0, 1024)
	} else {
		clear(&p.osc_buf)
	}
	p.apc_overflow = false
	if p.apc_buf == nil {
		p.apc_buf = make([dynamic]u8, 0, 131072)
	} else {
		clear(&p.apc_buf)
	}
	p.dcs_overflow = false
	if p.dcs_buf == nil {
		p.dcs_buf = make([dynamic]u8, 0, 131072)
	} else {
		clear(&p.dcs_buf)
	}
	p.response_len = 0
	p.utf8_state = 0
	p.utf8_len = 0
	p.prompt_state = .None
	p.egc_pool = nil
	p.on_osc = nil
	p.on_csi = nil
	p.on_apc = nil
	p.on_dcs = nil
	p.user_data = nil
}

parser_destroy :: proc(p: ^Parser) {
	if p == nil do return
	delete(p.osc_buf)
	p.osc_buf = nil
	delete(p.apc_buf)
	p.apc_buf = nil
	delete(p.dcs_buf)
	p.dcs_buf = nil
}

parser_reset :: proc(p: ^Parser, rows, cols: int) {
	parser_init(p, rows, cols)
}

_parser_dispatch_apc :: proc(p: ^Parser) {
	if p == nil do return
	defer {
		clear(&p.apc_buf)
		p.apc_overflow = false
	}
	// A truncated APC payload is never a valid protocol frame: drop it whole
	// instead of handing a half-decoded image or query to the extension.
	if p.apc_overflow || len(p.apc_buf) == 0 do return

	if p.on_apc != nil {
		p.on_apc(p.user_data, p.apc_buf[:])
	}
}

_parser_dispatch_dcs :: proc(p: ^Parser) {
	if p == nil do return
	defer {
		clear(&p.dcs_buf)
		p.dcs_overflow = false
	}
	if p.dcs_overflow || len(p.dcs_buf) == 0 do return

	if p.on_dcs != nil {
		p.on_dcs(p.user_data, p.dcs_buf[:])
	}
}

_parser_mark_prompt_row :: #force_inline proc(p: ^Parser, g: ^grid.Grid) {
	if p == nil || g == nil || p.in_alt_screen || p.prompt_state != .Prompt do return
	if phys := grid.grid_physical_row(g, p.cursor.row); phys >= 0 && phys < len(g.rows) {
		g.rows[phys].is_prompt = true
	}
}

_parser_clear_prompt_rows :: proc(g: ^grid.Grid, from_row, to_row: int) {
	if g == nil do return
	for r in max(0, from_row) ..< min(g.row_count, to_row) {
		if phys := grid.grid_physical_row(g, r); phys >= 0 && phys < len(g.rows) {
			g.rows[phys].is_prompt = false
		}
	}
}

_parser_handle_osc_133 :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, payload: string) {
	if p == nil || g == nil || p.in_alt_screen || len(payload) == 0 do return
	switch payload[0] {
	case 'A':
		if p.prompt_state != .None {
			erase_c, erase_dc := _parser_erase_cell(p)
			for p.cursor.row > 0 {
				above := grid.grid_physical_row(g, p.cursor.row - 1)
				if above < 0 || above >= len(g.rows) || !g.rows[above].is_prompt do break
				p.cursor.row -= 1
				grid.grid_clear_line(g, d, p.cursor.row, 0, g.col_count, erase_c, erase_dc)
			}
		}
		_parser_clear_prompt_rows(g, 0, g.row_count)
		p.prompt_state = .Prompt
		_parser_mark_prompt_row(p, g)
	case 'P':
		p.prompt_state = .Prompt
		_parser_mark_prompt_row(p, g)
	case 'B':
		p.prompt_state = .Input
		if phys := grid.grid_physical_row(g, p.cursor.row); phys >= 0 && phys < len(g.rows) {
			g.rows[phys].is_prompt = true
		}
		_parser_clear_prompt_rows(g, p.cursor.row + 1, g.row_count)
	case 'C', 'D':
		p.prompt_state = .None
		_parser_clear_prompt_rows(g, 0, g.row_count)
	}
}

_parser_dispatch_osc :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	if p == nil do return
	defer {
		clear(&p.osc_buf)
		p.osc_overflow = false
	}
	// Oversized/truncated OSC sequences are dropped whole so a clipboard or
	// hyperlink payload can never be silently cut in half.
	if p.osc_overflow || len(p.osc_buf) == 0 do return

	s := string(p.osc_buf[:])
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

	if osc_id == 133 {
		_parser_handle_osc_133(p, g, d, payload)
	}
	if p.on_osc != nil {
		p.on_osc(p.user_data, osc_id, payload)
	}
}

parser_parse_byte :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, b: u8) {
	if p == nil do return
	// CAN/SUB cancel any escape sequence or control string in progress (DEC
	// STD 070), so a stream that ends mid-sequence can be resynchronised.
	if b == 0x18 || b == 0x1A {
		_parser_abort_sequence(p)
		return
	}

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
			phys := grid.grid_physical_row(g, p.cursor.row)
			if phys >= 0 && phys < len(g.rows) {
				g.rows[phys].wrap = false
			}
			if p.cursor.row == p.scroll_bottom {
				erase_c, erase_dc := _parser_erase_cell(p)
				_parser_scroll_up(p, g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else if p.cursor.row < g.row_count - 1 {
				p.cursor.row += 1
			}
			p.cursor.pending_wrap = false
			_parser_mark_prompt_row(p, g)
		case '\t': // Tab - advance to the next programmed stop
			p.cursor.col = _parser_next_tab_stop(p, g.col_count, p.cursor.col)
			p.cursor.pending_wrap = false
		case 0x08: // Backspace
			p.cursor.col = max(0, p.cursor.col - 1)
			p.cursor.pending_wrap = false
		case 0x07: // BEL
			// Bell ignored in core
		case 0x0E: // SO - lock shift G1 into GL
			p.gl = 1
		case 0x0F: // SI - lock shift G0 into GL
			p.gl = 0
		case 0x20..=0x7E: // Printable ASCII Fast Path
			if _parser_graphics_active(p) {
				ch, _ := _parser_map_gl_byte(p, b)
				if ch != 0 do _parser_put_char(p, g, d, ch)
			} else {
				_parser_put_char(p, g, d, rune(b))
			}
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
				p.csi_sep[i] = 0
			}
		case ']':
			p.state = .Osc_String
			clear(&p.osc_buf)
			p.osc_overflow = false
		case '(':
			p.esc_charset_slot = 0
			p.state = .Esc_Charset
		case ')':
			p.esc_charset_slot = 1
			p.state = .Esc_Charset
		case '*':
			p.esc_charset_slot = 2
			p.state = .Esc_Charset
		case '+':
			p.esc_charset_slot = 3
			p.state = .Esc_Charset
		case '-':
			p.esc_charset_slot = 1
			p.state = .Esc_Charset
		case '.':
			p.esc_charset_slot = 2
			p.state = .Esc_Charset
		case '/':
			p.esc_charset_slot = 3
			p.state = .Esc_Charset
		case 'N': // SS2 - single shift G2 for the next character
			p.gl_single = 2
			p.state = .Ground
		case 'O': // SS3 - single shift G3 for the next character
			p.gl_single = 3
			p.state = .Ground
		case 'n': // LS2 - lock shift G2 into GL
			p.gl = 2
			p.state = .Ground
		case 'o': // LS3 - lock shift G3 into GL
			p.gl = 3
			p.state = .Ground
		case 'H': // HTS - horizontal tab set at the cursor column
			if p.cursor.col >= 0 && p.cursor.col < len(p.tab_stops) {
				p.tab_stops[p.cursor.col] = true
			}
			p.state = .Ground
		case 'D': // IND - index (down one line, keep column)
			if p.cursor.row == p.scroll_bottom {
				erase_c, erase_dc := _parser_erase_cell(p)
				_parser_scroll_up(p, g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else if p.cursor.row < g.row_count - 1 {
				p.cursor.row += 1
			}
			p.cursor.pending_wrap = false
			_parser_mark_prompt_row(p, g)
			p.state = .Ground
		case 'E': // NEL - next line (CR + IND)
			p.cursor.col = 0
			if p.cursor.row == p.scroll_bottom {
				erase_c, erase_dc := _parser_erase_cell(p)
				_parser_scroll_up(p, g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else if p.cursor.row < g.row_count - 1 {
				p.cursor.row += 1
			}
			p.cursor.pending_wrap = false
			_parser_mark_prompt_row(p, g)
			p.state = .Ground
		case 'P': // DCS - Device Control String
			p.state = .Dcs_String
			clear(&p.dcs_buf)
			p.dcs_overflow = false
		case '_': // APC - Application Program Command
			p.state = .Apc_String
			clear(&p.apc_buf)
		case '^', 'X': // PM / SOS
			p.state = .Dcs_String
		case 'M': // Reverse Index (scroll down if at top margin)
			if p.cursor.row == p.scroll_top {
				erase_c, erase_dc := _parser_erase_cell(p)
				_parser_scroll_down(p, g, d, p.scroll_top, p.scroll_bottom, 1, erase_c, erase_dc)
			} else {
				p.cursor.row = max(0, p.cursor.row - 1)
			}
			p.state = .Ground
		case 'c': // RIS - Reset to Initial State
			parser_reset(p, g.row_count, g.col_count)
			grid.grid_clear_all(g, d)
			grid.grid_clear_history(g)
			if p.on_clear != nil do p.on_clear(p.user_data, 3)
			p.state = .Ground
		case '7': // Save Cursor
			p.cursor.saved_row = p.cursor.row
			p.cursor.saved_col = p.cursor.col
			p.cursor.saved_origin_mode = p.origin_mode
			p.cursor.saved_autowrap = p.autowrap
			p.state = .Ground
		case '8': // Restore Cursor
			p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
			p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
			p.origin_mode = p.cursor.saved_origin_mode
			p.autowrap = p.cursor.saved_autowrap
			p.cursor.pending_wrap = false
			p.state = .Ground
		case '=', '>': // DECKPAM / DECKPNM
			p.keypad_app = b == '='
			p.state = .Ground
		case:
			p.state = .Ground
		}

	case .Esc_Charset:
		// ISO 2022 designator: 'B' US-ASCII, '0' DEC Special Graphics, 'A' UK,
		// 'U' Null. Anything else keeps the slot unchanged.
		if p.esc_charset_slot < 4 {
			switch b {
			case CHARSET_ASCII, CHARSET_DEC_ACS, CHARSET_UK, CHARSET_NULL:
				p.charsets[p.esc_charset_slot] = b
			}
		}
		p.state = .Ground

	case .Dcs_String:
		if b == 0x07 { // BEL terminates DCS
			_parser_dispatch_dcs(p)
			p.state = .Ground
		} else if b == 0x1B {
			p.state = .Esc_In_Dcs
		} else if len(p.dcs_buf) < MAX_DCS_BUFFER {
			append(&p.dcs_buf, b)
		} else {
			p.dcs_overflow = true
		}

	case .Esc_In_Dcs:
		if b == '\\' { // String Terminator (ST)
			_parser_dispatch_dcs(p)
			p.state = .Ground
		} else if b == 0x1B {
			// Stay in Esc_In_Dcs
		} else {
			p.state = .Ground
			clear(&p.dcs_buf)
			p.dcs_overflow = false
		}

	case .Apc_String:
		if b == 0x07 { // BEL terminates APC
			_parser_dispatch_apc(p)
			p.state = .Ground
		} else if b == 0x1B {
			p.state = .Esc_In_Apc
		} else if len(p.apc_buf) < MAX_APC_BUFFER {
			append(&p.apc_buf, b)
		} else {
			p.apc_overflow = true
		}

	case .Esc_In_Apc:
		if b == '\\' { // ST
			_parser_dispatch_apc(p)
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
			p.csi_sep[0] = b
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
				p.csi_sep[p.csi_count - 1] = b
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
			_parser_dispatch_osc(p, g, d)
			p.state = .Ground
		} else if b == 0x1B { // ESC inside OSC might be ST (ESC \)
			p.state = .Esc_In_Osc
		} else if len(p.osc_buf) < MAX_OSC_BUFFER {
			append(&p.osc_buf, b)
		} else {
			p.osc_overflow = true
		}

	case .Esc_In_Osc:
		if b == '\\' { // String Terminator (ST)
			_parser_dispatch_osc(p, g, d)
			p.state = .Ground
		} else {
			// Aborted OSC sequence
			p.state = .Ground
			clear(&p.osc_buf)
			p.osc_overflow = false
		}
	}
}

_parser_abort_sequence :: proc(p: ^Parser) {
	clear(&p.osc_buf)
	clear(&p.apc_buf)
	clear(&p.dcs_buf)
	p.osc_overflow, p.apc_overflow, p.dcs_overflow = false, false, false
	p.utf8_state, p.utf8_len = 0, 0
	p.state = .Ground
}

parser_parse_bytes :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, data: []u8) {
	if p == nil || len(data) == 0 do return

	i := 0
	for i < len(data) {
		// Printable ASCII runs in Ground state go to the grid as whole runs.
		if p.state == .Ground && p.utf8_state == 0 && !_parser_graphics_active(p) {
			start := i
			for i < len(data) && data[i] >= 0x20 && data[i] <= 0x7E do i += 1
			if i > start {
				_parser_print_ascii(p, g, d, data[start:i])
				continue
			}
		}

		parser_parse_byte(p, g, d, data[i])
		i += 1
	}
}

_parser_scroll_up :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, top, bottom, n: int, fill: cell.Semantic_Cell, dc: cell.Direct_Color) -> int {
	scrolled := grid.grid_scroll_up(g, d, top, bottom, n, fill, dc)
	if scrolled > 0 && p.on_scroll != nil {
		p.on_scroll(p.user_data, scrolled, top, bottom)
	}
	return scrolled
}

_parser_scroll_down :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, top, bottom, n: int, fill: cell.Semantic_Cell, dc: cell.Direct_Color) -> int {
	scrolled := grid.grid_scroll_down(g, d, top, bottom, n, fill, dc)
	if scrolled > 0 && p.on_scroll != nil {
		p.on_scroll(p.user_data, -scrolled, top, bottom)
	}
	return scrolled
}

parser_scroll_up :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, n: int) -> int {
	if p == nil || g == nil || n <= 0 do return 0
	erase_c, erase_dc := _parser_erase_cell(p)
	return _parser_scroll_up(p, g, d, p.scroll_top, p.scroll_bottom, n, erase_c, erase_dc)
}

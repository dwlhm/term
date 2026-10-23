package terminal_parser

import "core:fmt"
import "core:strconv"
import cell "../cell"
import damage "../damage"
import grid "../grid"

// Sgr_Extended_Color is the resolved result of an ECMA-48 extended colour
// introducer (38/48/58) in either `;` or `:` (ITU T.416) syntax.
Sgr_Extended_Color :: struct {
	has_rgb:     bool,
	rgb:         [3]u8,
	has_palette: bool,
	palette:     u8,
}

// _sgr_read_extended consumes the parameters of an extended colour specifier.
// The colon form carries an optional colour-space identifier before RGB values
// (`38:2:<cs>:<r>:<g>:<b>`), which the semicolon form does not.
_sgr_read_extended :: proc(p: ^Parser, idx: ^int, colon_syntax: bool) -> (color: Sgr_Extended_Color, ok: bool) {
	i := idx^
	if i >= p.csi_count do return {}, false

	mode := p.csi_params[i]
	i += 1
	switch mode {
	case 5: // indexed palette entry
		if i >= p.csi_count do return {}, false
		value := p.csi_params[i]
		i += 1
		if value < 0 || value > 255 do return {}, false
		idx^ = i
		return Sgr_Extended_Color{has_palette = true, palette = u8(value)}, true
	case 2: // 24-bit RGB
		if colon_syntax && p.csi_count - i >= 4 {
			i += 1 // skip the ITU T.416 colour-space identifier
		}
		if p.csi_count - i < 3 do return {}, false
		color.has_rgb = true
		color.rgb = [3]u8{
			u8(clamp(p.csi_params[i], 0, 255)),
			u8(clamp(p.csi_params[i + 1], 0, 255)),
			u8(clamp(p.csi_params[i + 2], 0, 255)),
		}
		idx^ = i + 3
		return color, true
	}
	return {}, false
}

_parser_handle_csi :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, cmd: u8) {
	if g == nil do return

	param0 := p.csi_params[0] if p.csi_count > 0 && p.csi_params[0] > 0 else 1

	switch cmd {
	case 'A': // CUU - Cursor Up
		min_row := p.scroll_top if (p.origin_mode || p.cursor.row >= p.scroll_top) else 0
		p.cursor.row = max(min_row, p.cursor.row - param0)
		p.cursor.pending_wrap = false

	case 'B': // CUD - Cursor Down
		max_row := p.scroll_bottom if (p.origin_mode || p.cursor.row <= p.scroll_bottom) else g.row_count - 1
		p.cursor.row = min(max_row, p.cursor.row + param0)
		p.cursor.pending_wrap = false

	case 'C': // CUF - Cursor Forward
		p.cursor.col = min(g.col_count - 1, p.cursor.col + param0)
		p.cursor.pending_wrap = false

	case 'D': // CUB - Cursor Back
		p.cursor.col = max(0, p.cursor.col - param0)
		p.cursor.pending_wrap = false

	case 'H', 'f': // CUP - Cursor Position
		r := 1
		c := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do r = p.csi_params[0]
		if p.csi_count >= 2 && p.csi_params[1] > 0 do c = p.csi_params[1]
		if p.origin_mode {
			top := p.scroll_top
			bot := p.scroll_bottom
			p.cursor.row = clamp(top + r - 1, top, bot)
		} else {
			p.cursor.row = clamp(r - 1, 0, g.row_count - 1)
		}
		p.cursor.col = clamp(c - 1, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'I': // CHT - Cursor Forward Tabulation
		for _ in 0..<param0 {
			p.cursor.col = _parser_next_tab_stop(p, g.col_count, p.cursor.col)
		}
		p.cursor.pending_wrap = false

	case 'Z': // CBT - Cursor Backward Tabulation
		for _ in 0..<param0 {
			target := 0
			c := p.cursor.col - 1
			for c >= 1 {
				if c < len(p.tab_stops) && p.tab_stops[c] {
					target = c
					break
				}
				c -= 1
			}
			p.cursor.col = target
		}
		p.cursor.pending_wrap = false

	case 'G': // CHA - Cursor Horizontal Absolute (1-indexed)
		c := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do c = p.csi_params[0]
		p.cursor.col = clamp(c - 1, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'd': // VPA - Line Position Absolute (1-indexed)
		r := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do r = p.csi_params[0]
		if p.origin_mode {
			top := p.scroll_top
			bot := p.scroll_bottom
			p.cursor.row = clamp(top + r - 1, top, bot)
		} else {
			p.cursor.row = clamp(r - 1, 0, g.row_count - 1)
		}
		p.cursor.pending_wrap = false

	case 'E': // CNL - Cursor Next Line
		p.cursor.row = clamp(p.cursor.row + param0, 0, g.row_count - 1)
		p.cursor.col = 0
		p.cursor.pending_wrap = false

	case 'F': // CPL - Cursor Previous Line
		p.cursor.row = clamp(p.cursor.row - param0, 0, g.row_count - 1)
		p.cursor.col = 0
		p.cursor.pending_wrap = false

	case 'J': // ED - Erase in Display (BCE aware)
		mode := p.csi_params[0] if p.csi_count > 0 else 0
		erase_c, erase_dc := _parser_erase_cell(p)
		switch mode {
		case 0: // Erase below
			grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, g.col_count, erase_c, erase_dc)
			for r in (p.cursor.row + 1)..<g.row_count {
				grid.grid_clear_line(g, d, r, 0, g.col_count, erase_c, erase_dc)
			}
		case 1: // Erase above
			for r in 0..<p.cursor.row {
				grid.grid_clear_line(g, d, r, 0, g.col_count, erase_c, erase_dc)
			}
			grid.grid_clear_line(g, d, p.cursor.row, 0, p.cursor.col + 1, erase_c, erase_dc)
		case 2, 3: // Erase all
			grid.grid_clear_all(g, d, erase_c, erase_dc)
			if mode == 3 do grid.grid_clear_history(g)
			if p.on_clear != nil do p.on_clear(p.user_data, mode)
		}

	case 'K': // EL - Erase in Line (BCE aware)
		mode := p.csi_params[0] if p.csi_count > 0 else 0
		erase_c, erase_dc := _parser_erase_cell(p)
		switch mode {
		case 0: // Erase to right
			grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, g.col_count, erase_c, erase_dc)
		case 1: // Erase to left
			grid.grid_clear_line(g, d, p.cursor.row, 0, p.cursor.col + 1, erase_c, erase_dc)
		case 2: // Erase entire line
			grid.grid_clear_line(g, d, p.cursor.row, 0, g.col_count, erase_c, erase_dc)
		}

	case 'X': // ECH - Erase Character (BCE aware)
		count := min(param0, g.col_count - p.cursor.col)
		if count > 0 {
			_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col)
			_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col + count)
			erase_c, erase_dc := _parser_erase_cell(p)
			grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, p.cursor.col + count, erase_c, erase_dc)
		}

	case 'L': // IL - Insert Lines (BCE aware)
		erase_c, erase_dc := _parser_erase_cell(p)
		_parser_scroll_down(p, g, d, p.cursor.row, p.scroll_bottom, param0, erase_c, erase_dc)

	case 'M': // DL - Delete Lines (BCE aware)
		erase_c, erase_dc := _parser_erase_cell(p)
		_parser_scroll_up(p, g, d, p.cursor.row, p.scroll_bottom, param0, erase_c, erase_dc)

	case 'S': // SU - Scroll Up
		erase_c, erase_dc := _parser_erase_cell(p)
		_parser_scroll_up(p, g, d, p.scroll_top, p.scroll_bottom, param0, erase_c, erase_dc)

	case 'T': // SD - Scroll Down
		erase_c, erase_dc := _parser_erase_cell(p)
		_parser_scroll_down(p, g, d, p.scroll_top, p.scroll_bottom, param0, erase_c, erase_dc)

	case 'P': // DCH - Delete Characters (BCE aware)
		count := min(param0, g.col_count - p.cursor.col)
		for c in p.cursor.col..<(g.col_count - count) {
			src := grid.grid_get_cell(g, p.cursor.row, c + count)
			src_dc := grid.grid_get_direct_color(g, p.cursor.row, c + count)
			grid.grid_set_cell(g, d, p.cursor.row, c, src, src_dc)
		}
		erase_c, erase_dc := _parser_erase_cell(p)
		grid.grid_clear_line(g, d, p.cursor.row, g.col_count - count, g.col_count, erase_c, erase_dc)

	case '@': // ICH - Insert Characters (BCE aware)
		count := min(param0, g.col_count - p.cursor.col)
		for c := g.col_count - 1; c >= p.cursor.col + count; c -= 1 {
			src := grid.grid_get_cell(g, p.cursor.row, c - count)
			src_dc := grid.grid_get_direct_color(g, p.cursor.row, c - count)
			grid.grid_set_cell(g, d, p.cursor.row, c, src, src_dc)
		}
		erase_c, erase_dc := _parser_erase_cell(p)
		grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, p.cursor.col + count, erase_c, erase_dc)

	case 'm': // SGR - Styling & Color Attributes
		// Private-prefixed forms are NOT SGR: `CSI > 4 ; 1 m` is xterm's
		// XTMODKEYS (keyboard options), which clients such as OpenCode emit on
		// startup. Treating its parameters as attributes would leave the whole
		// screen underlined/bold.
		if p.csi_prefix != 0 do return

		if p.csi_count == 0 {
			p.cursor.active_fg = 7
			p.cursor.active_bg = 0
			p.cursor.active_style = {}
			p.cursor.active_flags = {}
			p.cursor.direct_color = {}
			return
		}

		idx := 0
		for idx < p.csi_count {
			code := p.csi_params[idx]
			idx += 1
			switch code {
			case 0: // Reset
				p.cursor.active_fg = 7
				p.cursor.active_bg = 0
				p.cursor.active_style = {}
				p.cursor.active_flags = {}
				p.cursor.direct_color = {}
			case 1: p.cursor.active_style += {.Bold}
			case 2: p.cursor.active_style += {.Dim}
			case 3: p.cursor.active_style += {.Italic}
			case 7: p.cursor.active_style += {.Invert}
			case 9: p.cursor.active_style += {.Strike}
			case 22: p.cursor.active_style -= {.Bold, .Dim}
			case 23: p.cursor.active_style -= {.Italic}
			case 24: p.cursor.active_style -= {.Underline}
			case 27: p.cursor.active_style -= {.Invert}
			case 29: p.cursor.active_style -= {.Strike}
			case 30..=37: // Standard FG (0..7)
				p.cursor.active_fg = u8(code - 30)
				p.cursor.direct_color.has_fg = false
				if !p.cursor.direct_color.has_bg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 39: // Default FG
				p.cursor.active_fg = 7
				p.cursor.direct_color.has_fg = false
				if !p.cursor.direct_color.has_bg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 40..=47: // Standard BG (0..7)
				p.cursor.active_bg = u8(code - 40)
				p.cursor.direct_color.has_bg = false
				if !p.cursor.direct_color.has_fg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 49: // Default BG
				p.cursor.active_bg = 0
				p.cursor.direct_color.has_bg = false
				if !p.cursor.direct_color.has_fg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 90..=97: // Bright FG (8..15)
				p.cursor.active_fg = u8(code - 90 + 8)
				p.cursor.direct_color.has_fg = false
				if !p.cursor.direct_color.has_bg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 100..=107: // Bright BG (8..15)
				p.cursor.active_bg = u8(code - 100 + 8)
				p.cursor.direct_color.has_bg = false
				if !p.cursor.direct_color.has_fg {
					p.cursor.active_flags -= {.Has_Direct_Color}
				}
			case 38: // Extended FG (256 colour or TrueColor), ';' or ':' syntax
				colon := idx >= 1 && p.csi_sep[idx - 1] == ':'
				if color, ok := _sgr_read_extended(p, &idx, colon); ok {
					p.cursor.direct_color.has_fg = false
					p.cursor.active_flags -= {.Has_Direct_Color}
					if color.has_rgb {
						p.cursor.direct_color.fg = color.rgb
						p.cursor.direct_color.has_fg = true
						p.cursor.active_flags += {.Has_Direct_Color}
					} else if color.has_palette {
						p.cursor.active_fg = color.palette
					}
					if !p.cursor.direct_color.has_bg do p.cursor.active_flags -= {.Has_Direct_Color}
					if p.cursor.direct_color.has_fg || p.cursor.direct_color.has_bg {
						p.cursor.active_flags += {.Has_Direct_Color}
					}
				}
			case 48: // Extended BG
				colon := idx >= 1 && p.csi_sep[idx - 1] == ':'
				if color, ok := _sgr_read_extended(p, &idx, colon); ok {
					p.cursor.direct_color.has_bg = false
					if color.has_rgb {
						p.cursor.direct_color.bg = color.rgb
						p.cursor.direct_color.has_bg = true
					} else if color.has_palette {
						p.cursor.active_bg = color.palette
					}
					if !p.cursor.direct_color.has_fg do p.cursor.active_flags -= {.Has_Direct_Color}
					if p.cursor.direct_color.has_fg || p.cursor.direct_color.has_bg {
						p.cursor.active_flags += {.Has_Direct_Color}
					}
				}
			case 58: // Underline colour (consumed; decoration colour is not yet rendered)
				colon := idx >= 1 && p.csi_sep[idx - 1] == ':'
				_, _ = _sgr_read_extended(p, &idx, colon)
			case 59: // Default underline colour
			case 4: // Underline, optionally with a colon sub-parameter (4:0..4:5)
				if idx >= 1 && p.csi_sep[idx - 1] == ':' {
					style := p.csi_params[idx] if idx < p.csi_count else 1
					idx += 1
					if style == 0 {
						p.cursor.active_style -= {.Underline}
					} else {
						p.cursor.active_style += {.Underline}
					}
				} else {
					p.cursor.active_style += {.Underline}
				}
			case 5: // Blink (slow)
				p.cursor.active_style += {.Blink}
			case 6: // Rapid blink, folded into the same flag
				p.cursor.active_style += {.Blink}
			case 8: // Conceal
				p.cursor.active_style += {.Hidden}
			case 21: // Double underline, folded into the underline flag
				p.cursor.active_style += {.Underline}
			case 25: // No blink
				p.cursor.active_style -= {.Blink}
			case 28: // Reveal
				p.cursor.active_style -= {.Hidden}
			case 53, 55: // Overline set/reset (no dedicated cell bit available)
			}
		}

	case 'b': // REP - Repeat the preceding graphic character
		if p.last_print > 0 {
			for _ in 0..<param0 do _parser_put_char(p, g, d, p.last_print)
		}

	case 'g': // TBC - Tab Clear
		mode := p.csi_params[0] if p.csi_count > 0 else 0
		switch mode {
		case 0: // clear the stop at the cursor
			if p.cursor.col >= 0 && p.cursor.col < len(p.tab_stops) {
				p.tab_stops[p.cursor.col] = false
			}
		case 3: // clear every stop
			for i in 0..<len(p.tab_stops) do p.tab_stops[i] = false
		}

	case 'p': // DECRQM / DECSTR, distinguished by the prefix and intermediate
		if p.csi_intermediate == '!' {
			_parser_soft_reset(p, g)
		} else if p.csi_intermediate == '$' {
			_parser_report_mode(p, p.csi_params[0] if p.csi_count > 0 else 0)
		}

	case 'r': // DECSTBM - Set Top and Bottom Margins
		t := 1
		b := g.row_count
		if p.csi_count >= 1 && p.csi_params[0] > 0 do t = p.csi_params[0]
		if p.csi_count >= 2 && p.csi_params[1] > 0 do b = p.csi_params[1]
		if t < b && b <= g.row_count {
			p.scroll_top = t - 1
			p.scroll_bottom = b - 1
			p.cursor.row = p.scroll_top if p.origin_mode else 0
			p.cursor.col = 0
			p.cursor.pending_wrap = false
		}

	case 's': // SCOSC - Save Cursor Position
		p.cursor.saved_row = p.cursor.row
		p.cursor.saved_col = p.cursor.col
		p.cursor.saved_origin_mode = p.origin_mode
		p.cursor.saved_autowrap = p.autowrap

	case 'u': // KitKat keyboard protocol (prefixed) or SCORC - Restore Cursor
		switch p.csi_prefix {
		case '>': // push flags onto the stack
			flags := p.csi_params[0] if p.csi_count > 0 else 0
			parser_kitty_keyboard_push(p, u8(clamp(flags, 0, 255)))
		case '<': // pop n entries
			count := p.csi_params[0] if p.csi_count > 0 else 1
			parser_kitty_keyboard_pop(p, max(1, count))
		case '=': // set flags with mode 1=set, 2=or, 3=and-not
			flags := p.csi_params[0] if p.csi_count > 0 else 0
			mode := p.csi_params[1] if p.csi_count > 1 else 1
			parser_kitty_keyboard_set(p, u8(clamp(flags, 0, 255)), mode)
		case '?': // query the current flags
			buf: [16]u8
			resp := fmt.bprintf(buf[:], "\x1b[?%d u", parser_kitty_keyboard_flags(p))
			parser_emit_response(p, transmute([]u8)resp)
		case:
			p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
			p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
			p.origin_mode = p.cursor.saved_origin_mode
			p.autowrap = p.cursor.saved_autowrap
			p.cursor.pending_wrap = false
		}

	case 'h': // SM - Set Mode
		if p.csi_prefix == '?' {
			for idx in 0..<p.csi_count {
				mode := p.csi_params[idx]
				switch mode {
				case 1:
					p.cursor_key_mode = true
				case 6:
					p.origin_mode = true
					p.cursor.row = p.scroll_top
					p.cursor.col = 0
					p.cursor.pending_wrap = false
				case 7:
					p.autowrap = true
				case 9:
					p.mouse_mode = .X10
				case 25:
					p.cursor.visible = true
				case 47, 1047, 1049:
					if !p.in_alt_screen {
						if mode == 1049 {
							p.cursor.saved_row = p.cursor.row
							p.cursor.saved_col = p.cursor.col
						}
						p.in_alt_screen = true
						p.cursor.pending_wrap = false
						if p.on_alt_screen != nil do p.on_alt_screen(p.user_data, true, mode)
					}
				case 1000:
					p.mouse_mode = .Normal
				case 1002:
					p.mouse_mode = .Button_Event
				case 1003:
					p.mouse_mode = .Any_Event
				case 1004:
					p.report_focus = true
				case 1006:
					p.mouse_format = .Sgr
				case 1007:
					p.alternate_scroll_mode = true
				case 1016:
					p.mouse_format = .Sgr_Pixel
				case 2004:
					p.bracketed_paste = true
				case 2026:
					p.sync_output = true
				}
			}
		}

	case 'l': // RM - Reset Mode
		if p.csi_prefix == '?' {
			for idx in 0..<p.csi_count {
				mode := p.csi_params[idx]
				switch mode {
				case 1:
					p.cursor_key_mode = false
				case 6:
					p.origin_mode = false
					p.cursor.row = 0
					p.cursor.col = 0
					p.cursor.pending_wrap = false
				case 7:
					p.autowrap = false
				case 9, 1000, 1002, 1003:
					p.mouse_mode = .None
				case 25:
					p.cursor.visible = false
				case 47, 1047, 1049:
					if p.in_alt_screen {
						if p.on_alt_screen != nil do p.on_alt_screen(p.user_data, false, mode)
						p.in_alt_screen = false
						if mode == 1049 {
							p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
							p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
						}
						p.cursor.pending_wrap = false
					}
				case 1004:
					p.report_focus = false
				case 1007:
					p.alternate_scroll_mode = false
				case 1006, 1016:
					p.mouse_format = .X10
				case 2004:
					p.bracketed_paste = false
				case 2026:
					p.sync_output = false
				}
			}
		}

	case 'q': // DECSCUSR or XTVERSION
		if p.csi_prefix == '>' {
			parser_emit_response(p, []u8{0x1b, 'P', '>', '|', 't', 'e', 'r', 'm', '(', '0', '.', '1', '.', '0', ')', 0x1b, '\\'})
		} else if p.csi_intermediate == ' ' {
			mode := p.csi_params[0] if p.csi_count > 0 else 0
			switch mode {
			case 0, 1:
				p.cursor.shape = .Block
				p.cursor.blinking = true
			case 2:
				p.cursor.shape = .Block
				p.cursor.blinking = false
			case 3:
				p.cursor.shape = .Underline
				p.cursor.blinking = true
			case 4:
				p.cursor.shape = .Underline
				p.cursor.blinking = false
			case 5:
				p.cursor.shape = .Beam
				p.cursor.blinking = true
			case 6:
				p.cursor.shape = .Beam
				p.cursor.blinking = false
			}
		}

	case 'n': // DSR - Device Status Report
		param0_val := p.csi_params[0] if p.csi_count > 0 else 0
		if p.csi_prefix == 0 {
			switch param0_val {
			case 5: // Status report -> \x1b[0n (OK)
				parser_emit_response(p, []u8{0x1b, '[', '0', 'n'})
			case 6: // Cursor position report (CPR) -> \x1b[<row>;<col>R (1-indexed)
				buf: [32]u8
				r_buf: [16]u8
				c_buf: [16]u8
				r_str := strconv.write_int(r_buf[:], i64(p.cursor.row + 1), 10)
				c_str := strconv.write_int(c_buf[:], i64(p.cursor.col + 1), 10)
				buf[0] = 0x1b
				buf[1] = '['
				copy(buf[2:], r_str)
				r_len := len(r_str)
				buf[2 + r_len] = ';'
				copy(buf[3 + r_len:], c_str)
				c_len := len(c_str)
				buf[3 + r_len + c_len] = 'R'
				parser_emit_response(p, buf[:4 + r_len + c_len])
			}
		}

	case 'c': // DA - Device Attributes
		if p.csi_prefix == 0 {
			// Primary DA: VT220
			parser_emit_response(p, []u8{0x1b, '[', '?', '6', '2', ';', 'c'})
		} else if p.csi_prefix == '>' {
			// Secondary DA
			parser_emit_response(p, []u8{0x1b, '[', '>', '0', ';', '1', '0', ';', '1', 'c'})
		}

	case 't': // XTWINOPS - Window and cell pixel manipulation & reports
		if p.csi_prefix == 0 && p.csi_count > 0 {
			buf: [32]u8
			switch p.csi_params[0] {
			case 14: // Query window size in pixels -> \e[4;<height>;<width>t
				cw := p.cell_w if p.cell_w > 0 else 10
				ch := p.cell_h if p.cell_h > 0 else 20
				resp := fmt.bprintf(buf[:], "\x1b[4;%d;%dt", g.row_count * ch, g.col_count * cw)
				parser_emit_response(p, transmute([]u8)resp)
			case 16: // Query cell size in pixels -> \e[6;<height>;<width>t
				cw := p.cell_w if p.cell_w > 0 else 10
				ch := p.cell_h if p.cell_h > 0 else 20
				resp := fmt.bprintf(buf[:], "\x1b[6;%d;%dt", ch, cw)
				parser_emit_response(p, transmute([]u8)resp)
			case 18: // Query window size in characters -> \e[8;<rows>;<cols>t
				resp := fmt.bprintf(buf[:], "\x1b[8;%d;%dt", g.row_count, g.col_count)
				parser_emit_response(p, transmute([]u8)resp)
			}
		}

	case:
		// Dispatch unhandled custom CSI to callback
		if p.on_csi != nil {
			p.on_csi(p.user_data, rune(cmd), p.csi_params[:p.csi_count])
		}
	}
}

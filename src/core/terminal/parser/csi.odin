package terminal_parser

import "core:fmt"
import "core:strconv"
import cell "../cell"
import damage "../damage"
import grid "../grid"

_parser_handle_csi :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, cmd: u8) {
	if g == nil do return

	param0 := p.csi_params[0] if p.csi_count > 0 && p.csi_params[0] > 0 else 1

	switch cmd {
	case 'A': // CUU - Cursor Up
		p.cursor.row = max(p.scroll_top, p.cursor.row - param0)
		p.cursor.pending_wrap = false

	case 'B': // CUD - Cursor Down
		p.cursor.row = min(p.scroll_bottom, p.cursor.row + param0)
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
		p.cursor.row = clamp(r - 1, 0, g.row_count - 1)
		p.cursor.col = clamp(c - 1, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'G': // CHA - Cursor Horizontal Absolute (1-indexed)
		c := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do c = p.csi_params[0]
		p.cursor.col = clamp(c - 1, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'd': // VPA - Line Position Absolute (1-indexed)
		r := 1
		if p.csi_count >= 1 && p.csi_params[0] > 0 do r = p.csi_params[0]
		p.cursor.row = clamp(r - 1, 0, g.row_count - 1)
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
			case 4: p.cursor.active_style += {.Underline}
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
			case 38: // Extended FG (256 color or TrueColor)
				if idx < p.csi_count && p.csi_params[idx] == 5 {
					// 38;5;<color>
					idx += 1
					if idx < p.csi_count {
						p.cursor.active_fg = u8(p.csi_params[idx] & 0xFF)
						p.cursor.direct_color.has_fg = false
						if !p.cursor.direct_color.has_bg {
							p.cursor.active_flags -= {.Has_Direct_Color}
						}
						idx += 1
					}
				} else if idx < p.csi_count && p.csi_params[idx] == 2 {
					// 38;2;<r>;<g>;<b> (TrueColor)
					idx += 1
					if idx + 2 < p.csi_count {
						p.cursor.direct_color.fg = [3]u8{
							u8(p.csi_params[idx] & 0xFF),
							u8(p.csi_params[idx + 1] & 0xFF),
							u8(p.csi_params[idx + 2] & 0xFF),
						}
						p.cursor.direct_color.has_fg = true
						p.cursor.active_flags += {.Has_Direct_Color}
						idx += 3
					}
				}
			case 48: // Extended BG
				if idx < p.csi_count && p.csi_params[idx] == 5 {
					idx += 1
					if idx < p.csi_count {
						p.cursor.active_bg = u8(p.csi_params[idx] & 0xFF)
						p.cursor.direct_color.has_bg = false
						if !p.cursor.direct_color.has_fg {
							p.cursor.active_flags -= {.Has_Direct_Color}
						}
						idx += 1
					}
				} else if idx < p.csi_count && p.csi_params[idx] == 2 {
					idx += 1
					if idx + 2 < p.csi_count {
						p.cursor.direct_color.bg = [3]u8{
							u8(p.csi_params[idx] & 0xFF),
							u8(p.csi_params[idx + 1] & 0xFF),
							u8(p.csi_params[idx + 2] & 0xFF),
						}
						p.cursor.direct_color.has_bg = true
						p.cursor.active_flags += {.Has_Direct_Color}
						idx += 3
					}
				}
			}
		}

	case 'r': // DECSTBM - Set Top and Bottom Margins
		t := 1
		b := g.row_count
		if p.csi_count >= 1 && p.csi_params[0] > 0 do t = p.csi_params[0]
		if p.csi_count >= 2 && p.csi_params[1] > 0 do b = p.csi_params[1]
		if t < b && b <= g.row_count {
			p.scroll_top = t - 1
			p.scroll_bottom = b - 1
			p.cursor.row = p.scroll_top
			p.cursor.col = 0
			p.cursor.pending_wrap = false
		}

	case 's': // SCOSC - Save Cursor Position
		p.cursor.saved_row = p.cursor.row
		p.cursor.saved_col = p.cursor.col

	case 'u': // SCOSC - Restore Cursor Position
		p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
		p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
		p.cursor.pending_wrap = false

	case 'h': // SM - Set Mode
		if p.csi_prefix == '?' {
			for idx in 0..<p.csi_count {
				mode := p.csi_params[idx]
				switch mode {
				case 1:
					p.cursor_key_mode = true
				case 9:
					p.mouse_mode = .X10
				case 25:
					p.cursor.visible = true
				case 47, 1047, 1049:
					p.in_alt_screen = true
					if mode == 1049 {
						p.cursor.saved_row = p.cursor.row
						p.cursor.saved_col = p.cursor.col
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
				case 9, 1000, 1002, 1003:
					p.mouse_mode = .None
				case 25:
					p.cursor.visible = false
				case 47, 1047, 1049:
					p.in_alt_screen = false
					if mode == 1049 {
						p.cursor.row = clamp(p.cursor.saved_row, 0, g.row_count - 1)
						p.cursor.col = clamp(p.cursor.saved_col, 0, g.col_count - 1)
					}
				case 1004:
					p.report_focus = false
				case 1007:
					p.alternate_scroll_mode = false
				case 1006, 1016:
					p.mouse_format = .X10
				case 2004:
					p.bracketed_paste = false
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

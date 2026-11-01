package core_terminal

import cell "cell"
import grid "grid"
import parser "parser"

// _paint_state restores everything but the cells, after the cells are written
// (painting needs autowrap on, no margins and ASCII charsets). Order matters:
// DECSTBM and DECOM home the cursor, so the cursor goes last but one; charsets
// come after the last printed glyph.
_paint_state :: proc(t: ^Terminal, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	p := &t.parser
	_paint_tab_stops(t, out)
	_paint_saved_cursor(p, out)
	if p.scroll_top != 0 || p.scroll_bottom != t.rows - 1 {
		_paint_csi_int(out, "", p.scroll_top + 1, ";")
		_paint_int(out, p.scroll_bottom + 1)
		_paint_str(out, "r")
	}
	_paint_dec_mode(out, 6, p.origin_mode)
	_paint_dec_mode(out, 7, p.autowrap)
	_paint_cursor(t, out, pen)
	_paint_set_pen(t, out, pen, _paint_active_pen(p))
	_paint_input_modes(p, out)
	_paint_cursor_style(p, out)
	_paint_charsets(p, out)
	if t.title_len > 0 {
		_paint_str(out, "\x1b]2;")
		append(out, ..t.title_buf[:t.title_len])
		_paint_str(out, "\x1b\\")
	}
}

_paint_tab_stops :: proc(t: ^Terminal, out: ^[dynamic]u8) {
	p := &t.parser
	is_default := true
	for stop, i in p.tab_stops {
		if stop != (i % 8 == 0) {
			is_default = false
			break
		}
	}
	if is_default do return
	_paint_str(out, "\x1b[3g")
	for stop, i in p.tab_stops {
		if !stop || i >= t.cols do continue
		_paint_cup(out, 1, i + 1)
		_paint_str(out, "\x1bH")
	}
}

// _paint_saved_cursor rebuilds the DECSC slot (shared with mode 1049): the
// position plus the DECOM/DECAWM state it captured.
_paint_saved_cursor :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	_paint_dec_mode(out, 6, p.cursor.saved_origin_mode)
	_paint_dec_mode(out, 7, p.cursor.saved_autowrap)
	_paint_cup(out, p.cursor.saved_row + 1, p.cursor.saved_col + 1)
	_paint_str(out, "\x1b7")
}

// _paint_cursor positions the cursor. A pending wrap (cursor parked past the
// last column) can only be recreated by printing that last glyph again.
_paint_cursor :: proc(t: ^Terminal, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	p := &t.parser
	row := p.cursor.row - p.scroll_top if p.origin_mode else p.cursor.row
	col := p.cursor.col
	g_row := grid.grid_get_row(&t.grid, p.cursor.row)
	if !p.cursor.pending_wrap || !p.autowrap || g_row == nil || col >= len(g_row.cells) {
		_paint_cup(out, row + 1, col + 1)
		return
	}
	if col > 0 && .Wide_Continuation in g_row.cells[col].flags do col -= 1
	_paint_cup(out, row + 1, col + 1)
	_paint_cell(t, g_row, col, out, pen)
}

_paint_active_pen :: proc(p: ^parser.Parser) -> Paint_Pen {
	flags := p.cursor.active_flags
	if p.cursor.direct_color.has_fg || p.cursor.direct_color.has_bg do flags += {.Has_Direct_Color}
	if p.active_link != 0 do flags += {.Has_Hyperlink}
	dc := p.cursor.direct_color
	dc.link_id = p.active_link
	sc := cell.Semantic_Cell{fg = p.cursor.active_fg, bg = p.cursor.active_bg, style = p.cursor.active_style, flags = flags}
	return _paint_pen_of_cell(sc, dc)
}

@(rodata)
MOUSE_MODE_NUMBERS := [parser.Mouse_Tracking_Mode]int {
	.None         = 0,
	.X10          = 9,
	.Normal       = 1000,
	.Button_Event = 1002,
	.Any_Event    = 1003,
}

@(rodata)
MOUSE_FORMAT_NUMBERS := [parser.Mouse_Format]int {
	.X10       = 0,
	.Sgr       = 1006,
	.Sgr_Pixel = 1016,
}

// _paint_input_modes restores the modes that change what the viewer sends back.
// The preamble switched all of them off, so only the active ones are written.
_paint_input_modes :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	if p.cursor_key_mode do _paint_dec_mode(out, 1, true)
	if p.keypad_app do _paint_str(out, "\x1b=")
	if p.bracketed_paste do _paint_dec_mode(out, 2004, true)
	if p.report_focus do _paint_dec_mode(out, 1004, true)
	if p.alternate_scroll_mode do _paint_dec_mode(out, 1007, true)
	if p.mouse_mode != .None do _paint_dec_mode(out, MOUSE_MODE_NUMBERS[p.mouse_mode], true)
	if p.mouse_format != .X10 do _paint_dec_mode(out, MOUSE_FORMAT_NUMBERS[p.mouse_format], true)
	for i in 0 ..< int(p.kbd_depth) do _paint_csi_int(out, ">", int(p.kbd_flags[i]), "u")
}

_paint_cursor_style :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	code: int
	switch p.cursor.shape {
	case .Block:     code = 1
	case .Underline: code = 3
	case .Beam:      code = 5
	}
	if !p.cursor.blinking do code += 1
	_paint_csi_int(out, "", code, " q")
	if !p.cursor.visible do _paint_dec_mode(out, 25, false)
}

@(rodata)
CHARSET_SLOT_INTRODUCERS := [4]u8{'(', ')', '*', '+'}

_paint_charsets :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	for set, slot in p.charsets {
		if set == parser.CHARSET_ASCII do continue
		append(out, u8(0x1b), CHARSET_SLOT_INTRODUCERS[slot], set)
	}
	switch p.gl {
	case 1: _paint_str(out, "\x0e")
	case 2: _paint_str(out, "\x1bn")
	case 3: _paint_str(out, "\x1bo")
	}
	switch p.gl_single {
	case 2: _paint_str(out, "\x1bN")
	case 3: _paint_str(out, "\x1bO")
	}
}

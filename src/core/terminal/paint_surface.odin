package core_terminal

import cell "cell"
import grid "grid"
import parser "parser"

_paint_surface_vt :: proc(t: ^Terminal, g: ^grid.Grid, p: ^parser.Parser, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	_paint_dec_mode(out, 6, p.cursor.saved_origin_mode)
	_paint_dec_mode(out, 7, p.cursor.saved_autowrap)
	_paint_cup(out, p.cursor.saved_row + 1, p.cursor.saved_col + 1)
	_paint_str(out, "\x1b7")
	if p.scroll_top != 0 || p.scroll_bottom != g.row_count - 1 {
		_paint_csi_int(out, "", p.scroll_top + 1, ";")
		_paint_int(out, p.scroll_bottom + 1)
		_paint_str(out, "r")
	}
	if p.declrmm {
		_paint_dec_mode(out, 69, true)
		if p.scroll_left != 0 || p.scroll_right != g.col_count - 1 {
			_paint_csi_int(out, "", p.scroll_left + 1, ";")
			_paint_int(out, p.scroll_right + 1)
			_paint_str(out, "s")
		}
	}
	_paint_dec_mode(out, 6, p.origin_mode)
	_paint_dec_mode(out, 7, p.autowrap)
	_paint_surface_cursor(t, g, p, out, pen)
}

_paint_surface_cursor :: proc(t: ^Terminal, g: ^grid.Grid, p: ^parser.Parser, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	row := p.cursor.row - p.scroll_top if p.origin_mode else p.cursor.row
	left_base := p.scroll_left if (p.origin_mode && p.declrmm) else 0
	col := p.cursor.col
	g_row := grid.grid_get_row(g, p.cursor.row)
	right_col := p.scroll_right if (p.declrmm && col <= p.scroll_right) else len(g_row.cells) - 1 if g_row != nil else 0
	if !p.cursor.pending_wrap || !p.autowrap || g_row == nil || col >= len(g_row.cells) || col != right_col {
		_paint_cup(out, row + 1, col - left_base + 1)
		return
	}
	if col > 0 && .Wide_Continuation in g_row.cells[col].flags do col -= 1
	_paint_cup(out, row + 1, col - left_base + 1)
	_paint_cell(t, g_row, col, out, pen)
}

_paint_vt_pen :: proc(t: ^Terminal, p: ^parser.Parser) -> Paint_Pen {
	flags := p.cursor.active_flags
	if p.cursor.direct_color.has_fg || p.cursor.direct_color.has_bg do flags += {.Has_Direct_Color}
	if p.active_link != 0 do flags += {.Has_Hyperlink}
	dc := p.cursor.direct_color
	dc.link_id = p.active_link
	sc := cell.Semantic_Cell{
		fg    = p.cursor.active_fg,
		bg    = p.cursor.active_bg,
		style = p.cursor.active_style,
		flags = flags,
	}
	return _paint_pen_of_cell(sc, dc)
}

_paint_surfaces_splits_init :: proc(t: ^Terminal, out: ^[dynamic]u8) {
	if len(t.surfaces) == 0 do return
	for i in 0 ..< len(t.surfaces) {
		s := &t.surfaces[i]
		if s.kind != .Split do continue
		_paint_str(out, "\x1b]8400;2;")
		_paint_int(out, int(s.id))
		_paint_str(out, ";")
		_paint_int(out, int(s.parent_id))
		_paint_str(out, ";")
		_paint_int(out, int(s.split_dir))
		_paint_str(out, ";")
		_paint_int(out, s.split_ratio)
		_paint_str(out, ";0\x1b\\")
		if !s.visible {
			_paint_str(out, "\x1b]8400;5;")
			_paint_int(out, int(s.id))
			_paint_str(out, ";0\x1b\\")
		}
	}
	_paint_str(out, "\x1b]8400;1;0\x07\x1b[H")
}

_paint_popup_init :: proc(s: ^Terminal_Surface, out: ^[dynamic]u8) {
	_paint_str(out, "\x1b]8400;3;")
	_paint_int(out, int(s.id))
	_paint_str(out, ";")
	_paint_int(out, s.req_w)
	_paint_str(out, ";")
	_paint_int(out, s.req_h)
	_paint_str(out, ";")
	_paint_int(out, int(s.anchor))
	_paint_str(out, ";")
	_paint_int(out, s.req_x)
	_paint_str(out, ";")
	_paint_int(out, s.req_y)
	_paint_str(out, ";")
	_paint_int(out, s.z)
	_paint_str(out, ";")
	_paint_int(out, int(s.chrome))
	_paint_str(out, ";0;")
	if s.title_len > 0 {
		_paint_base64(out, s.title_buf[:s.title_len])
	}
	_paint_str(out, "\x1b\\")
	if !s.visible {
		_paint_str(out, "\x1b]8400;5;")
		_paint_int(out, int(s.id))
		_paint_str(out, ";0\x1b\\")
	}
}

_paint_surfaces_content :: proc(t: ^Terminal, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	if len(t.surfaces) == 0 do return
	for i in 0 ..< len(t.surfaces) {
		s := &t.surfaces[i]
		if s.kind == .Popup do _paint_popup_init(s, out)
		_paint_str(out, "\x1b]8400;1;")
		_paint_int(out, int(s.id))
		_paint_str(out, "\x07\x1b[H")
		_paint_set_pen(t, out, pen, PAINT_PEN_DEFAULT)
		_paint_lines(t, &s.grid, 0, s.grid.row_count, out, pen)
		_paint_surface_vt(t, &s.grid, &s.parser, out, pen)
		_paint_set_pen(t, out, pen, _paint_vt_pen(t, &s.parser))
		_paint_input_modes(&s.parser, out)
		_paint_cursor_style(&s.parser, out)
		_paint_charsets(&s.parser, out)
	}
	if t.focused_surface_id != 0 {
		_paint_str(out, "\x1b]8400;4;")
		_paint_int(out, int(t.focused_surface_id))
		_paint_str(out, "\x1b\\")
	}
	_paint_str(out, "\x1b]8400;1;")
	_paint_int(out, int(t.active_surface_id))
	_paint_str(out, "\x07")
	_, _, active_p := terminal_surface_parts(t, t.active_surface_id)
	_paint_set_pen(t, out, pen, _paint_vt_pen(t, active_p))
}

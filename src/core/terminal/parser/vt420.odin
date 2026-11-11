package terminal_parser

// VT420 / VT520 Left-Right Margin Mode (DECLRMM ?69, DECSLRM) and Rectangular
// Area Operations (DECCRA, DECFRA, DECERA, DECSERA).

import cell "../cell"
import damage "../damage"
import grid "../grid"

// _parser_eff_left returns the active 0-based left margin column.
_parser_eff_left :: #force_inline proc(p: ^Parser) -> int {
	return p.scroll_left if p.declrmm else 0
}

// _parser_eff_right returns the active 0-based right margin column.
_parser_eff_right :: #force_inline proc(p: ^Parser, g: ^grid.Grid) -> int {
	if g == nil do return 0
	if p.declrmm && p.scroll_right < g.col_count {
		return p.scroll_right
	}
	return max(0, g.col_count - 1)
}

// _parser_in_h_margins reports whether the cursor column sits inside the
// active horizontal scroll margins.
_parser_in_h_margins :: #force_inline proc(p: ^Parser, g: ^grid.Grid) -> bool {
	if !p.declrmm do return true
	return p.cursor.col >= p.scroll_left && p.cursor.col <= _parser_eff_right(p, g)
}

// _parser_cr_col returns the target column for CR / NEL / CNL / CPL.
// Per VT420: when inside or to the right of the left margin (or in DECOM),
// carriage return moves to the left margin; to the left of the margin it goes to 0.
_parser_cr_col :: #force_inline proc(p: ^Parser) -> int {
	if p.declrmm && (p.origin_mode || p.cursor.col >= p.scroll_left) {
		return p.scroll_left
	}
	return 0
}

// _parser_page_bounds returns the addressable origin `(row_base, col_base)` and
// dimensions `(page_h, page_w)` taking DECOM (`?6`) and DECLRMM (`?69`) into account.
_parser_page_bounds :: proc(p: ^Parser, g: ^grid.Grid) -> (row_base, col_base, page_h, page_w: int) {
	if g == nil do return 0, 0, 0, 0
	if p.origin_mode {
		row_base = p.scroll_top
		col_base = _parser_eff_left(p)
		page_h = max(1, p.scroll_bottom - p.scroll_top + 1)
		page_w = max(1, _parser_eff_right(p, g) - col_base + 1)
		return
	}
	return 0, 0, g.row_count, g.col_count
}

// _parser_rect_bounds resolves 1-based `(Pt, Pl, Pb, Pr)` starting at
// `p.csi_params[offset]` into 0-based inclusive grid coordinates `(r0, r1, c0, c1)`.
_parser_rect_bounds :: proc(p: ^Parser, g: ^grid.Grid, offset: int) -> (r0, r1, c0, c1: int, valid: bool) {
	row_base, col_base, page_h, page_w := _parser_page_bounds(p, g)
	if page_h <= 0 || page_w <= 0 do return 0, 0, 0, 0, false

	top := p.csi_params[offset] if p.csi_count > offset && p.csi_params[offset] > 0 else 1
	left := p.csi_params[offset + 1] if p.csi_count > offset + 1 && p.csi_params[offset + 1] > 0 else 1
	bottom := p.csi_params[offset + 2] if p.csi_count > offset + 2 && p.csi_params[offset + 2] > 0 else page_h
	right := p.csi_params[offset + 3] if p.csi_count > offset + 3 && p.csi_params[offset + 3] > 0 else page_w

	if top > bottom || left > right do return 0, 0, 0, 0, false
	if top > page_h || left > page_w || bottom < 1 || right < 1 do return 0, 0, 0, 0, false

	r0 = row_base + clamp(top, 1, page_h) - 1
	r1 = row_base + clamp(bottom, 1, page_h) - 1
	c0 = col_base + clamp(left, 1, page_w) - 1
	c1 = col_base + clamp(right, 1, page_w) - 1
	return r0, r1, c0, c1, true
}

// _parser_handle_decslrm implements DECSLRM (`CSI Pl ; Pr s`) when DECLRMM (`?69`) is active.
_parser_handle_decslrm :: proc(p: ^Parser, g: ^grid.Grid) {
	if g == nil do return
	l := 1
	r := g.col_count
	if p.csi_count >= 1 && p.csi_params[0] > 0 do l = p.csi_params[0]
	if p.csi_count >= 2 && p.csi_params[1] > 0 do r = p.csi_params[1]
	if l < r && r <= g.col_count {
		p.scroll_left = l - 1
		p.scroll_right = r - 1
		p.cursor.row = p.scroll_top if p.origin_mode else 0
		p.cursor.col = _parser_eff_left(p) if p.origin_mode else 0
		p.cursor.pending_wrap = false
	}
}

// _parser_handle_deccra implements DECCRA (`CSI Pts;Pls;Pbs;Prs;Pps;Ptd;Pld;Ppd $ v`).
_parser_handle_deccra :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	r0, r1, c0, c1, ok := _parser_rect_bounds(p, g, 0)
	if !ok do return

	row_base, col_base, page_h, page_w := _parser_page_bounds(p, g)
	ptd := p.csi_params[5] if p.csi_count > 5 && p.csi_params[5] > 0 else 1
	pld := p.csi_params[6] if p.csi_count > 6 && p.csi_params[6] > 0 else 1
	if ptd > page_h || pld > page_w do return

	dst_r := row_base + ptd - 1
	dst_c := col_base + pld - 1
	max_r := row_base + page_h - 1
	max_c := col_base + page_w - 1
	eff_r1 := min(r1, r0 + (max_r - dst_r))
	eff_c1 := min(c1, c0 + (max_c - dst_c))
	grid.grid_copy_rect(g, d, r0, c0, eff_r1, eff_c1, dst_r, dst_c)
}

// _parser_handle_decfra implements DECFRA (`CSI Pch ; Pt ; Pl ; Pb ; Pr $ x`).
_parser_handle_decfra :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	if p.csi_count < 1 do return
	pch := p.csi_params[0]
	// VT420: only GL (0x20..0x7E) or GR (0xA0..0xFF) graphic characters are valid.
	if !((pch >= 0x20 && pch <= 0x7E) || (pch >= 0xA0 && pch <= 0xFF)) do return
	r0, r1, c0, c1, ok := _parser_rect_bounds(p, g, 1)
	if !ok do return

	ch := rune(pch)
	if pch >= 0x20 && pch <= 0x7E && _parser_graphics_active(p) {
		if mapped, m_ok := _parser_map_gl_byte(p, u8(pch)); m_ok && mapped != 0 {
			ch = mapped
		}
	}
	base_c := cell.cell_make(ch, p.cursor.active_fg, p.cursor.active_bg, p.cursor.active_style, p.cursor.active_flags)
	fill_c, fill_dc := _parser_apply_link(p, base_c, p.cursor.direct_color)
	grid.grid_fill_rect(g, d, r0, c0, r1, c1, fill_c, fill_dc)
}

// _parser_handle_decera implements DECERA (`CSI Pt ; Pl ; Pb ; Pr $ z`).
_parser_handle_decera :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	r0, r1, c0, c1, ok := _parser_rect_bounds(p, g, 0)
	if !ok do return
	erase_c, erase_dc := _parser_erase_cell(p)
	grid.grid_fill_rect(g, d, r0, c0, r1, c1, erase_c, erase_dc)
}

// _parser_handle_decsera implements DECSERA (`CSI Pt ; Pl ; Pb ; Pr $ {`).
_parser_handle_decsera :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker) {
	r0, r1, c0, c1, ok := _parser_rect_bounds(p, g, 0)
	if !ok do return
	grid.grid_selective_erase_rect(g, d, r0, c0, r1, c1)
}

// _parser_dch implements DCH (`CSI P`) bounded by active horizontal margins.
_parser_dch :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, param0: int) {
	if !_parser_in_h_margins(p, g) do return
	right_limit := _parser_eff_right(p, g) + 1
	count := min(param0, right_limit - p.cursor.col)
	if count <= 0 do return
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col)
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col + count)
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, right_limit)
	for c in p.cursor.col ..< (right_limit - count) {
		src := grid.grid_get_cell(g, p.cursor.row, c + count)
		src_dc := grid.grid_get_direct_color(g, p.cursor.row, c + count)
		grid.grid_set_cell(g, d, p.cursor.row, c, src, src_dc)
	}
	erase_c, erase_dc := _parser_erase_cell(p)
	grid.grid_clear_line(g, d, p.cursor.row, right_limit - count, right_limit, erase_c, erase_dc)
}

// _parser_ich implements ICH (`CSI @`) bounded by active horizontal margins.
_parser_ich :: proc(p: ^Parser, g: ^grid.Grid, d: ^damage.Damage_Tracker, param0: int) {
	if !_parser_in_h_margins(p, g) do return
	right_limit := _parser_eff_right(p, g) + 1
	count := min(param0, right_limit - p.cursor.col)
	if count <= 0 do return
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, p.cursor.col)
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, right_limit - count)
	_parser_sanitize_wide_boundary(g, d, p.cursor.row, right_limit)
	for c := right_limit - 1; c >= p.cursor.col + count; c -= 1 {
		src := grid.grid_get_cell(g, p.cursor.row, c - count)
		src_dc := grid.grid_get_direct_color(g, p.cursor.row, c - count)
		grid.grid_set_cell(g, d, p.cursor.row, c, src, src_dc)
	}
	erase_c, erase_dc := _parser_erase_cell(p)
	grid.grid_clear_line(g, d, p.cursor.row, p.cursor.col, p.cursor.col + count, erase_c, erase_dc)
}

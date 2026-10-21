package terminal_kitty

import contract "../../contract"
import core_terminal "../../../terminal"
import grid "../../../terminal/grid"
import ext "../../../terminal/extension"

Kitty_Draw_Batch :: struct {
	gpu_group:      rawptr,
	start_instance: int,
	instance_count: int,
	z_index:        int,
}

_kitty_cell_matches_image :: proc(
	term: ^core_terminal.Terminal,
	row: ^grid.Row,
	c: int,
	target_id: u32,
	active_count: int,
) -> bool {
	cell_val := row.cells[c]
	is_ph := cell_val.char == 0x10EEEE
	if !is_ph && .Has_Egc in cell_val.flags {
		if runes := core_terminal.terminal_get_egc_runes(term, cell_val.char); len(runes) > 0 {
			is_ph = (runes[0] == 0x10EEEE)
		}
	}
	if !is_ph do return false
	if active_count == 1 || target_id == 0 do return true

	if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) && row.direct_colors[c].has_fg {
		dc := row.direct_colors[c]
		color_id := (u32(dc.fg[0]) << 16) | (u32(dc.fg[1]) << 8) | u32(dc.fg[2])
		if color_id == target_id do return true
	}
	return u32(cell_val.fg) == target_id
}

_kitty_find_placeholders_for_image :: proc(
	term: ^core_terminal.Terminal,
	target_id: u32,
	active_count: int,
) -> (x, y, cols, rows: int, found: bool) {
	if term == nil do return 0, 0, 0, 0, false
	min_c, min_r, max_c, max_r := 9999, 9999, -1, -1

	for r_idx in 0..<term.rows {
		row := core_terminal.terminal_get_row(term, r_idx)
		if row == nil do continue
		for c in 0..<min(term.cols, len(row.cells)) {
			if _kitty_cell_matches_image(term, row, c, target_id, active_count) {
				if c < min_c do min_c = c
				if c > max_c do max_c = c
				if r_idx < min_r do min_r = r_idx
				if r_idx > max_r do max_r = r_idx
			}
		}
	}
	if max_c >= min_c && max_r >= min_r {
		return min_c, min_r, max_c - min_c + 1, max_r - min_r + 1, true
	}
	return 0, 0, 0, 0, false
}

_kitty_calc_placement_record :: proc(
	p: ^ext.Kitty_Placement,
	img: ^ext.Kitty_Image,
	pane_rect: [4]f32,
	cell_w, cell_h, pad_x, pad_y: f32,
	scroll_offset: int,
) -> contract.Instance_Record {
	u0: f32 = 0.0
	v0: f32 = 0.0
	u1: f32 = 1.0
	v1: f32 = 1.0

	if p.src_w > 0 && p.src_h > 0 && img.width > 0 && img.height > 0 {
		u0 = f32(p.src_x) / f32(img.width)
		v0 = f32(p.src_y) / f32(img.height)
		u1 = f32(p.src_x + p.src_w) / f32(img.width)
		v1 = f32(p.src_y + p.src_h) / f32(img.height)
	}

	qx := pane_rect[0] + pad_x + f32(p.x_col) * cell_w
	qy := pane_rect[1] + pad_y + f32(p.y_row + scroll_offset) * cell_h
	qw := f32(p.cols) * cell_w
	qh := f32(p.rows) * cell_h

	return contract.Instance_Record{
		pos_size = {qx, qy, qw, qh},
		uv_rect  = {u0, v0, u1, v1},
		fg_color = {1, 1, 1, 1},
		bg_color = {0, 0, 0, 0},
	}
}

_kitty_collect_placeholder_cells :: proc(
	r: ^Kitty_Renderer,
	img: ^ext.Kitty_Image,
	term: ^core_terminal.Terminal,
	pane_rect: [4]f32,
	cell_w, cell_h, pad_x, pad_y: f32,
	scroll_offset, active_count: int,
) {
	min_c, min_r, cols, rows, found := _kitty_find_placeholders_for_image(term, img.id, active_count)
	if !found || cols <= 0 || rows <= 0 do return

	cols_f := f32(cols)
	rows_f := f32(rows)

	for r_idx in min_r..<min_r + rows {
		row := core_terminal.terminal_get_row(term, r_idx)
		if row == nil do continue
		for c in min_c..<min_c + cols {
			if c >= len(row.cells) do continue
			if !_kitty_cell_matches_image(term, row, c, img.id, active_count) do continue

			u0 := f32(c - min_c) / cols_f
			u1 := f32(c - min_c + 1) / cols_f
			v0 := f32(r_idx - min_r) / rows_f
			v1 := f32(r_idx - min_r + 1) / rows_f

			qx := pane_rect[0] + pad_x + f32(c) * cell_w
			qy := pane_rect[1] + pad_y + f32(r_idx + scroll_offset) * cell_h

			append(&r.instance_data, contract.Instance_Record{
				pos_size = {qx, qy, cell_w, cell_h},
				uv_rect  = {u0, v0, u1, v1},
				fg_color = {1, 1, 1, 1},
				bg_color = {0, 0, 0, 0},
			})
		}
	}
}

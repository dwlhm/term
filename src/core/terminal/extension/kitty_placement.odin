package terminal_extension

Kitty_Placement :: struct {
	image_id:     u32,
	placement_id: u32,
	x_col, y_row: int,
	cols, rows:   int,
	src_x, src_y: int,
	src_w, src_h: int,
	z_index:      int,
	is_active:    bool,
}

_kitty_find_image :: proc(state: ^Kitty_Extension, img_id: u32) -> ^Kitty_Image {
	if state == nil do return nil
	for i in 0..<MAX_KITTY_IMAGES {
		img := &state.images[i]
		if (img_id > 0 && img.id == img_id) || (img_id == 0 && (img.is_active || img.id != 0)) {
			return img
		}
	}
	return nil
}

_kitty_calculate_span :: proc(
	state: ^Kitty_Extension,
	img: ^Kitty_Image,
	term: rawptr,
) -> (cols, rows: int) {
	cw, ch_px := 19, 43
	if state.cell_size_provider != nil && term != nil {
		pw, ph := state.cell_size_provider(term)
		if pw > 0 do cw, ch_px = pw, ph
	}
	ref_w := state.current_src_w if state.current_src_w > 0 else img.width
	ref_h := state.current_src_h if state.current_src_h > 0 else img.height
	if ref_w <= 0 do ref_w = 1
	if ref_h <= 0 do ref_h = 1

	req_c := state.current_cols if state.current_cols > 0 else img.cols
	req_r := state.current_rows if state.current_rows > 0 else img.rows

	if req_c > 0 && req_r > 0 {
		return req_c, req_r
	}

	aspect := f32(ref_w) / f32(ref_h)

	if req_c > 0 {
		h_px := (f32(req_c) * f32(cw)) / aspect
		rows = max(1, int((h_px + f32(ch_px) - 1.0) / f32(ch_px)))
		return req_c, rows
	}

	if req_r > 0 {
		w_px := (f32(req_r) * f32(ch_px)) * aspect
		cols = max(1, int((w_px + f32(cw) - 1.0) / f32(cw)))
		return cols, req_r
	}

	term_cols, term_rows := 0, 0
	if state.grid_size_provider != nil && term != nil {
		term_cols, term_rows = state.grid_size_provider(term)
	}

	raw_c := max(1, (ref_w + cw - 1) / cw)
	raw_r := max(1, (ref_h + ch_px - 1) / ch_px)

	if term_cols > 0 && term_rows > 0 && (raw_c > term_cols || raw_r > term_rows) {
		max_w_px := f32(term_cols) * f32(cw)
		max_h_px := f32(max(1, term_rows - 2)) * f32(ch_px)
		scale := min(1.0, min(max_w_px / f32(ref_w), max_h_px / f32(ref_h)))
		fit_w := f32(ref_w) * scale
		fit_h := f32(ref_h) * scale
		cols = max(1, int((fit_w + f32(cw) - 1.0) / f32(cw)))
		rows = max(1, int((fit_h + f32(ch_px) - 1.0) / f32(ch_px)))
		return cols, rows
	}

	return raw_c, raw_r
}

_kitty_handle_put :: proc(state: ^Kitty_Extension, term: rawptr, img_id: u32) {
	if state == nil do return
	img := _kitty_find_image(state, img_id)
	if img == nil do return

	if state.current_cols > 0 do img.cols = state.current_cols
	if state.current_rows > 0 do img.rows = state.current_rows
	if state.current_virtual == 1 do img.is_virtual = true

	img.is_active = true
	img.gpu_dirty = true
	if img.is_virtual do return

	cols, rows := _kitty_calculate_span(state, img, term)
	cur_r, cur_c := 0, 0
	if state.cursor_provider != nil && term != nil {
		cur_r, cur_c = state.cursor_provider(term)
	}

	slot_idx := -1
	for i in 0..<len(state.placements) {
		p := &state.placements[i]
		if p.is_active && p.image_id == img.id && p.placement_id == state.current_placement {
			slot_idx = i
			break
		}
		if slot_idx == -1 && !p.is_active do slot_idx = i
	}

	new_p := Kitty_Placement{
		image_id     = img.id,
		placement_id = state.current_placement,
		x_col        = cur_c,
		y_row        = cur_r,
		cols         = cols,
		rows         = rows,
		src_x        = state.current_src_x,
		src_y        = state.current_src_y,
		src_w        = state.current_src_w,
		src_h        = state.current_src_h,
		z_index      = state.current_z,
		is_active    = true,
	}

	if slot_idx >= 0 {
		state.placements[slot_idx] = new_p
	} else {
		append(&state.placements, new_p)
	}

	// Notify grid damage across rows occupied by image so compositor triggers render frame immediately
	if state.damage_notifier != nil && term != nil {
		state.damage_notifier(term, cur_r, rows)
	}

	// Advance cursor according to KGP cursor movement policy (C=0 default: advance, C=1: do not move)
	if state.current_cursor_move == 0 && state.cursor_advancer != nil && term != nil {
		state.cursor_advancer(term, cols, rows)
	}
}

_kitty_handle_clear_screen :: proc(state: ^Kitty_Extension, mode: int) {
	if state == nil do return
	if mode == 2 {
		// Clear visible screen: deactivate placements currently visible on screen (y_row >= 0)
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if p.is_active && p.y_row >= 0 {
				p.is_active = false
			}
		}
	} else if mode == 3 {
		// Clear visible screen AND scrollback history: deactivate all placements
		for i in 0..<len(state.placements) {
			state.placements[i].is_active = false
		}
	}
}

_kitty_handle_grid_scroll :: proc(state: ^Kitty_Extension, n: int, top, bottom: int) {
	if state == nil || n == 0 do return
	for i in 0..<len(state.placements) {
		p := &state.placements[i]
		if !p.is_active do continue
		if top == 0 {
			p.y_row -= n
		} else {
			if p.y_row >= top && p.y_row + p.rows <= bottom + 1 {
				p.y_row -= n
			}
		}
	}
}

_kitty_handle_resize :: proc(state: ^Kitty_Extension, new_rows, new_cols: int, delta_y: int, term: rawptr) {
	if state == nil do return
	if delta_y != 0 {
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if !p.is_active do continue
			p.y_row += delta_y
		}
	}
	if new_cols > 0 {
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if !p.is_active do continue
			if p.x_col + p.cols > new_cols {
				if p.cols <= new_cols {
					p.x_col = max(0, new_cols - p.cols)
				}
			}
		}
	}
}

_kitty_delete_image_slot :: proc(state: ^Kitty_Extension, img: ^Kitty_Image) {
	if len(img.pixels) > 0 {
		delete(img.pixels, state.allocator)
		img.pixels = nil
	}
	kitty_animation_destroy(&img.animation, state.allocator)
	img.gpu_dirty = true
	img.is_active = false
	img.id = 0
}

_kitty_handle_delete :: proc(
	state: ^Kitty_Extension,
	img_id: u32,
	del_mode: u8,
	p_id: u32,
	cur_col, cur_row, z: int,
) {
	if state == nil do return

	// 1. Purge all: d=a or d=A
	if del_mode == 'a' || del_mode == 'A' || (del_mode == 0 && img_id == 0) {
		for i in 0..<MAX_KITTY_IMAGES {
			img := &state.images[i]
			if img.id != 0 do _kitty_delete_image_slot(state, img)
		}
		clear(&state.placements)
		return
	}

	// 2. Delete single placement: d=p or d=P
	if del_mode == 'p' || del_mode == 'P' {
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if p.is_active && p.placement_id == p_id && (img_id == 0 || p.image_id == img_id) {
				p.is_active = false
			}
		}
		return
	}

	// 3. Delete at cursor cell: d=c or d=C
	if del_mode == 'c' || del_mode == 'C' {
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if !p.is_active do continue
			if cur_col >= p.x_col && cur_col < p.x_col + p.cols &&
			   cur_row >= p.y_row && cur_row < p.y_row + p.rows {
				p.is_active = false
			}
		}
		return
	}

	// 4. Delete by z-index: d=z or d=Z
	if del_mode == 'z' || del_mode == 'Z' {
		for i in 0..<len(state.placements) {
			p := &state.placements[i]
			if p.is_active && p.z_index == z do p.is_active = false
		}
		return
	}

	// 5. Delete image by ID: d=i or d=I (or default fallback)
	for i in 0..<MAX_KITTY_IMAGES {
		img := &state.images[i]
		if img.id == img_id && img.id != 0 {
			_kitty_delete_image_slot(state, img)
		}
	}
	for i in 0..<len(state.placements) {
		p := &state.placements[i]
		if p.is_active && p.image_id == img_id do p.is_active = false
	}
}

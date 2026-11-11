package core_terminal

import damage "damage"
import extension "extension"
import grid "grid"
import parser "parser"

_surface_compute_popup_rect :: proc(t: ^Terminal, s: ^Terminal_Surface) {
	w := clamp(s.req_w, 1, max(1, t.cols))
	h := clamp(s.req_h, 1, max(1, t.rows))
	col := 0
	row := 0
	switch s.anchor {
	case .Center:
		col = max(0, (t.cols - w) / 2)
		row = max(0, (t.rows - h) / 2)
	case .Absolute:
		col = clamp(max(0, s.req_x - 1), 0, max(0, t.cols - w))
		row = clamp(max(0, s.req_y - 1), 0, max(0, t.rows - h))
	case .Cursor:
		base_c := t.root_cell_rect[0] + t.parser.cursor.col + s.req_x
		base_r := t.root_cell_rect[1] + t.parser.cursor.row + 1 + s.req_y
		if base_r + h > t.rows && (t.root_cell_rect[1] + t.parser.cursor.row - h) >= 0 {
			base_r = t.root_cell_rect[1] + t.parser.cursor.row - h
		}
		col = clamp(base_c, 0, max(0, t.cols - w))
		row = clamp(base_r, 0, max(0, t.rows - h))
	}
	s.cell_rect = {col, row, w, h}
	inv_c := 1.0 / f32(max(1, t.cols))
	inv_r := 1.0 / f32(max(1, t.rows))
	s.norm_rect = {f32(col) * inv_c, f32(row) * inv_r, f32(w) * inv_c, f32(h) * inv_r}
}

_surface_carve_split :: proc(p_cell: ^[4]int, p_norm: ^[4]f32, s: ^Terminal_Surface) {
	ratio := clamp(s.split_ratio, 10, 90)
	frac := f32(ratio) / 100.0
	switch s.split_dir {
	case .Right, .Left:
		cw := max(1, (p_cell[2] * ratio) / 100)
		pw := max(1, p_cell[2] - cw)
		nw := p_norm[2] * frac
		if s.split_dir == .Right {
			s.cell_rect = {p_cell[0] + pw, p_cell[1], max(1, p_cell[2] - pw), p_cell[3]}
			s.norm_rect = {p_norm[0] + (p_norm[2] - nw), p_norm[1], nw, p_norm[3]}
		} else {
			s.cell_rect = {p_cell[0], p_cell[1], cw, p_cell[3]}
			s.norm_rect = {p_norm[0], p_norm[1], nw, p_norm[3]}
			p_cell[0] += cw
			p_norm[0] += nw
		}
		p_cell[2] = pw
		p_norm[2] -= nw
	case .Down, .Up:
		ch := max(1, (p_cell[3] * ratio) / 100)
		ph := max(1, p_cell[3] - ch)
		nh := p_norm[3] * frac
		if s.split_dir == .Down {
			s.cell_rect = {p_cell[0], p_cell[1] + ph, p_cell[2], max(1, p_cell[3] - ph)}
			s.norm_rect = {p_norm[0], p_norm[1] + (p_norm[3] - nh), p_norm[2], nh}
		} else {
			s.cell_rect = {p_cell[0], p_cell[1], p_cell[2], ch}
			s.norm_rect = {p_norm[0], p_norm[1], p_norm[2], nh}
			p_cell[1] += ch
			p_norm[1] += nh
		}
		p_cell[3] = ph
		p_norm[3] -= nh
	}
}

// terminal_surfaces_relayout recomputes default cell and normalized rectangles
// for Root and all child surfaces when running headless, resizing grids whose
// dimensions changed.
terminal_surfaces_relayout :: proc(t: ^Terminal, emit_events: bool = true) {
	if t == nil do return
	t.root_cell_rect = {0, 0, max(1, t.cols), max(1, t.rows)}
	t.root_norm_rect = {0, 0, 1, 1}
	for i in 0 ..< len(t.surfaces) {
		s := &t.surfaces[i]
		if !s.visible || s.kind != .Split do continue
		p_cell := &t.root_cell_rect
		p_norm := &t.root_norm_rect
		if s.parent_id != 0 {
			if ps := terminal_surface_find(t, s.parent_id); ps != nil && ps.visible && ps.kind == .Split {
				p_cell = &ps.cell_rect
				p_norm = &ps.norm_rect
			}
		}
		_surface_carve_split(p_cell, p_norm, s)
	}

	_ = terminal_surface_resize_grid(&t.grid, &t.damage, &t.parser, t.root_cell_rect[3], t.root_cell_rect[2])

	used := 0
	for i in 0 ..< len(t.surfaces) {
		s := &t.surfaces[i]
		if s.kind == .Popup do _surface_compute_popup_rect(t, s)
		if s.visible {
			_ = terminal_surface_resize_grid(&s.grid, &s.damage, &s.parser, s.cell_rect[3], s.cell_rect[2])
		}
		used += s.grid.row_count * s.grid.col_count
	}
	t.surface_cells_used = used
	t.surfaces_dirty = true
}

_surface_handle_split :: proc(t: ^Terminal, msg: ^extension.Osc_7502_Command) -> bool {
	if s := terminal_surface_find(t, msg.id); s != nil {
		if s.kind != .Split do return false
		s.parent_id = msg.parent
		s.split_dir = msg.split_dir
		s.split_ratio = clamp(msg.ratio, 10, 90)
		s.visible = true
		terminal_surfaces_relayout(t, true)
		if msg.focus {
			_ = terminal_surface_focus(t, msg.id)
			_ = terminal_surface_target(t, msg.id)
		}
		return true
	}
	if len(t.surfaces) >= MAX_SURFACES do return false
	est_cells := max(1, (t.cols * msg.ratio) / 100) * max(1, t.rows)
	if t.surface_cells_used + est_cells > MAX_SURFACE_CELL_BUDGET do return false
	if t.surfaces == nil do t.surfaces = make([dynamic]Terminal_Surface, 0, 8, t.allocator)
	append(&t.surfaces, Terminal_Surface{
		id          = msg.id,
		parent_id   = msg.parent,
		kind        = .Split,
		visible     = true,
		split_dir   = msg.split_dir,
		split_ratio = clamp(msg.ratio, 10, 90),
		cell_rect   = {0, 0, 1, 1},
	})
	idx := len(t.surfaces) - 1
	grid.grid_init(&t.surfaces[idx].grid, 1, 1, t.allocator)
	damage.damage_init(&t.surfaces[idx].damage, 1, 1, t.allocator)
	_surface_init_parser(t, &t.surfaces[idx], 1, 1)
	terminal_surfaces_relayout(t, true)
	if msg.focus {
		_ = terminal_surface_focus(t, msg.id)
		_ = terminal_surface_target(t, msg.id)
	}
	return true
}

_surface_handle_popup :: proc(t: ^Terminal, msg: ^extension.Osc_7502_Command) -> bool {
	w := clamp(msg.w, 1, max(1, t.cols))
	h := clamp(msg.h, 1, max(1, t.rows))
	if s := terminal_surface_find(t, msg.id); s != nil {
		if s.kind != .Popup do return false
		s.req_w, s.req_h, s.anchor, s.req_x, s.req_y = w, h, msg.anchor, msg.x, msg.y
		s.z, s.chrome, s.visible = msg.z, msg.chrome, true
		s.title_len = min(msg.title_len, len(s.title_buf))
		copy(s.title_buf[:s.title_len], msg.title_buf[:s.title_len])
		terminal_surfaces_relayout(t, true)
		if msg.focus {
			_ = terminal_surface_focus(t, msg.id)
			_ = terminal_surface_target(t, msg.id)
		}
		return true
	}
	if len(t.surfaces) >= MAX_SURFACES || t.surface_cells_used + w * h > MAX_SURFACE_CELL_BUDGET do return false
	if t.surfaces == nil do t.surfaces = make([dynamic]Terminal_Surface, 0, 8, t.allocator)
	surf := Terminal_Surface{
		id = msg.id, kind = .Popup, visible = true, anchor = msg.anchor,
		req_x = msg.x, req_y = msg.y, req_w = w, req_h = h,
		z = msg.z, chrome = msg.chrome,
	}
	surf.title_len = min(msg.title_len, len(surf.title_buf))
	copy(surf.title_buf[:surf.title_len], msg.title_buf[:surf.title_len])
	append(&t.surfaces, surf)
	idx := len(t.surfaces) - 1
	grid.grid_init(&t.surfaces[idx].grid, h, w, t.allocator)
	damage.damage_init(&t.surfaces[idx].damage, h, w, t.allocator)
	_surface_init_parser(t, &t.surfaces[idx], h, w)
	terminal_surfaces_relayout(t, true)
	if msg.focus {
		_ = terminal_surface_focus(t, msg.id)
		_ = terminal_surface_target(t, msg.id)
	}
	return true
}

terminal_surface_close :: proc(t: ^Terminal, id: u16) -> bool {
	if t == nil || id == 0 do return false
	idx := -1
	for i in 0 ..< len(t.surfaces) {
		if t.surfaces[i].id == id {
			idx = i
			break
		}
	}
	if idx < 0 do return false
	parent_id := t.surfaces[idx].parent_id
	if t.active_surface_id == id do _ = terminal_surface_target(t, 0)
	if t.focused_surface_id == id {
		t.focused_surface_id = 0
		t.focus_requested = true
	}
	for i in 0 ..< len(t.surfaces) {
		if t.surfaces[i].parent_id == id do t.surfaces[i].parent_id = parent_id
	}
	grid.grid_destroy(&t.surfaces[idx].grid)
	damage.damage_destroy(&t.surfaces[idx].damage)
	parser.parser_destroy(&t.surfaces[idx].parser)
	ordered_remove(&t.surfaces, idx)
	terminal_surfaces_relayout(t, true)
	return true
}

_terminal_handle_osc_7502 :: proc(t: ^Terminal, payload: string) -> bool {
	msg, ok := extension.osc_7502_parse(payload)
	if !ok do return false
	if msg.is_probe {
		return parser.parser_emit_response(&t.parser, transmute([]u8)string(OSC_7502_SUPPORTED))
	}
	#partial switch msg.op {
	case .Reset:
		terminal_surfaces_reset(t)
		return true
	case .Target:
		return terminal_surface_target(t, msg.id)
	case .Split:
		return _surface_handle_split(t, &msg)
	case .Popup:
		return _surface_handle_popup(t, &msg)
	case .Focus:
		return terminal_surface_focus(t, msg.id, false)
	case .Visibility:
		s := terminal_surface_find(t, msg.id)
		if s == nil do return false
		s.visible = msg.visible
		if !msg.visible && t.focused_surface_id == msg.id {
			t.focused_surface_id = 0
			t.focus_requested = true
		}
		terminal_surfaces_relayout(t, true)
		return true
	case .Close:
		return terminal_surface_close(t, msg.id)
	}
	return false
}

package core_terminal

import damage "damage"
import extension "extension"
import grid "grid"
import parser "parser"

MAX_SURFACES            :: 256
MAX_SURFACE_CELL_BUDGET :: 1_048_576
OSC_7502_SUPPORTED      :: "\x1b]7502;?1\x1b\\"

Surface_Kind :: enum u8 {
	Split,
	Popup,
}

// Terminal_Surface is an independent sub-surface (Split or Popup) owned by a
// single Terminal instance and addressed via OSC 7502. Each surface owns its
// own Grid, Damage_Tracker, Parser, and scroll offset.
Terminal_Surface :: struct {
	id:            u16,
	parent_id:     u16,
	kind:          Surface_Kind,
	visible:       bool,
	split_dir:     extension.Surface_Split_Dir,
	split_ratio:   int,
	anchor:        extension.Surface_Anchor,
	req_x:         int,
	req_y:         int,
	req_w:         int,
	req_h:         int,
	z:             int,
	chrome:        extension.Surface_Chrome,
	title_buf:     [128]u8,
	title_len:     int,
	cell_rect:     [4]int, // {col, row, cols, rows} in 0-indexed pane cells
	norm_rect:     [4]f32, // {x, y, w, h} normalized 0..1 within pane
	scroll_offset: int,
	grid:          grid.Grid,
	damage:        damage.Damage_Tracker,
	parser:        parser.Parser,
}

_surface_on_alt_screen :: proc(user_data: rawptr, enter: bool, mode: int) {
	if user_data == nil do return
	t := (^Terminal)(user_data)
	s := terminal_surface_find(t, t.active_surface_id)
	if !enter && (s == nil || !s.parser.in_alt_screen) {
		if t.parser.in_alt_screen {
			_terminal_on_alt_screen(user_data, false, mode)
			t.parser.in_alt_screen = false
			if mode == 1049 {
				t.parser.cursor.row = clamp(t.parser.cursor.saved_row, 0, t.grid.row_count - 1)
				t.parser.cursor.col = clamp(t.parser.cursor.saved_col, 0, t.grid.col_count - 1)
			}
			t.parser.cursor.pending_wrap = false
		}
		return
	}
	if s != nil {
		if mode != 47 {
			grid.grid_clear_all(&s.grid, &s.damage)
		}
		s.parser.scroll_top = 0
		s.parser.scroll_bottom = max(0, s.grid.row_count - 1)
		s.parser.scroll_left = 0
		s.parser.scroll_right = max(0, s.grid.col_count - 1)
		damage.damage_mark_all(&s.damage, 1)
	}
}

_surface_init_parser :: proc(t: ^Terminal, s: ^Terminal_Surface, rows, cols: int) {
	parser.parser_init(&s.parser, max(1, rows), max(1, cols))
	s.parser.egc_pool = &t.egc_pool
	s.parser.on_osc = _terminal_on_osc
	s.parser.on_csi = _terminal_on_csi
	s.parser.on_apc = _terminal_on_apc
	s.parser.on_dcs = _terminal_on_dcs
	s.parser.on_clear = _terminal_on_clear
	s.parser.on_scroll = _terminal_on_scroll
	s.parser.on_alt_screen = _surface_on_alt_screen
	s.parser.user_data = rawptr(t)
	s.parser.cell_w = t.parser.cell_w
	s.parser.cell_h = t.parser.cell_h
}

terminal_surface_resize_grid :: proc(g: ^grid.Grid, d: ^damage.Damage_Tracker, p: ^parser.Parser, new_rows, new_cols: int) -> bool {
	r := max(1, new_rows)
	c := max(1, new_cols)
	if g.row_count == r && g.col_count == c do return false
	disp := 0
	grid.grid_resize(g, d, r, c, &p.cursor.row, &p.cursor.col, &p.cursor.pending_wrap, &disp)
	p.cursor.row = clamp(p.cursor.row, 0, r - 1)
	p.cursor.col = clamp(p.cursor.col, 0, c - 1)
	p.cursor.saved_row = clamp(p.cursor.saved_row, 0, r - 1)
	p.cursor.saved_col = clamp(p.cursor.saved_col, 0, c - 1)
	p.scroll_top = clamp(p.scroll_top, 0, r - 1)
	p.scroll_bottom = max(0, r - 1)
	p.scroll_left = clamp(p.scroll_left, 0, c - 1)
	p.scroll_right = max(0, c - 1)
	return true
}

terminal_surface_find :: proc(t: ^Terminal, id: u16) -> ^Terminal_Surface {
	if t == nil || id == 0 do return nil
	for i in 0 ..< len(t.surfaces) {
		if t.surfaces[i].id == id do return &t.surfaces[i]
	}
	return nil
}

terminal_surface_parts :: proc(t: ^Terminal, id: u16) -> (^grid.Grid, ^damage.Damage_Tracker, ^parser.Parser) {
	if t == nil do return nil, nil, nil
	if id != 0 {
		if s := terminal_surface_find(t, id); s != nil {
			return &s.grid, &s.damage, &s.parser
		}
	}
	return &t.grid, &t.damage, &t.parser
}

terminal_surface_title :: proc(s: ^Terminal_Surface) -> string {
	if s == nil || s.title_len <= 0 do return ""
	return string(s.title_buf[:s.title_len])
}

// terminal_surface_target switches the active VT output target to surface `id` (`0` = Root).
terminal_surface_target :: proc(t: ^Terminal, id: u16) -> bool {
	if t == nil do return false
	if id != 0 && terminal_surface_find(t, id) == nil do return false
	t.active_surface_id = id
	return true
}

terminal_surface_focus :: proc(t: ^Terminal, id: u16, emit_event: bool = false) -> bool {
	if t == nil do return false
	if id != 0 {
		s := terminal_surface_find(t, id)
		if s == nil || !s.visible do return false
	}
	t.focused_surface_id = id
	t.focus_requested = true
	return true
}

terminal_surfaces_destroy :: proc(t: ^Terminal) {
	if t == nil do return
	for i in 0 ..< len(t.surfaces) {
		grid.grid_destroy(&t.surfaces[i].grid)
		damage.damage_destroy(&t.surfaces[i].damage)
		parser.parser_destroy(&t.surfaces[i].parser)
	}
	if t.surfaces != nil {
		delete(t.surfaces)
		t.surfaces = nil
	}
	t.surface_cells_used = 0
	t.active_surface_id = 0
	t.focused_surface_id = 0
	t.focus_requested = false
	t.surfaces_dirty = true
}

// terminal_surfaces_reset destroys all child surfaces and restores Root (0) to
// the full host pane dimensions.
terminal_surfaces_reset :: proc(t: ^Terminal) {
	if t == nil do return
	if len(t.surfaces) == 0 && t.active_surface_id == 0 && t.focused_surface_id == 0 {
		t.root_cell_rect = {0, 0, t.cols, t.rows}
		t.root_norm_rect = {0, 0, 1, 1}
		t.parser.active_grid = &t.grid
		t.parser.active_damage = &t.damage
		return
	}
	_ = terminal_surface_target(t, 0)
	for i in 0 ..< len(t.surfaces) {
		grid.grid_destroy(&t.surfaces[i].grid)
		damage.damage_destroy(&t.surfaces[i].damage)
		parser.parser_destroy(&t.surfaces[i].parser)
	}
	clear(&t.surfaces)
	t.surface_cells_used = 0
	t.focused_surface_id = 0
	t.focus_requested = true
	t.surfaces_dirty = true
	terminal_surfaces_relayout(t, false)
	t.parser.active_grid = &t.grid
	t.parser.active_damage = &t.damage
}

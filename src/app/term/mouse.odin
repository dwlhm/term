package term

// Dedicated Mouse Interaction, Selection & Wheel Scrolling Engine
// Part of Tier 3 Application Shell (src/app/term/*).

import "vendor:sdl3"

Cell_Pos :: struct {
	row: int,
	col: int,
}

Mouse_Selection :: struct {
	active:     bool,
	pane_id:    u32,
	start_cell: Cell_Pos,
	end_cell:   Cell_Pos,
}

Mouse_State :: struct {
	pos:           [2]f32,
	is_down:       bool,
	button:        u8,
	selection:     Mouse_Selection,
	cell_w:        f32,
	cell_h:        f32,
	pad_x:         f32,
	pad_y:         f32,
	// pending_* holds the origin of a mouse-down that has not yet moved
	// at least one cell. A selection is only committed (active = true) once
	// the pointer actually drags into a different cell, so that a plain
	// click in empty space does NOT create a zero-width highlight.
	pending_start: Cell_Pos,
	pending_pane:  u32,
	drag_started:  bool,
}

mouse_init :: proc(m: ^Mouse_State, cell_w, cell_h: f32, pad_x: f32 = 12.0, pad_y: f32 = 8.0) {
	if m == nil do return
	m.pos = {0.0, 0.0}
	m.is_down = false
	m.button = 0
	m.cell_w = max(1.0, cell_w)
	m.cell_h = max(1.0, cell_h)
	m.pad_x = pad_x
	m.pad_y = pad_y
	m.selection.active = false
	m.selection.pane_id = 0
	m.drag_started = false
}

mouse_on_button_down :: proc(
	m: ^Mouse_State,
	pos: [2]f32,
	button: u8,
	pane_id: u32,
	pane_rect: [4]f32,
	clicks: int = 1,
) {
	if m == nil do return
	m.pos = pos
	m.is_down = true
	m.button = button
	m.drag_started = false

	if button == sdl3.BUTTON_LEFT {
		cell_r, cell_c := mouse_pixel_to_cell(pos, pane_rect, m.cell_w, m.cell_h, m.pad_x, m.pad_y)
		// Clear any previous selection; we will only commit a new one on drag.
		m.selection.active = false
		m.pending_start = {cell_r, cell_c}
		m.pending_pane  = pane_id
	}
}

mouse_on_motion :: proc(m: ^Mouse_State, pos: [2]f32, pane_rect: [4]f32) {
	if m == nil do return
	m.pos = pos

	if m.is_down && m.button == sdl3.BUTTON_LEFT {
		cell_r, cell_c := mouse_pixel_to_cell(pos, pane_rect, m.cell_w, m.cell_h, m.pad_x, m.pad_y)

		if !m.drag_started {
			// Only start a drag when the pointer enters a different cell from
			// where the button was pressed.  This prevents accidental selection
			// when the user simply clicks (without moving) on empty space.
			if cell_r != m.pending_start.row || cell_c != m.pending_start.col {
				m.drag_started = true
				m.selection.active = true
				m.selection.pane_id = m.pending_pane
				m.selection.start_cell = m.pending_start
				m.selection.end_cell = {cell_r, cell_c}
			}
		} else {
			m.selection.end_cell = {cell_r, cell_c}
		}
	}
}

mouse_on_button_up :: proc(m: ^Mouse_State, button: u8) {
	if m == nil do return
	m.is_down = false
	m.drag_started = false

	// If start and end cell are identical (or no drag happened), cancel selection
	if m.selection.start_cell == m.selection.end_cell {
		m.selection.active = false
	}
}

mouse_clear_selection :: proc(m: ^Mouse_State) {
	if m == nil do return
	m.selection.active = false
	m.drag_started = false
}

mouse_pixel_to_cell :: proc(pos: [2]f32, pane_rect: [4]f32, cell_w, cell_h: f32, pad_x: f32 = 12.0, pad_y: f32 = 8.0) -> (row: int, col: int) {
	local_x := max(0.0, pos[0] - (pane_rect[0] + pad_x))
	local_y := max(0.0, pos[1] - (pane_rect[1] + pad_y))

	col = int(local_x / max(1.0, cell_w))
	row = int(local_y / max(1.0, cell_h))
	return row, col
}

mouse_is_in_rect :: proc(pos: [2]f32, rect: [4]f32) -> bool {
	return pos[0] >= rect[0] && pos[0] <= rect[0] + rect[2] &&
	       pos[1] >= rect[1] && pos[1] <= rect[1] + rect[3]
}

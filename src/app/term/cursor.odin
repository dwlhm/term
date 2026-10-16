package term

// Dedicated Terminal Cursor Shapes, Geometry & Smooth Blink Engine
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:math"

Cursor_Shape :: enum {
	Block,
	Beam,
	Underline,
}

Cursor_State :: struct {
	shape:       Cursor_Shape,
	blink_rate:  f32, // Hz
	is_visible:  bool,
}

cursor_init :: proc(c: ^Cursor_State) {
	if c == nil do return
	c.shape = .Block
	c.blink_rate = 1.0
	c.is_visible = true
}

// cursor_compute_rect calculates physical pixel rectangle of the cursor inside a pane card
cursor_compute_rect :: proc(
	col, row: int,
	pane_rect: [4]f32,
	cell_w, cell_h: f32,
	pad_x: f32 = 12.0,
	pad_y: f32 = 8.0,
	shape: Cursor_Shape = .Block,
) -> [4]f32 {
	base_x := pane_rect[0] + pad_x + f32(col) * cell_w
	base_y := pane_rect[1] + pad_y + f32(row) * cell_h

	switch shape {
	case .Block:
		return {base_x, base_y, cell_w, cell_h}
	case .Beam:
		return {base_x, base_y, 2.0, cell_h}
	case .Underline:
		return {base_x, base_y + cell_h - 2.0, cell_w, 2.0}
	}
	return {base_x, base_y, cell_w, cell_h}
}

// cursor_compute_opacity provides smooth sinusoidal 120Hz/60Hz blink
cursor_compute_opacity :: proc(time_elapsed: f32, is_focused: bool) -> f32 {
	if !is_focused do return 0.50

	// Sinusoidal blink between 0.25 and 1.0
	s := math.sin(time_elapsed * 5.0)
	if s >= 0.0 {
		return 0.85 + 0.15 * s
	} else {
		return 0.85 + 0.55 * s // Fades down smoothly
	}
}

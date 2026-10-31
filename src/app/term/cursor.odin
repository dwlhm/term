package term

// Dedicated Terminal Cursor Shapes, Geometry & Deadline-Driven Blink Engine
// Part of Tier 3 Application Shell (src/app/term/*).

CURSOR_BLINK_INTERVAL_NS: u64 : 500_000_000 // 500 ms per half-cycle (2 toggles/sec)

Cursor_Shape :: enum {
	Block,
	Beam,
	Underline,
}

Cursor_State :: struct {
	shape:         Cursor_Shape,
	blink_rate:    f32, // Hz
	is_visible:    bool,
	next_blink_ns: u64,
}

cursor_init :: proc(c: ^Cursor_State) {
	if c == nil do return
	c.shape = .Block
	c.blink_rate = 1.0
	c.is_visible = true
	c.next_blink_ns = 0
}

// cursor_reset_blink forces the cursor visible and pushes the next blink deadline
// forward by one full half-cycle (used on key input or PTY activity).
cursor_reset_blink :: proc(c: ^Cursor_State, now_ns: u64) {
	if c == nil do return
	c.is_visible = true
	c.next_blink_ns = now_ns + CURSOR_BLINK_INTERVAL_NS
}

// cursor_update_blink advances the discrete blink state against now_ns without drift.
// When active is false (window unfocused, cursor hidden, or steady cursor), resets
// to visible with deadline 0 (parked).
cursor_update_blink :: proc(c: ^Cursor_State, now_ns: u64, active: bool) -> (toggled: bool) {
	if c == nil do return false
	if !active {
		changed := !c.is_visible
		c.is_visible = true
		c.next_blink_ns = 0
		return changed
	}
	if c.next_blink_ns == 0 {
		c.is_visible = true
		c.next_blink_ns = now_ns + CURSOR_BLINK_INTERVAL_NS
		return false
	}
	if now_ns < c.next_blink_ns do return false
	c.is_visible = !c.is_visible
	for c.next_blink_ns <= now_ns {
		c.next_blink_ns += CURSOR_BLINK_INTERVAL_NS
	}
	return true
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

// cursor_compute_opacity returns discrete cursor opacity for focused/unfocused state.
cursor_compute_opacity :: proc(time_elapsed: f32, is_focused: bool) -> f32 {
	_ = time_elapsed
	if !is_focused do return 0.35
	return 0.85
}

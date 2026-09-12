package render

import instance "instance"

// Cursor blink overlay state (TODO Langkah 11).
//
// The overlay mirrors the terminal cursor position (row/col, synced
// explicitly via cursor_overlay_sync so render never reads Terminal
// directly) plus the blink phase (blink_on/next_toggle, advanced by
// cursor_overlay_tick with synthetic ns timestamps; the caller converts
// platform ticks via platform_ticks_to_ns and decides whether to present
// from the returned changed flag).
//
// Decisions (per locked spec, documented here):
//   - Initial state is visible-on: a zero-value Cursor_Overlay has
//     next_toggle == 0 (timer parked), so the first visible+focused tick
//     arms blink_on = true with a fresh timer and reports changed, and
//     the cursor appears immediately instead of after one blink period.
//   - Focus regained restarts visible-on with a fresh timer
//     (next_toggle = now + CURSOR_BLINK_NS), same as the initial tick.
//   - cursor_overlay_sync updates position only: blink phase and timer
//     are untouched, no toggle reset on cursor movement.
//   - Clock jumping backwards (now more than one full period behind the
//     scheduled toggle) clamps the timer to now + CURSOR_BLINK_NS and
//     reports unchanged, so no toggle storm can occur.

// Cursor_Overlay is the cursor blink + position mirror owned by render.
Cursor_Overlay :: struct {
	visible:     bool, // last term_visible seen by cursor_overlay_tick
	blink_on:    bool, // displayed state: true draws the cursor this frame
	row:         int,  // mirrored terminal cursor row (via cursor_overlay_sync)
	col:         int,  // mirrored terminal cursor col (via cursor_overlay_sync)
	next_toggle: i64,  // ns timestamp of the next blink flip; 0 = parked
}

// CURSOR_BLINK_NS is the blink half-period: the cursor toggles every 530ms
// while visible and focused.
CURSOR_BLINK_NS :: 530_000_000

// cursor_overlay_sync mirrors a terminal cursor move into the overlay.
// Position only: blink state and timer are untouched, no toggle reset.
cursor_overlay_sync :: proc(o: ^Cursor_Overlay, row, col: int) {
	o.row = row
	o.col = col
}

// cursor_overlay_tick advances the blink state for timestamp now (ns).
// focused is the window focus state, term_visible the DECTCEM visibility.
// Returns true iff the displayed state changed (caller decides whether
// to present).
cursor_overlay_tick :: proc(o: ^Cursor_Overlay, now: i64, focused: bool, term_visible: bool) -> bool {
	o.visible = term_visible
	if !term_visible || !focused {
		// Hidden or unfocused: steady off, timer parked.
		if o.blink_on || o.next_toggle != 0 {
			o.blink_on = false
			o.next_toggle = 0
			return true
		}
		return false
	}
	if o.next_toggle == 0 {
		// Parked (initial or focus regained): restart visible-on
		// with a fresh timer so the cursor appears immediately.
		o.blink_on = true
		o.next_toggle = now + CURSOR_BLINK_NS
		return true
	}
	if now < o.next_toggle - CURSOR_BLINK_NS {
		// Clock jumped backwards (more than a full period behind the
		// scheduled toggle): clamp the timer, no toggle storm.
		o.next_toggle = now + CURSOR_BLINK_NS
		return false
	}
	if now >= o.next_toggle {
		o.blink_on = !o.blink_on
		o.next_toggle = now + CURSOR_BLINK_NS
		return true
	}
	return false
}

// CURSOR_OVERLAY_R/G/B is the solid block color of the cursor quad
// (opaque white). Chosen over inverting the cell because
// instance_renderer_fill_bg emits a flat color directly, while an invert
// would need a compiled-cell fg/bg read that this signature cannot supply.
CURSOR_OVERLAY_R :: 1.0
CURSOR_OVERLAY_G :: 1.0
CURSOR_OVERLAY_B :: 1.0

// cursor_overlay_draw emits ONE solid-block quad at (o.col, o.row) into the
// existing instance staging buffer. The renderer composes this staged quad
// into its already-acquired surface before the frame's single present; this
// proc never acquires or presents and remains nil-backend safe.
//
// Decisions (per locked spec, documented here):
//   - Solid block in cursor color, not an invert: fill_bg with a color is
//     the only fill the locked (r, o) signature can supply.
//   - Wide-char alignment is always a single cell: the overlay carries no
//     width and render never reads Terminal (step 11 header), so a lead
//     covers only its lead half and a continuation only its own half.
//     Width-aware sync is deferred to a later step if needed.
//   - Blink off or hidden draws nothing: returns false, touches no buffer,
//     issues no GPU work.
//   - Out of bounds (stale after resize) is skipped, never clamped:
//     clamping would paint the cursor on the wrong cell.
//   - Idempotent within a frame: the quad always lands in the reserved
//     last slot (max_instances-1), so a second call overwrites identical
//     contents instead of appending a duplicate. Dense bg/glyph data is
//     never touched, so the glyph beneath stays intact for the next frame.
//
// Guarantees: never mutates Damage, never touches terminal state, never
// allocates. Returns true iff a quad was staged.
cursor_overlay_draw :: proc(r: ^Renderer, o: ^Cursor_Overlay, scrollback_offset: int = 0) -> bool {
	if r == nil {
		return false
	}
	r.cursor_staged = false
	if o == nil {
		return false
	}
	if !o.blink_on || !o.visible {
		return false
	}
	rows := int(r.rows)
	cols := int(r.cols)
	if rows <= 0 || cols <= 0 {
		return false
	}
	viewport_row := o.row + scrollback_offset
	if viewport_row < 0 || viewport_row >= rows || o.col < 0 || o.col >= cols {
		return false
	}
	inst := &r.instances
	if inst.max_instances == 0 {
		return false
	}
	if len(inst.instance_data) == 0 {
		return false
	}
	slot := inst.max_instances - 1
	if u64(slot) >= u64(len(inst.instance_data)) {
		return false
	}
	x := r.pad_x + f32(o.col) * r.cell_width
	y := r.pad_y + f32(viewport_row) * r.cell_height
	instance.instance_renderer_fill_bg(
		inst, slot, x, y, r.cell_width, r.cell_height,
		CURSOR_OVERLAY_R, CURSOR_OVERLAY_G, CURSOR_OVERLAY_B,
	)
	r.cursor_staged = true
	return true
}

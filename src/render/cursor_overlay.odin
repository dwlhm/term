package render

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

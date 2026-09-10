package render_tests

// TODO Langkah 11 blink-state tests (synthetic `now` values only, fully
// deterministic, no sleeping): one test per MECE row of the locked spec.

import "core:testing"
import render "../"

@(test)
test_cursor_overlay_initial_visible_on :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	testing.expect_value(t, render.CURSOR_BLINK_NS, 530_000_000)

	changed := render.cursor_overlay_tick(&o, 1000, true, true)
	testing.expect(t, changed, "first visible+focused tick must report changed")
	testing.expect(t, o.blink_on, "cursor must appear immediately on first tick")
	testing.expect_value(t, o.next_toggle, 1000 + render.CURSOR_BLINK_NS)
	testing.expect(t, o.visible, "overlay must mirror term_visible")
}

@(test)
test_cursor_overlay_timer_expired_toggles :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true) // arms next = 1000+B, on

	changed := render.cursor_overlay_tick(&o, 1000 + render.CURSOR_BLINK_NS, true, true)
	testing.expect(t, changed, "expired timer must report changed")
	testing.expect(t, !o.blink_on, "expired timer must toggle blink off")
	testing.expect_value(t, o.next_toggle, 1000 + 2 * render.CURSOR_BLINK_NS)
}

@(test)
test_cursor_overlay_timer_pending_unchanged :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true)

	changed := render.cursor_overlay_tick(&o, 1000 + render.CURSOR_BLINK_NS - 1, true, true)
	testing.expect(t, !changed, "pending timer must report unchanged")
	testing.expect(t, o.blink_on, "pending timer must keep blink on")
	testing.expect_value(t, o.next_toggle, 1000 + render.CURSOR_BLINK_NS)
}

@(test)
test_cursor_overlay_hidden_parks :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true) // on, timer armed

	changed := render.cursor_overlay_tick(&o, 2000, true, false)
	testing.expect(t, changed, "hiding a lit cursor must report changed")
	testing.expect(t, !o.blink_on, "hidden cursor must be steady off")
	testing.expect_value(t, o.next_toggle, 0)
	testing.expect(t, !o.visible, "overlay must mirror term_visible=false")

	again := render.cursor_overlay_tick(&o, 3000, true, false)
	testing.expect(t, !again, "already-parked hidden tick must report unchanged")
}

@(test)
test_cursor_overlay_unfocused_parks :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true) // on, timer armed

	changed := render.cursor_overlay_tick(&o, 2000, false, true)
	testing.expect(t, changed, "unfocus of a lit cursor must report changed")
	testing.expect(t, !o.blink_on, "unfocused cursor must be steady off")
	testing.expect_value(t, o.next_toggle, 0)

	again := render.cursor_overlay_tick(&o, 3000, false, true)
	testing.expect(t, !again, "already-parked unfocused tick must report unchanged")
}

@(test)
test_cursor_overlay_focus_regained_restarts_on :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true)
	render.cursor_overlay_tick(&o, 2000, false, true) // parked off

	changed := render.cursor_overlay_tick(&o, 9000, true, true)
	testing.expect(t, changed, "regained focus must report changed")
	testing.expect(t, o.blink_on, "regained focus must restart visible-on")
	testing.expect_value(t, o.next_toggle, 9000 + render.CURSOR_BLINK_NS)
}

@(test)
test_cursor_overlay_sync_moves_without_touching_blink :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 1000, true, true)
	before_toggle := o.next_toggle

	render.cursor_overlay_sync(&o, 5, 7)
	testing.expect_value(t, o.row, 5)
	testing.expect_value(t, o.col, 7)
	testing.expect(t, o.blink_on, "sync must leave blink state untouched")
	testing.expect_value(t, o.next_toggle, before_toggle)

	// Timer not reset by the move: still pending just before expiry.
	changed := render.cursor_overlay_tick(&o, before_toggle - 1, true, true)
	testing.expect(t, !changed, "sync must not reset the toggle timer")
}

@(test)
test_cursor_overlay_clock_backwards_clamps :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	render.cursor_overlay_tick(&o, 10_000, true, true) // next = 10_000+B, on

	changed := render.cursor_overlay_tick(&o, 100, true, true)
	testing.expect(t, !changed, "backwards clock must report unchanged (no toggle storm)")
	testing.expect(t, o.blink_on, "backwards clock must not toggle blink")
	testing.expect_value(t, o.next_toggle, 100 + render.CURSOR_BLINK_NS)

	steady := render.cursor_overlay_tick(&o, 100, true, true)
	testing.expect(t, !steady, "clamped timer must stay pending at the same now")
	testing.expect(t, o.blink_on, "clamped timer must keep blink on")
}

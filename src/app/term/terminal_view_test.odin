package term

// Behavioral tests for pane_grid_pad, the top-left anchored cell-grid padding helper.

import "core:testing"
import "core:time"

@test
test_pane_grid_pad_exact_fit :: proc(t: ^testing.T) {
	// 10 cols x 40px + 2*4px = 408 wide; 5 rows x 20px + 2*4px = 108 tall.
	rect := [4]f32{0, 0, 408, 108}
	px, py := pane_grid_pad(rect, 5, 10, 40, 20, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(4))
}

@test
test_pane_grid_pad_anchors_top_left_with_leftover :: proc(t: ^testing.T) {
	// Sub-cell leftover pixels are absorbed at the right/bottom edges so top-left
	// padding stays stationary during live resize (no sawtooth jitter).
	rect := [4]f32{0, 0, 425, 123}
	px, py := pane_grid_pad(rect, 4, 10, 40, 20, 4, 6)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(6))
}

@test
test_pane_grid_pad_anchors_top_left_across_term_sizes :: proc(t: ^testing.T) {
	rect := [4]f32{0, 0, 408, 108}
	px, py := pane_grid_pad(rect, 3, 10, 40, 20, 8, 10)
	testing.expect_value(t, px, f32(8))
	testing.expect_value(t, py, f32(10))
}

@test
test_pane_grid_pad_zero_cell_returns_base :: proc(t: ^testing.T) {
	px, py := pane_grid_pad([4]f32{0, 0, 800, 400}, 24, 80, 0, 0, 4, 4)
	testing.expect_value(t, px, f32(4))
	testing.expect_value(t, py, f32(4))
}

@test
test_cursor_blink_deadline_drift_free_and_inactive_parked :: proc(t: ^testing.T) {
	c: Cursor_State
	cursor_init(&c)
	testing.expect_value(t, c.is_visible, true)
	testing.expect_value(t, c.next_blink_ns, u64(0))

	// Arm at t = 100ms
	t0: u64 = 100_000_000
	toggled := cursor_update_blink(&c, t0, true)
	testing.expect_value(t, toggled, false)
	testing.expect_value(t, c.is_visible, true)
	testing.expect_value(t, c.next_blink_ns, t0 + CURSOR_BLINK_INTERVAL_NS)

	// Before deadline (t = 599ms) -> no toggle
	testing.expect_value(t, cursor_update_blink(&c, t0 + CURSOR_BLINK_INTERVAL_NS - 1, true), false)
	testing.expect_value(t, c.is_visible, true)

	// At deadline (t = 600ms) -> toggles off and advances drift-free to 1100ms
	testing.expect_value(t, cursor_update_blink(&c, t0 + CURSOR_BLINK_INTERVAL_NS + 5_000_000, true), true)
	testing.expect_value(t, c.is_visible, false)
	testing.expect_value(t, c.next_blink_ns, t0 + 2 * CURSOR_BLINK_INTERVAL_NS)

	// Input activity resets visibility and pushes deadline forward
	cursor_reset_blink(&c, t0 + 700_000_000)
	testing.expect_value(t, c.is_visible, true)
	testing.expect_value(t, c.next_blink_ns, t0 + 700_000_000 + CURSOR_BLINK_INTERVAL_NS)

	// Unfocused / inactive parks deadline to 0 and keeps cursor visible
	_ = cursor_update_blink(&c, t0 + 2_000_000_000, false)
	testing.expect_value(t, c.is_visible, true)
	testing.expect_value(t, c.next_blink_ns, u64(0))
}

@test
test_wait_timeout_parked_when_idle_and_wakes_on_pty :: proc(t: ^testing.T) {
	app := new(Term_App)
	defer free(app)
	app.start_time = time.now()
	app.layout.tab_bar_anim_t = 1.0

	// Completely idle & parked (next_deadline == 0) -> -1 (WaitEvent indefinite sleep)
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), i32(-1))

	// Pending PTY wakeup -> 0 (immediate non-blocking poll)
	app.wakeup_pending = true
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), i32(0))
	app.wakeup_pending = false

	// Active tab-bar slide animation -> FRAME_TICK_MS (8ms)
	app.layout.tab_bar_anim_t = 0.5
	testing.expect_value(t, app_compute_wait_timeout_ms(app, false), i32(FRAME_TICK_MS))
	app.layout.tab_bar_anim_t = 1.0
}

@test
test_quantize_layer_cap_grows_in_buckets :: proc(t: ^testing.T) {
	// Initial allocation rounds up to 256px multiples
	testing.expect_value(t, _quantize_layer_cap(0, 1280), u32(1280))
	testing.expect_value(t, _quantize_layer_cap(0, 1281), u32(1536))
	// Shrinking or sub-bucket growth keeps existing capacity (zero texture churn)
	testing.expect_value(t, _quantize_layer_cap(1536, 1285), u32(1536))
	testing.expect_value(t, _quantize_layer_cap(1536, 900), u32(1536))
	// Crossing bucket boundary grows to next 256px multiple
	testing.expect_value(t, _quantize_layer_cap(1536, 1537), u32(1792))
}

package term

// Behavioral tests for pane_grid_pad, the top-left anchored cell-grid padding helper.

import "core:testing"
import "core:time"
import terminal "../../core/terminal"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

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

@test
test_multiplexer_pane_at_floating_z_order_and_tiled :: proc(t: ^testing.T) {
	mux: mux_feat.Multiplexer
	mux_feat.multiplexer_init(&mux, {})
	defer mux_feat.multiplexer_destroy(&mux, false)

	dummy_sess: sess_feat.Terminal_Session
	p0_id := mux_feat.multiplexer_add_terminal_pane(&mux, &dummy_sess, 0)
	p1_id := mux_feat.multiplexer_add_terminal_pane(&mux, &dummy_sess, 1)
	pop_lo_id := mux_feat.multiplexer_add_terminal_pane(&mux, &dummy_sess, 10)
	pop_hi_id := mux_feat.multiplexer_add_terminal_pane(&mux, &dummy_sess, 11)

	mux_feat.multiplexer_get_pane(&mux, p0_id).rect = {0, 0, 400, 600}
	mux_feat.multiplexer_get_pane(&mux, p1_id).rect = {400, 0, 400, 600}

	pop_lo := mux_feat.multiplexer_get_pane(&mux, pop_lo_id)
	pop_lo.is_floating = true
	pop_lo.z = 5
	pop_lo.rect = {200, 100, 300, 200}

	pop_hi := mux_feat.multiplexer_get_pane(&mux, pop_hi_id)
	pop_hi.is_floating = true
	pop_hi.z = 10
	pop_hi.rect = {250, 150, 200, 150}

	// Uncovered left tiled pane -> p0
	testing.expect_value(t, mux_feat.multiplexer_pane_at(&mux, 50, 50).id, p0_id)
	// Uncovered right tiled pane -> p1
	testing.expect_value(t, mux_feat.multiplexer_pane_at(&mux, 700, 50).id, p1_id)
	// Inside pop_lo but outside pop_hi -> pop_lo
	testing.expect_value(t, mux_feat.multiplexer_pane_at(&mux, 220, 120).id, pop_lo_id)
	// Overlapping region of pop_lo and pop_hi -> pop_hi (higher z)
	testing.expect_value(t, mux_feat.multiplexer_pane_at(&mux, 300, 200).id, pop_hi_id)
}

@test
test_surface_popup_body_rect_centering :: proc(t: ^testing.T) {
	tm: terminal.Terminal
	terminal.terminal_init(&tm, 24, 80)
	defer terminal.terminal_destroy(&tm)

	terminal.terminal_feed_string(&tm, "\x1b]7502;3;2;20;6;0;0;0;10;2;1;\x1b\\")
	s := terminal.terminal_surface_find(&tm, 2)
	testing.expect(t, s != nil, "popup 2 should exist")
	if s != nil {
		metrics := Visual_Metrics{cell_w = 10, cell_h = 20, pane_pad_x = 8, pane_pad_y = 8, scale = 1}
		rect := surface_popup_body_rect({0, 0, 800, 480}, {0, 0, 800, 480}, &tm, s, metrics)
		testing.expect_value(t, rect[2], f32(20 * 10 + 16))
		testing.expect_value(t, rect[3], f32(6 * 20 + 16))
	}
}

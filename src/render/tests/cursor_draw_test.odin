package render_tests

// TODO Langkah 12 cursor-draw tests (CPU-only, nil backend): one test per
// MECE row of the locked spec. The GPU present itself cannot run headless,
// so these tests pin the CPU-verifiable contract: skip conditions, staged
// quad geometry, bounds clamp, wide single-cell decision, idempotence, and
// nil-safety. The backend stays nil in every test; a non-crash plus exact
// staging contents is the headless limit, documented honestly here.

import "core:testing"
import render "../"
import instance "../instance"
import termgrid "../../terminal"

CURSOR_DRAW_ROWS :: 24
CURSOR_DRAW_COLS :: 80
CURSOR_DRAW_MAX  :: 64
CURSOR_DRAW_CW   :: 8
CURSOR_DRAW_CH   :: 16

// _cursor_draw_renderer builds a CPU-only renderer state: nil backend, a
// zeroed instance staging buffer, fixed cell geometry. No GPU resources.
_cursor_draw_renderer :: proc(rows, cols: int, max: u32) -> render.Renderer {
	r: render.Renderer
	r.rows = i32(rows)
	r.cols = i32(cols)
	r.cell_width = CURSOR_DRAW_CW
	r.cell_height = CURSOR_DRAW_CH
	r.instances.max_instances = max
	r.instances.instance_data = make([]instance.Instance_Data, int(max))
	return r
}

// _cursor_draw_lit syncs the overlay to (row, col) and arms a visible,
// blink-on phase via the step-11 tick (term_visible drives tick).
_cursor_draw_lit :: proc(o: ^render.Cursor_Overlay, row, col: int) {
	render.cursor_overlay_sync(o, row, col)
	render.cursor_overlay_tick(o, 1000, true, true)
}

// _cursor_draw_nonzero counts staged quads. The cursor slot is expected to
// be the only nonzero entry after a draw.
_cursor_draw_nonzero :: proc(r: ^render.Renderer) -> int {
	zero := instance.Instance_Data{}
	n := 0
	for q in r.instances.instance_data {
		if q != zero {
			n += 1
		}
	}
	return n
}

@(test)
test_cursor_draw_narrow_emits_one_quad :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	// Sentinel bg quad in the dense region: the draw must leave it intact
	// (glyph beneath intact next frame — overlay only, no state change).
	instance.instance_renderer_fill_bg(&r.instances, 0, 0, 0, CURSOR_DRAW_CW, CURSOR_DRAW_CH, 0.0, 0.0, 0.5)
	before := r.instances.instance_data[0]

	term: termgrid.Terminal
	termgrid.terminal_init(&term, CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_move_cursor(&term, 2, 3)
	cur_before := termgrid.terminal_get_cursor(&term)

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 2, 3)

	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, drew, "blink_on && visible narrow cell must stage one quad")
	testing.expect(t, r.cursor_staged, "lit cursor must be marked for same-surface composition")

	slot := r.instances.max_instances - 1
	got := r.instances.instance_data[slot]
	testing.expect_value(t, got.x, f32(3 * CURSOR_DRAW_CW))
	testing.expect_value(t, got.y, f32(2 * CURSOR_DRAW_CH))
	testing.expect_value(t, got.cw, f32(CURSOR_DRAW_CW))
	testing.expect_value(t, got.ch, f32(CURSOR_DRAW_CH))
	testing.expect_value(t, got.r, f32(render.CURSOR_OVERLAY_R))
	testing.expect_value(t, got.g, f32(render.CURSOR_OVERLAY_G))
	testing.expect_value(t, got.b, f32(render.CURSOR_OVERLAY_B))
	testing.expect_value(t, got.a, 1.0)
	testing.expect_value(t, got.u0, 0.0)
	testing.expect_value(t, got.v0, 0.0)
	testing.expect_value(t, got.u1, 0.0)
	testing.expect_value(t, got.v1, 0.0)

	testing.expect_value(t, _cursor_draw_nonzero(&r), 2) // sentinel + cursor slot only
	testing.expect(t, r.instances.instance_data[0] == before, "dense region must be untouched (glyph intact)")

	// Overlay phase and terminal state untouched by the draw.
	testing.expect_value(t, o.row, 2)
	testing.expect_value(t, o.col, 3)
	testing.expect(t, o.blink_on && o.visible, "draw must not mutate overlay phase")
	cur_after := termgrid.terminal_get_cursor(&term)
	testing.expect(t, cur_after == cur_before, "draw must not touch terminal state")
}

@(test)
test_cursor_draw_blink_off_skips :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 1, 1)
	// Expire the timer: blink flips off while still visible+focused.
	render.cursor_overlay_tick(&o, 1000 + render.CURSOR_BLINK_NS, true, true)
	testing.expect(t, !o.blink_on, "setup must reach blink-off phase")

	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "blink off must draw nothing")
	testing.expect(t, !r.cursor_staged, "blink-off cursor must not be composed")
	testing.expect_value(t, _cursor_draw_nonzero(&r), 0)
}

@(test)
test_cursor_draw_hidden_skips :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	// DECTCEM-hidden via tick: steady off, timer parked.
	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 1, 1)
	render.cursor_overlay_tick(&o, 2000, true, false)
	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "DECTCEM-hidden cursor must draw nothing")
	testing.expect(t, !r.cursor_staged, "hidden cursor must not be composed")

	// Inconsistent phase honoring: blink_on without visible still skips.
	o.blink_on = true
	drew = render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "blink_on && !visible must draw nothing")
	testing.expect_value(t, _cursor_draw_nonzero(&r), 0)
}

@(test)
test_cursor_draw_wide_lead_single_cell :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(4, 8, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 4, 8)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_move_cursor(&term, 0, 0)
	termgrid.terminal_put_wide(&term, '中') // lead at col 0, continuation at col 1

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 0, 0)

	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, drew, "cursor on wide lead must still draw")

	slot := r.instances.max_instances - 1
	got := r.instances.instance_data[slot]
	testing.expect_value(t, got.x, 0.0)
	testing.expect_value(t, got.cw, f32(CURSOR_DRAW_CW))
	testing.expect(t, got.cw != 2 * f32(CURSOR_DRAW_CW), "lead decision: single cell, never double width")
	testing.expect_value(t, _cursor_draw_nonzero(&r), 1)
}

@(test)
test_cursor_draw_continuation_single_cell :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(4, 8, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 4, 8)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_move_cursor(&term, 0, 0)
	termgrid.terminal_put_wide(&term, '中')

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 0, 1) // continuation half: drawn as-positioned, single cell

	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, drew, "cursor on continuation must draw as-positioned")

	slot := r.instances.max_instances - 1
	got := r.instances.instance_data[slot]
	testing.expect_value(t, got.x, f32(CURSOR_DRAW_CW))
	testing.expect_value(t, got.cw, f32(CURSOR_DRAW_CW))
	testing.expect_value(t, _cursor_draw_nonzero(&r), 1)
}

@(test)
test_cursor_draw_oob_stale_skips :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, CURSOR_DRAW_ROWS + 6, CURSOR_DRAW_COLS + 10) // stale after shrink
	drew := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "stale out-of-bounds cursor must be skipped, never OOB")

	render.cursor_overlay_sync(&o, -1, 0)
	drew = render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "negative row must be skipped")

	render.cursor_overlay_sync(&o, 0, -1)
	drew = render.cursor_overlay_draw(&r, &o)
	testing.expect(t, !drew, "negative col must be skipped")

	testing.expect_value(t, _cursor_draw_nonzero(&r), 0)
}

@(test)
test_cursor_draw_idempotent :: proc(t: ^testing.T) {
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)

	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 5, 7)

	first := render.cursor_overlay_draw(&r, &o)
	slot := r.instances.max_instances - 1
	after_first := r.instances.instance_data[slot]
	count_first := _cursor_draw_nonzero(&r)

	second := render.cursor_overlay_draw(&r, &o)
	testing.expect(t, first && second, "both calls in one frame must report drawn")
	testing.expect(t, r.instances.instance_data[slot] == after_first, "second call must overwrite identical contents")
	testing.expect_value(t, _cursor_draw_nonzero(&r), count_first)
	testing.expect_value(t, _cursor_draw_nonzero(&r), 1)
}

@(test)
test_cursor_draw_nil_safe :: proc(t: ^testing.T) {
	o: render.Cursor_Overlay
	_cursor_draw_lit(&o, 0, 0)

	testing.expect(t, !render.cursor_overlay_draw(nil, &o), "nil renderer must skip")
	r := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	defer delete(r.instances.instance_data)
	testing.expect(t, !render.cursor_overlay_draw(&r, nil), "nil overlay must skip")

	empty: render.Renderer
	empty.rows = CURSOR_DRAW_ROWS
	empty.cols = CURSOR_DRAW_COLS
	testing.expect(t, !render.cursor_overlay_draw(&empty, &o), "zero max_instances must skip")

	no_staging := _cursor_draw_renderer(CURSOR_DRAW_ROWS, CURSOR_DRAW_COLS, CURSOR_DRAW_MAX)
	delete(no_staging.instances.instance_data)
	no_staging.instances.instance_data = nil
	testing.expect(t, !render.cursor_overlay_draw(&no_staging, &o), "nil staging must skip")
}

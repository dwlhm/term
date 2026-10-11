package render_tests

// Phase 16 adaptive strategy tests (nil backend, no GPU):
// static ratio bands on an 80x80 grid (one full row = 80/6400 = 1.25%),
// scroll + 1-cell carve-out locks, cold vs warm online overrides, pin wins
// + unavailable-pin fallback without latching, and no-record-on-skip.

import "core:testing"
import render "../"
import termgrid "../../terminal"

STRATEGY_TEST_ROWS :: 80
STRATEGY_TEST_COLS :: 80
STRATEGY_TEST_N :: STRATEGY_TEST_ROWS * STRATEGY_TEST_COLS

// _strategy_test_inputs marks k full rows on a fresh 80x80 terminal and
// estimates the selector inputs read-only (the journal stays intact).
_strategy_test_inputs :: proc(term: ^termgrid.Terminal, k: int) -> render.Strategy_Inputs {
	for row in 0..<k {
		termgrid.damage_mark_row(&term.damage, row, 0)
	}
	return render.strategy_estimate_inputs(&term.damage, STRATEGY_TEST_ROWS, STRATEGY_TEST_COLS)
}

@(test)
test_strategy_static_bands :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, STRATEGY_TEST_ROWS, STRATEGY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	// Empty journal: zero damage, zero ratio.
	empty := render.strategy_estimate_inputs(&term.damage, STRATEGY_TEST_ROWS, STRATEGY_TEST_COLS)
	testing.expect_value(t, empty.dirty_cells, 0)
	testing.expect_value(t, empty.total_cells, STRATEGY_TEST_N)
	testing.expect(t, render.strategy_select_static(empty) == .Instance, "empty must select Instance")

	// 1-cell single span: tile-amplification carve-out.
	termgrid.damage_mark_cell(&term.damage, 12, 40, 0)
	one := render.strategy_estimate_inputs(&term.damage, STRATEGY_TEST_ROWS, STRATEGY_TEST_COLS)
	testing.expect_value(t, one.dirty_cells, 1)
	testing.expect_value(t, one.span_count, 1)
	testing.expect_value(t, one.full_rows, 0)
	testing.expect(t, render.strategy_select_static(one) == .Instance, "1-cell must select Instance")
	termgrid.damage_clear(&term.damage)

	// Single full row ~1.25%: below the Instance band edge by ratio.
	row := _strategy_test_inputs(&term, 1)
	testing.expect_value(t, row.dirty_cells, STRATEGY_TEST_COLS)
	testing.expect_value(t, row.full_rows, 1)
	testing.expect(t, row.ratio < render.STRATEGY_INSTANCE_MAX_RATIO, "one row must sit below the Instance band edge")
	testing.expect(t, render.strategy_select_static(row) == .Instance, "one row must select Instance")
	termgrid.damage_clear(&term.damage)

	// 10% and 25%: mid-band Compute.
	ten := _strategy_test_inputs(&term, 8)
	testing.expect(t, render.strategy_select_static(ten) == .Compute_Tiles, "10% must select Compute")
	termgrid.damage_clear(&term.damage)
	quarter := _strategy_test_inputs(&term, 20)
	testing.expect(t, render.strategy_select_static(quarter) == .Compute_Tiles, "25% must select Compute")
	termgrid.damage_clear(&term.damage)

	// 65% and 100%: fullscreen band.
	sixty := _strategy_test_inputs(&term, 52)
	testing.expect(t, render.strategy_select_static(sixty) == .Fullscreen, "65% must select Fullscreen")
	termgrid.damage_clear(&term.damage)
	flood := _strategy_test_inputs(&term, STRATEGY_TEST_ROWS)
	testing.expect_value(t, flood.dirty_cells, STRATEGY_TEST_N)
	testing.expect(t, render.strategy_select_static(flood) == .Fullscreen, "flood must select Fullscreen")
	termgrid.damage_clear(&term.damage)

	// Scroll ops: structural, always Instance.
	termgrid.damage_record_scroll(&term.damage, 0, STRATEGY_TEST_ROWS - 1, 1)
	scroll := render.strategy_estimate_inputs(&term.damage, STRATEGY_TEST_ROWS, STRATEGY_TEST_COLS)
	testing.expect(t, scroll.scroll, "scroll op must set the scroll flag")
	testing.expect(t, render.strategy_select_static(scroll) == .Instance, "scroll must select Instance")
	termgrid.damage_clear(&term.damage)

	// Degenerate geometry: undefined ratio locks to Instance.
	zero := render.strategy_estimate_inputs(&term.damage, 0, STRATEGY_TEST_COLS)
	testing.expect_value(t, zero.total_cells, 0)
	testing.expect(t, render.strategy_select_static(zero) == .Instance, "zero geometry must select Instance")
}

@(test)
test_strategy_ratio_edges :: proc(t: ^testing.T) {
	below := render.Strategy_Inputs{dirty_cells = 2, total_cells = 100, ratio = f32(2) / f32(100)}
	testing.expect(t, render.strategy_select_static(below) == .Instance, "2% must select Instance")
	edge_lo := render.Strategy_Inputs{dirty_cells = 3, total_cells = 100, ratio = f32(3) / f32(100)}
	testing.expect(t, render.strategy_select_static(edge_lo) == .Compute_Tiles, "3% must select Compute")
	edge_hi := render.Strategy_Inputs{dirty_cells = 64, total_cells = 100, ratio = f32(64) / f32(100)}
	testing.expect(t, render.strategy_select_static(edge_hi) == .Compute_Tiles, "64% must select Compute")
	at_hi := render.Strategy_Inputs{dirty_cells = 65, total_cells = 100, ratio = f32(65) / f32(100)}
	testing.expect(t, render.strategy_select_static(at_hi) == .Fullscreen, "65% must select Fullscreen")
}

@(test)
test_strategy_availability_gate :: proc(t: ^testing.T) {
	mid := render.Strategy_Inputs{dirty_cells = 192, total_cells = 1920, ratio = f32(192) / f32(1920), full_rows = 2}
	large := render.Strategy_Inputs{dirty_cells = 1920, total_cells = 1920, ratio = 1.0, full_rows = 24}
	st: render.Strategy_State

	testing.expect(t, render.strategy_select(mid, &st, true, true) == .Compute_Tiles, "mid-band with compute must stay Compute")
	testing.expect(t, render.strategy_select(mid, &st, false, true) == .Instance, "mid-band without compute must fall to Instance")
	testing.expect(t, render.strategy_select(large, &st, true, true) == .Fullscreen, "flood with fullscreen must stay Fullscreen")
	testing.expect(t, render.strategy_select(large, &st, true, false) == .Compute_Tiles, "flood without fullscreen must fall to Compute")
	testing.expect(t, render.strategy_select(large, &st, false, false) == .Instance, "flood with neither sibling must fall to Instance")
}

@(test)
test_strategy_online_override :: proc(t: ^testing.T) {
	mid := render.Strategy_Inputs{dirty_cells = 192, total_cells = 1920, ratio = f32(192) / f32(1920), full_rows = 2}
	large := render.Strategy_Inputs{dirty_cells = 1920, total_cells = 1920, ratio = 1.0, full_rows = 24}

	// Cold history: static order holds.
	cold: render.Strategy_State
	testing.expect(t, render.strategy_select(mid, &cold, true, true) == .Compute_Tiles, "cold mid-band must stay Compute")
	testing.expect(t, render.strategy_select(large, &cold, true, true) == .Fullscreen, "cold flood must stay Fullscreen")

	// Warm mid-band: cheaper fullscreen inverts Compute -> Fullscreen.
	st: render.Strategy_State
	for _ in 0..<render.STRATEGY_WARMUP_FRAMES {
		render.strategy_record(&st, .Compute_Tiles, 9000)
		render.strategy_record(&st, .Fullscreen, 1000)
	}
	avg_ct, warm_ct := render.strategy_avg(&st.costs[int(render.Render_Strategy.Compute_Tiles)])
	avg_fs, warm_fs := render.strategy_avg(&st.costs[int(render.Render_Strategy.Fullscreen)])
	testing.expect_value(t, avg_ct, u64(9000))
	testing.expect_value(t, avg_fs, u64(1000))
	testing.expect(t, warm_ct && warm_fs, "seeded rings must be warm")
	testing.expect(t, render.strategy_select(mid, &st, true, true) == .Fullscreen, "warm cheaper fullscreen must invert mid-band")

	// Warm flood: cheaper compute pulls Fullscreen -> Compute.
	st2: render.Strategy_State
	for _ in 0..<render.STRATEGY_WARMUP_FRAMES {
		render.strategy_record(&st2, .Fullscreen, 9000)
		render.strategy_record(&st2, .Compute_Tiles, 1000)
	}
	testing.expect(t, render.strategy_select(large, &st2, true, true) == .Compute_Tiles, "warm cheaper compute must pull back flood")

	// Warm small-band: cheaper compute follows Instance -> Compute.
	small := render.Strategy_Inputs{dirty_cells = 2, total_cells = 1920, ratio = f32(2) / f32(1920), span_count = 2}
	st3: render.Strategy_State
	for _ in 0..<render.STRATEGY_WARMUP_FRAMES {
		render.strategy_record(&st3, .Instance, 9000)
		render.strategy_record(&st3, .Compute_Tiles, 1000)
	}
	testing.expect(t, render.strategy_select_static(small) == .Instance, "2-cell must be static Instance")
	testing.expect(t, render.strategy_select(small, &st3, true, true) == .Compute_Tiles, "warm cheaper compute must follow small Instance")

	// Carve-outs never flip, however lopsided the averages.
	one := render.Strategy_Inputs{dirty_cells = 1, total_cells = 1920, ratio = f32(1) / f32(1920), span_count = 1}
	testing.expect(t, render.strategy_select(one, &st3, true, true) == .Instance, "1-cell carve-out must never flip")
	scrolled := render.Strategy_Inputs{dirty_cells = 80, total_cells = 1920, ratio = f32(80) / f32(1920), full_rows = 1, scroll = true}
	testing.expect(t, render.strategy_select(scrolled, &st, true, true) == .Instance, "scroll must never flip")
}

@(test)
test_strategy_record_ring :: proc(t: ^testing.T) {
	st: render.Strategy_State

	// Zero samples are skipped, never poison.
	render.strategy_record(&st, .Compute_Tiles, 0)
	testing.expect_value(t, st.costs[int(render.Render_Strategy.Compute_Tiles)].count, 0)

	// Fill past the ring: count saturates, sum tracks the last 16.
	for i in 1..=20 {
		render.strategy_record(&st, .Compute_Tiles, u64(i * 100))
	}
	c := &st.costs[int(render.Render_Strategy.Compute_Tiles)]
	testing.expect_value(t, c.count, render.STRATEGY_HISTORY_N)
	want: u64 = 0
	for i in 5..=20 {
		want += u64(i * 100)
	}
	testing.expect_value(t, c.sum, want)
	avg, warm := render.strategy_avg(c)
	testing.expect_value(t, avg, want / u64(render.STRATEGY_HISTORY_N))
	testing.expect(t, warm, "full ring must be warm")
	testing.expect(t, st.last == .Compute_Tiles, "record must stamp last")
	testing.expect_value(t, st.last_ns, u64(2000))

	// Reset zeroes costs + last but preserves the pin.
	st.pinned = true
	st.pin = .Fullscreen
	render.strategy_reset(&st)
	testing.expect_value(t, st.costs[int(render.Render_Strategy.Compute_Tiles)].count, 0)
	testing.expect_value(t, st.costs[int(render.Render_Strategy.Compute_Tiles)].sum, u64(0))
	testing.expect(t, st.last == .Instance, "reset must restore last to Instance")
	testing.expect_value(t, st.last_ns, u64(0))
	testing.expect(t, st.pinned && st.pin == .Fullscreen, "reset must preserve the pin")
}

@(test)
test_strategy_pin_fallback :: proc(t: ^testing.T) {
	flood := render.Strategy_Inputs{dirty_cells = 1920, total_cells = 1920, ratio = 1.0, full_rows = 24}
	scrolled := render.Strategy_Inputs{dirty_cells = 80, total_cells = 1920, ratio = f32(80) / f32(1920), full_rows = 1, scroll = true}

	r: render.Renderer
	st := &r.strategy_state

	// Pin wins over scroll, ratio, and history.
	render.renderer_strategy_pin(&r, .Fullscreen)
	testing.expect(t, st.pinned && st.pin == .Fullscreen, "pin must latch")
	testing.expect(t, render.strategy_select(scrolled, st, true, true) == .Fullscreen, "pin must win over scroll")
	testing.expect(t, render.strategy_select(flood, st, true, false) == .Instance, "unavailable pinned sibling must fall to Instance")
	testing.expect(t, !r.fullscreen.available, "fallback must never latch available")

	// Unavailable compute pin falls back without latching.
	render.renderer_strategy_pin(&r, .Compute_Tiles)
	testing.expect(t, render.strategy_select(flood, st, false, true) == .Instance, "unavailable compute pin must fall to Instance")
	testing.expect(t, !r.compute_tiles.available, "compute fallback must never latch available")

	// History cannot move a pin either.
	for _ in 0..<render.STRATEGY_WARMUP_FRAMES {
		render.strategy_record(st, .Instance, 1)
		render.strategy_record(st, .Fullscreen, 9000)
	}
	testing.expect(t, render.strategy_select(flood, st, true, true) == .Compute_Tiles, "pinned compute must still win with hostile history")

	// Unpin resumes adaptive selection with history intact.
	render.renderer_strategy_unpin(&r)
	testing.expect(t, !st.pinned, "unpin must clear pinned")
	testing.expect(t, render.strategy_select(flood, st, true, true) == .Fullscreen, "unpinned flood must resume static Fullscreen")

	// Manual set_strategy never leaves a stale pin.
	render.renderer_strategy_pin(&r, .Fullscreen)
	render.renderer_set_strategy(&r, .Instance)
	testing.expect(t, !st.pinned, "manual set must clear the pin")
	testing.expect(t, r.strategy == .Instance, "manual set must still switch the path")
}

@(test)
test_strategy_cell_origin_contract :: proc(t: ^testing.T) {
	r: render.Renderer
	r.pad_x = 3.5
	r.pad_y = 2.25
	r.cell_width = 9.0
	r.cell_height = 17.0
	r.compute_tiles.pad_x = r.pad_x
	r.compute_tiles.pad_y = r.pad_y
	r.fullscreen.pad_x = r.pad_x
	r.fullscreen.pad_y = r.pad_y

	row := 4
	col := 7
	want_x := r.pad_x + f32(col) * r.cell_width
	want_y := r.pad_y + f32(row) * r.cell_height
	instance_x := r.pad_x + f32(col) * r.cell_width
	instance_y := r.pad_y + f32(row) * r.cell_height
	compute_x := r.compute_tiles.pad_x + f32(col) * r.cell_width
	compute_y := r.compute_tiles.pad_y + f32(row) * r.cell_height
	fullscreen_x := r.fullscreen.pad_x + f32(col) * r.cell_width
	fullscreen_y := r.fullscreen.pad_y + f32(row) * r.cell_height

	testing.expect_value(t, instance_x, want_x)
	testing.expect_value(t, instance_y, want_y)
	testing.expect_value(t, compute_x, want_x)
	testing.expect_value(t, compute_y, want_y)
	testing.expect_value(t, fullscreen_x, want_x)
	testing.expect_value(t, fullscreen_y, want_y)
}


@(test)
test_strategy_no_record_on_skip :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 24, 80)
	defer termgrid.terminal_destroy(&term)
	lut := _dirty_test_lut()

	// Empty journal: skip with no candidate, no record, no delegation.
	r: render.Renderer
	r.rows = 24
	r.cols = 80
	testing.expect(t, !render.renderer_frame_auto(&r, &term, &lut), "empty frame must skip")
	testing.expect_value(t, r.frame_count, u64(0))
	testing.expect_value(t, r.strategy_state.costs[0].count, 0)
	testing.expect_value(t, r.strategy_state.costs[1].count, 0)
	testing.expect_value(t, r.strategy_state.costs[2].count, 0)

	// Dirty frame with nil backend: dispatch fails, nothing recorded.
	termgrid.terminal_move_cursor(&term, 12, 40)
	termgrid.terminal_put_char(&term, 'Q')
	testing.expect(t, !render.renderer_frame_auto(&r, &term, &lut), "nil-backend frame must return false")
	testing.expect(t, r.last_dirty, "dirty frame must arm last_dirty through the delegated proc")
	testing.expect_value(t, r.strategy_state.costs[0].count, 0)
	testing.expect_value(t, r.strategy_state.costs[1].count, 0)
	testing.expect_value(t, r.strategy_state.costs[2].count, 0)
	testing.expect_value(t, r.strategy_state.last_ns, u64(0))
}

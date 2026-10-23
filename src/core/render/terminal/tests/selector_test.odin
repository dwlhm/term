package render_terminal_tests

// Regression tests for the adaptive strategy selector's sticky hysteresis gate.
// The gate exists to damp per-frame pipeline oscillation (Instance <->
// Compute_Tiles <-> Fullscreen), which is the primary source of visible flashing
// during damage-heavy activity.

import "core:testing"
import render_terminal "../"

@(private = "file")
_full_input :: proc(total_cells: int = 100) -> render_terminal.Strategy_Inputs {
	return render_terminal.Strategy_Inputs{
		dirty_cells = total_cells,
		total_cells = total_cells,
		ratio       = 1.0,
		full_rows   = total_cells,
		span_count  = 1,
		scroll      = false,
	}
}

@(private = "file")
_small_input :: proc(total_cells: int = 100) -> render_terminal.Strategy_Inputs {
	// Two dirty cells: below the instance threshold but NOT the single-cell
	// structural lock, so it exercises the ordinary ratio decision.
	return render_terminal.Strategy_Inputs{
		dirty_cells = 2,
		total_cells = total_cells,
		ratio       = 0.02,
		full_rows   = 0,
		span_count  = 2,
		scroll      = false,
	}
}

@(test)
test_static_thresholds :: proc(t: ^testing.T) {
	testing.expect_value(t, render_terminal.strategy_select_static(_full_input()), render_terminal.Render_Strategy.Fullscreen)
	testing.expect_value(t, render_terminal.strategy_select_static(_small_input()), render_terminal.Render_Strategy.Instance)
	mid := render_terminal.Strategy_Inputs{dirty_cells = 50, total_cells = 100, ratio = 0.5, full_rows = 1, span_count = 1}
	testing.expect_value(t, render_terminal.strategy_select_static(mid), render_terminal.Render_Strategy.Compute_Tiles)
}

@(test)
test_single_cell_locks_instance_immediately :: proc(t: ^testing.T) {
	st: render_terminal.Strategy_State
	// Drive the committed strategy to Fullscreen first so the lock is exercised
	// against a non-Instance committed strategy.
	for _ in 0 ..< render_terminal.STRATEGY_STICKY_FRAMES {
		_ = render_terminal.strategy_select(_full_input(), &st, true, true)
	}
	testing.expect_value(t, st.committed, render_terminal.Render_Strategy.Fullscreen)

	single := render_terminal.Strategy_Inputs{dirty_cells = 1, total_cells = 100, ratio = 0.01, full_rows = 0, span_count = 1}
	s := render_terminal.strategy_select(single, &st, true, true)
	testing.expect_value(t, s, render_terminal.Render_Strategy.Instance)
}

@(test)
test_scroll_locks_instance_immediately :: proc(t: ^testing.T) {
	st: render_terminal.Strategy_State
	for _ in 0 ..< render_terminal.STRATEGY_STICKY_FRAMES {
		_ = render_terminal.strategy_select(_full_input(), &st, true, true)
	}

	scroll := render_terminal.Strategy_Inputs{dirty_cells = 10, total_cells = 100, ratio = 0.1, full_rows = 1, span_count = 1, scroll = true}
	s := render_terminal.strategy_select(scroll, &st, true, true)
	testing.expect_value(t, s, render_terminal.Render_Strategy.Instance)
}

@(test)
test_hysteresis_commits_after_sticky_frames :: proc(t: ^testing.T) {
	st: render_terminal.Strategy_State

	s0 := render_terminal.strategy_select(_full_input(), &st, true, true)
	testing.expect_value(t, s0, render_terminal.Render_Strategy.Instance)

	s1 := render_terminal.strategy_select(_full_input(), &st, true, true)
	testing.expect_value(t, s1, render_terminal.Render_Strategy.Instance)

	s2 := render_terminal.strategy_select(_full_input(), &st, true, true)
	testing.expect_value(t, s2, render_terminal.Render_Strategy.Fullscreen)
}

@(test)
test_hysteresis_damps_alternation :: proc(t: ^testing.T) {
	// Alternating full -> small damage must never flip the committed strategy:
	// a lone full-redraw frame between small updates is not a sustained workload.
	st: render_terminal.Strategy_State
	for _ in 0 ..< 10 {
		_ = render_terminal.strategy_select(_full_input(), &st, true, true)
		_ = render_terminal.strategy_select(_small_input(), &st, true, true)
	}
	testing.expect_value(t, st.committed, render_terminal.Render_Strategy.Instance)
}

@(test)
test_hysteresis_returns_to_instance_after_sustained_small :: proc(t: ^testing.T) {
	st: render_terminal.Strategy_State
	// Commit to Fullscreen.
	for _ in 0 ..< render_terminal.STRATEGY_STICKY_FRAMES {
		_ = render_terminal.strategy_select(_full_input(), &st, true, true)
	}
	testing.expect_value(t, st.committed, render_terminal.Render_Strategy.Fullscreen)

	// Sustained small damage returns to Instance after the sticky delay.
	s0 := render_terminal.strategy_select(_small_input(), &st, true, true)
	testing.expect_value(t, s0, render_terminal.Render_Strategy.Fullscreen)
	s1 := render_terminal.strategy_select(_small_input(), &st, true, true)
	testing.expect_value(t, s1, render_terminal.Render_Strategy.Fullscreen)
	s2 := render_terminal.strategy_select(_small_input(), &st, true, true)
	testing.expect_value(t, s2, render_terminal.Render_Strategy.Instance)
}

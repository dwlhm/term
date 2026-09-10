package bench

// Phase 16 strategy benchmarks: select-only cost over the damage-extent
// sweep (sub-microsecond target, zero allocations) and a T1-T4 auto-replay
// through renderer_frame_auto on CPU-only nil-backend states mirroring the
// bench_fullscreen traces, reporting the chosen mix per trace plus total
// submit ns against a pinned-Instance baseline.

import render "../render"
import termgrid "../terminal"
import "../platform"

// STRATEGY_SELECT_SWEEP is the damage-extent sweep set (percent of grid).
STRATEGY_SELECT_SWEEP := [6]int{1, 4, 10, 25, 50, 100}

// STRATEGY_SELECT_ITERS is the timed repetition count per sweep point.
STRATEGY_SELECT_ITERS :: 20000

// STRATEGY_SELECT_NS_PER_SELECT holds the latest bench_strategy_select
// mean cost per strategy_select call in nanoseconds (sub-us target).
STRATEGY_SELECT_NS_PER_SELECT: f64

// bench_strategy_select times strategy_select alone over the 1/4/10/25/50/
// 100% sweep on the 24x80 grid with cold state and both siblings available.
// The selector performs no allocation, so allocation_count is untouched;
// elapsed submit-side ns folds into render_time_ns.
bench_strategy_select :: proc(ctx: ^Benchmark_Context) {
	inputs: [len(STRATEGY_SELECT_SWEEP)]render.Strategy_Inputs
	for pct, i in STRATEGY_SELECT_SWEEP {
		dirty := max(1, pct * FULLSCREEN_BENCH_N / 100)
		full := dirty / FULLSCREEN_BENCH_COLS
		rem := dirty % FULLSCREEN_BENCH_COLS
		spans := 1 if rem > 0 else 0
		inputs[i] = render.Strategy_Inputs{
			dirty_cells = dirty,
			total_cells = FULLSCREEN_BENCH_N,
			ratio       = f32(dirty) / f32(FULLSCREEN_BENCH_N),
			full_rows   = full,
			span_count  = spans,
		}
	}
	st: render.Strategy_State
	start := platform.platform_now()
	for _ in 0..<STRATEGY_SELECT_ITERS {
		for inp in inputs {
			_ = render.strategy_select(inp, &st, true, true)
		}
	}
	end := platform.platform_now()
	total_ns := platform.platform_ticks_to_ns(end - start)
	STRATEGY_SELECT_NS_PER_SELECT = f64(total_ns) / f64(STRATEGY_SELECT_ITERS * len(inputs))
	ctx.gpu_stats.render_time_ns += total_ns
}

// Strategy_Auto_Summary is one trace's auto-replay row: the chosen mix per
// strategy plus total submit ns around the frame_auto calls.
Strategy_Auto_Summary :: struct {
	trace:             int,
	frames:            int,
	instance_frames:   int,
	compute_frames:    int,
	fullscreen_frames: int,
	cpu_submit_ns:     i64,
}

// STRATEGY_AUTO_MIX holds the latest bench_strategy_auto_replay per-trace
// breakdown (T1..T4 at indices 0..3).
STRATEGY_AUTO_MIX: [4]Strategy_Auto_Summary

// STRATEGY_AUTO_BASELINE_NS holds the pinned-Instance submit ns per trace
// (T1..T4 at indices 0..3) for the auto-vs-pinned comparison; the scroll
// trace (T3) must land within noise of its baseline (both take Instance).
STRATEGY_AUTO_BASELINE_NS: [4]i64

// _strategy_auto_frame applies one trace frame's damage and runs it through
// renderer_frame_auto on a nil-backend renderer, returning the call's submit
// ns. The chosen strategy lands in r.strategy for the mix tally.
_strategy_auto_frame :: proc(r: ^render.Renderer, term: ^termgrid.Terminal, lut: ^render.Style_LUT, trace: int) -> i64 {
	_compute_tile_apply_trace(term, trace)
	start := platform.platform_now()
	_ = render.renderer_frame_auto(r, term, lut)
	end := platform.platform_now()
	return platform.platform_ticks_to_ns(end - start)
}

// _strategy_auto_run_trace replays one trace for frames frames through
// frame_auto (pinned selects the pinned-Instance baseline path instead) and
// tallies the chosen mix.
_strategy_auto_run_trace :: proc(trace: int, frames: int, pinned: bool) -> Strategy_Auto_Summary {
	s: Strategy_Auto_Summary
	s.trace = trace
	s.frames = frames
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FULLSCREEN_BENCH_ROWS, FULLSCREEN_BENCH_COLS)
	defer termgrid.terminal_destroy(&term)
	r: render.Renderer
	r.rows = FULLSCREEN_BENCH_ROWS
	r.cols = FULLSCREEN_BENCH_COLS
	r.compute_tiles.available = true
	r.fullscreen.available = true
	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &term.grid.style_table)
	if pinned {
		render.renderer_strategy_pin(&r, .Instance)
	}
	for _ in 0..<frames {
		s.cpu_submit_ns += _strategy_auto_frame(&r, &term, &lut, trace)
		switch r.strategy {
		case .Instance:
			s.instance_frames += 1
		case .Compute_Tiles:
			s.compute_frames += 1
		case .Fullscreen:
			s.fullscreen_frames += 1
		}
	}
	return s
}

// bench_strategy_auto_replay replays T1 typing / T2 line / T3 scroll / T4
// fullscreen through frame_auto with the FULLSCREEN_TRACE_REPS frame counts
// and identical per-trace damage, then replays each trace pinned to Instance.
// The auto mix lands in STRATEGY_AUTO_MIX, the baselines in
// STRATEGY_AUTO_BASELINE_NS; totals accumulate into ctx.
bench_strategy_auto_replay :: proc(ctx: ^Benchmark_Context) {
	for ti in 0..<4 {
		auto := _strategy_auto_run_trace(ti + 1, FULLSCREEN_TRACE_REPS[ti], false)
		STRATEGY_AUTO_MIX[ti] = auto
		base := _strategy_auto_run_trace(ti + 1, FULLSCREEN_TRACE_REPS[ti], true)
		STRATEGY_AUTO_BASELINE_NS[ti] = base.cpu_submit_ns
		ctx.gpu_stats.render_time_ns += auto.cpu_submit_ns + base.cpu_submit_ns
		ctx.allocation_count += auto.frames + base.frames
	}
}

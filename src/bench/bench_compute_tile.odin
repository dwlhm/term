package bench

// Phase 14 compute-tile benchmark: T1 typing / T2 line / T3 scroll /
// T4 fullscreen traces replayed under both strategies with identical
// seed/LUT, plus a tile-size sweep over TILE_CANDIDATES.
//
// Byte-count rule: compute bytes = dirty cell-range bytes + tile-list
// bytes (count*4) + LUT bytes when rebuilt; blit uploads 0 bytes.
// Instance bytes = dirty-upload range bytes (2 draws/frame); scroll
// falls back to the dense legacy upload. Compute issues 1 dispatch +
// 1 blit draw per non-empty frame.

import render "../render"
import instance "../render/instance"
import tile "../render/tile"
import termgrid "../terminal"
import "../platform"

COMPUTE_TILE_BENCH_ROWS :: 24
COMPUTE_TILE_BENCH_COLS :: 80
COMPUTE_TILE_BENCH_N :: COMPUTE_TILE_BENCH_ROWS * COMPUTE_TILE_BENCH_COLS

// Compute_Tile_Counters accumulates one strategy's submit-side totals.
Compute_Tile_Counters :: struct {
	cpu_submit_ns: i64,
	bytes_uploaded: int,
	invocations:   u32,
	dispatches:    u32,
}

// Compute_Tile_Trace_Summary is one trace's crossover row (Phase 16 handoff).
Compute_Tile_Trace_Summary :: struct {
	trace:          int,
	frames:         int,
	bytes_uploaded: int,
	dispatches:    u32,
	invocations:   u32,
	cpu_submit_ns: i64,
}

// COMPUTE_TILE_COMPARE_TRACES holds the latest bench_compare_instance_vs_compute
// per-trace breakdown (T1..T4 at indices 0..3) for the crossover table.
COMPUTE_TILE_COMPARE_TRACES: [4]Compute_Tile_Trace_Summary

// COMPUTE_TILE_TRACE_REPS is the per-trace frame count (T1..T4).
COMPUTE_TILE_TRACE_REPS := [4]int{500, 200, 100, 50}

// _compute_tile_bench_states builds CPU-only renderer + terminal + dirty +
// tile map states sharing one deterministic LUT (nil backend: byte math
// only, no GPU work).
_compute_tile_bench_states :: proc(
	term: ^termgrid.Terminal,
	r: ^render.Renderer,
	d: ^render.Dirty_Upload,
	lut: ^render.Style_LUT,
	m: ^tile.Tile_Map,
	tile_w: u32,
	tile_h: u32,
) -> bool {
	_dirty_bench_setup(term, r, d, lut)
	r.instances.max_instances = u32(2 * COMPUTE_TILE_BENCH_N)
	r.instances.instance_data = make([]instance.Instance_Data, 2 * COMPUTE_TILE_BENCH_N)
	return tile.tile_map_init(m, COMPUTE_TILE_BENCH_ROWS, COMPUTE_TILE_BENCH_COLS, tile_w, tile_h)
}

_compute_tile_bench_teardown :: proc(term: ^termgrid.Terminal, r: ^render.Renderer, d: ^render.Dirty_Upload, m: ^tile.Tile_Map) {
	tile.tile_map_destroy(m)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
	_dirty_bench_teardown(term, r, d)
}

// _compute_tile_apply_trace applies trace damage: 1 typing cell, 2 full row,
// 3 scroll, 4 fullscreen fixture + full damage. Identical for both strategies.
_compute_tile_apply_trace :: proc(term: ^termgrid.Terminal, trace: int) {
	switch trace {
	case 1:
		termgrid.terminal_move_cursor(term, 12, 40)
		termgrid.terminal_put_char(term, 'Q')
	case 2:
		termgrid.damage_mark_row(&term.damage, 12, 0)
	case 3:
		termgrid.terminal_move_cursor(term, 5, 0)
		termgrid.terminal_put_string(term, "hello world scroll test")
		termgrid.terminal_scroll_up(term, 1)
	case 4:
		grid := render_cell_bench_fixture()
		for i in 0..<COMPUTE_TILE_BENCH_N {
			termgrid.grid_set_cell(&term.grid, i / COMPUTE_TILE_BENCH_COLS, i % COMPUTE_TILE_BENCH_COLS, grid.cells[i])
		}
		for row in 0..<COMPUTE_TILE_BENCH_ROWS {
			termgrid.damage_mark_row(&term.damage, row, 0)
		}
	}
}

// _compute_tile_trace runs one trace frame under a strategy (0 instance,
// else compute at tile_w × tile_h) and returns its byte/dispatch totals.
// cpu_submit_ns covers damage apply + compile + map + upload math.
_compute_tile_trace :: proc(strategy: int, tile_w: u32, tile_h: u32, trace: int, counters: ^Compute_Tile_Counters) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	m: tile.Tile_Map
	if !_compute_tile_bench_states(&term, &r, &d, &lut, &m, tile_w, tile_h) {
		return
	}
	defer _compute_tile_bench_teardown(&term, &r, &d, &m)

	start := platform.platform_now()
	_compute_tile_apply_trace(&term, trace)
	journal := termgrid.terminal_take_damage(&term)

	bytes := 0
	dispatches: u32 = 0
	invocations: u32 = 0
	if strategy == 0 {
		ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
		_, uploaded, fell_back := render.dirty_upload_frame(&d, &r, &term, &journal, &lut, &ranges)
		if fell_back {
			render.render_compile_full_v2(&r.compiled_v2, &term)
			bg_count, glyph_count, _ := render._prepare_instances_v2(&r, &lut)
			uploaded = u64(bg_count + glyph_count) * instance.INSTANCE_STRIDE
		}
		bytes = int(uploaded)
	} else {
		if len(journal.scroll_ops) > 0 {
			render.render_compile_full_v2(&r.compiled_v2, &term)
			tile.tile_map_mark_all(&m)
		} else {
			render.render_compile_v2(&r.compiled_v2, &term, &journal, nil, nil, nil, nil, nil)
			tile.tile_map_mark_damage(&m, &journal)
		}
		ct: tile.Compute_Tile_Renderer
		ct.rows = COMPUTE_TILE_BENCH_ROWS
		ct.cols = COMPUTE_TILE_BENCH_COLS
		lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:tile.TILE_LUT_WORDS]
		bytes = int(tile.compute_tile_upload_cells(&ct, &m, r.compiled_v2.cells, lut_words, false))
		if m.count > 0 {
			dispatches = 1
			invocations = u32(m.count)
		}
	}
	termgrid.damage_journal_destroy(&journal)
	end := platform.platform_now()

	counters.cpu_submit_ns += platform.platform_ticks_to_ns(end - start)
	counters.bytes_uploaded += bytes
	counters.dispatches += dispatches
	counters.invocations += invocations
}

// bench_compare_instance_vs_compute replays T1 typing x500, T2 line x200,
// T3 scroll x100, T4 fullscreen x50 under one strategy (0 instance, else
// compute at the default 8x4) with identical seed/LUT. Totals accumulate
// into ctx (bytes_uploaded, 2 draw calls per frame); the per-trace
// breakdown lands in COMPUTE_TILE_COMPARE_TRACES for the crossover table.
bench_compare_instance_vs_compute :: proc(ctx: ^Benchmark_Context, strategy: int) {
	for ti in 0..<4 {
		counters: Compute_Tile_Counters
		for _ in 0..<COMPUTE_TILE_TRACE_REPS[ti] {
			_compute_tile_trace(strategy, tile.TILE_W_DEFAULT, tile.TILE_H_DEFAULT, ti + 1, &counters)
		}
		ctx.gpu_stats.bytes_uploaded += counters.bytes_uploaded
		ctx.gpu_stats.draw_calls += 2 * COMPUTE_TILE_TRACE_REPS[ti]
		ctx.allocation_count += COMPUTE_TILE_TRACE_REPS[ti]
		COMPUTE_TILE_COMPARE_TRACES[ti] = Compute_Tile_Trace_Summary{
			trace          = ti + 1,
			frames         = COMPUTE_TILE_TRACE_REPS[ti],
			bytes_uploaded = counters.bytes_uploaded,
			dispatches     = counters.dispatches,
			invocations    = counters.invocations,
			cpu_submit_ns  = counters.cpu_submit_ns,
		}
	}
}

// _compute_tile_mix runs one T1..T4 frame each at the given tile size,
// accumulating submit bytes + draws into ctx (timing via the harness).
_compute_tile_mix :: proc(ctx: ^Benchmark_Context, tile_w: u32, tile_h: u32) {
	counters: Compute_Tile_Counters
	for trace in 1..=4 {
		_compute_tile_trace(1, tile_w, tile_h, trace, &counters)
	}
	ctx.gpu_stats.bytes_uploaded += counters.bytes_uploaded
	ctx.gpu_stats.draw_calls += 2 * 4 // T1..T4, one dispatch + one blit each
	ctx.allocation_count += 4 + int(counters.dispatches)
}

bench_compute_tile_mix_4x2 :: proc(ctx: ^Benchmark_Context) {
	_compute_tile_mix(ctx, 4, 2)
}

bench_compute_tile_mix_8x4 :: proc(ctx: ^Benchmark_Context) {
	_compute_tile_mix(ctx, 8, 4)
}

bench_compute_tile_mix_8x8 :: proc(ctx: ^Benchmark_Context) {
	_compute_tile_mix(ctx, 8, 8)
}

bench_compute_tile_mix_16x4 :: proc(ctx: ^Benchmark_Context) {
	_compute_tile_mix(ctx, 16, 4)
}

bench_compute_tile_mix_16x8 :: proc(ctx: ^Benchmark_Context) {
	_compute_tile_mix(ctx, 16, 8)
}

// bench_compute_tile_size returns the sweep Benchmark for one tile size.
bench_compute_tile_size :: proc(tile_w: u32, tile_h: u32) -> Benchmark {
	if tile_w == 4 && tile_h == 2 {
		return Benchmark{name = "compute_tile_4x2", run = bench_compute_tile_mix_4x2, iterations = 100}
	}
	if tile_w == 8 && tile_h == 8 {
		return Benchmark{name = "compute_tile_8x8", run = bench_compute_tile_mix_8x8, iterations = 100}
	}
	if tile_w == 16 && tile_h == 4 {
		return Benchmark{name = "compute_tile_16x4", run = bench_compute_tile_mix_16x4, iterations = 100}
	}
	if tile_w == 16 && tile_h == 8 {
		return Benchmark{name = "compute_tile_16x8", run = bench_compute_tile_mix_16x8, iterations = 100}
	}
	return Benchmark{name = "compute_tile_8x4", run = bench_compute_tile_mix_8x4, iterations = 100}
}

// compute_tile_bench_all returns the tile-size sweep Benchmarks.
compute_tile_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 5)
	benches[0] = bench_compute_tile_size(4, 2)
	benches[1] = bench_compute_tile_size(8, 4)
	benches[2] = bench_compute_tile_size(8, 8)
	benches[3] = bench_compute_tile_size(16, 4)
	benches[4] = bench_compute_tile_size(16, 8)
	return benches
}

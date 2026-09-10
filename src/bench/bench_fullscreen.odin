package bench

// Phase 15 fullscreen three-way benchmark: T1 typing / T2 line / T3 scroll /
// T4 fullscreen traces replayed under all three strategies with identical
// seed/LUT, plus a damage-extent sweep for the Phase 16 crossover table.
//
// Byte-count rule: instance bytes = dirty-upload range bytes (2 draws per
// frame; scroll falls back to the dense legacy upload); compute bytes =
// dirty cell ranges + tile-list bytes (count*4) + LUT when rebuilt
// (1 dispatch + 1 blit per non-empty frame); fullscreen bytes = full-grid
// N*8 + LUT when rebuilt on non-empty frames, 0 on empty frames (1 draw,
// full-pixel shade).
//
// Pixels: fullscreen shades fb_w*fb_h per non-empty frame; instance shades
// one cell rect per uploaded instance; compute shades its dirty tiles.

import render "../render"
import fullscreen "../render/fullscreen"
import instance "../render/instance"
import tile "../render/tile"
import termgrid "../terminal"
import "../platform"

FULLSCREEN_BENCH_ROWS :: 24
FULLSCREEN_BENCH_COLS :: 80
FULLSCREEN_BENCH_N :: FULLSCREEN_BENCH_ROWS * FULLSCREEN_BENCH_COLS

// FULLSCREEN_BENCH_CELL_W/H are the bench cell pixel dimensions; the bench
// framebuffer shades 640x384 = 245760 pixels per fullscreen frame.
FULLSCREEN_BENCH_CELL_W :: 8
FULLSCREEN_BENCH_CELL_H :: 16
FULLSCREEN_BENCH_FB_W :: FULLSCREEN_BENCH_COLS * FULLSCREEN_BENCH_CELL_W
FULLSCREEN_BENCH_FB_H :: FULLSCREEN_BENCH_ROWS * FULLSCREEN_BENCH_CELL_H
FULLSCREEN_BENCH_FB_PIXELS :: FULLSCREEN_BENCH_FB_W * FULLSCREEN_BENCH_FB_H
FULLSCREEN_BENCH_CELL_PIXELS :: FULLSCREEN_BENCH_CELL_W * FULLSCREEN_BENCH_CELL_H

// Fullscreen_Counters accumulates one strategy's submit-side totals.
Fullscreen_Counters :: struct {
	cpu_submit_ns:  i64,
	bytes_uploaded: int,
	pixels_shaded:  u64,
	draws:          u32,
}

// Fullscreen_Trace_Summary is one trace's three-way row (Phase 16 handoff).
Fullscreen_Trace_Summary :: struct {
	trace:          int,
	frames:         int,
	bytes_uploaded: int,
	pixels_shaded:  u64,
	draws:          u32,
	cpu_submit_ns:  i64,
}

// FULLSCREEN_COMPARE_TRACES holds the latest bench_compare_three_way
// per-trace breakdown (T1..T4 at indices 0..3) for the crossover table.
FULLSCREEN_COMPARE_TRACES: [4]Fullscreen_Trace_Summary

// FULLSCREEN_TRACE_REPS is the per-trace frame count (T1..T4).
FULLSCREEN_TRACE_REPS := [4]int{500, 200, 100, 50}

// FULLSCREEN_DAMAGE_SWEEP is the damage-extent sweep set (percent of grid).
FULLSCREEN_DAMAGE_SWEEP := [6]int{1, 4, 10, 25, 50, 100}

// Fullscreen_Crossover_Row is one damage-extent row: per-strategy submit
// bytes for a single frame at pct% damage (Phase 16 handoff; table only,
// no selector logic).
Fullscreen_Crossover_Row :: struct {
	pct:              int,
	instance_bytes:   int,
	compute_bytes:    int,
	fullscreen_bytes: int,
}

// FULLSCREEN_CROSSOVER holds the latest bench_fullscreen_crossover rows.
FULLSCREEN_CROSSOVER: [6]Fullscreen_Crossover_Row

// _fullscreen_bench_states builds CPU-only renderer + terminal + dirty +
// tile map states sharing one deterministic LUT (nil backend: byte math
// only, no GPU work).
_fullscreen_bench_states :: proc(
	term: ^termgrid.Terminal,
	r: ^render.Renderer,
	d: ^render.Dirty_Upload,
	lut: ^render.Style_LUT,
	m: ^tile.Tile_Map,
) -> bool {
	_dirty_bench_setup(term, r, d, lut)
	r.instances.max_instances = u32(2 * FULLSCREEN_BENCH_N)
	r.instances.instance_data = make([]instance.Instance_Data, 2 * FULLSCREEN_BENCH_N)
	return tile.tile_map_init(m, FULLSCREEN_BENCH_ROWS, FULLSCREEN_BENCH_COLS, tile.TILE_W_DEFAULT, tile.TILE_H_DEFAULT)
}

_fullscreen_bench_teardown :: proc(term: ^termgrid.Terminal, r: ^render.Renderer, d: ^render.Dirty_Upload, m: ^tile.Tile_Map) {
	tile.tile_map_destroy(m)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
	_dirty_bench_teardown(term, r, d)
}

// _fullscreen_journal_has_damage mirrors the renderer skip gate: any full
// row, span, or scroll op counts as damage.
_fullscreen_journal_has_damage :: proc(journal: ^termgrid.Damage_Journal) -> bool {
	for i in 0..<len(journal.dirty_rows) {
		if journal.dirty_rows[i].full || journal.dirty_rows[i].span_count > 0 {
			return true
		}
	}
	return len(journal.scroll_ops) > 0
}

// _three_way_frame runs one frame's compile + upload math under a strategy
// (0 instance, 1 compute, 2 fullscreen) and returns its submit-side totals.
_three_way_frame :: proc(
	strategy: int,
	term: ^termgrid.Terminal,
	r: ^render.Renderer,
	d: ^render.Dirty_Upload,
	lut: ^render.Style_LUT,
	m: ^tile.Tile_Map,
	journal: ^termgrid.Damage_Journal,
) -> (bytes: int, pixels: u64, draws: u32) {
	switch strategy {
	case 0:
		ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
		_, uploaded, fell_back := render.dirty_upload_frame(d, r, term, journal, lut, &ranges)
		if fell_back {
			render.render_compile_full_v2(&r.compiled_v2, term)
			bg_count, glyph_count := render._prepare_instances_v2(r, lut)
			uploaded = u64(bg_count + glyph_count) * instance.INSTANCE_STRIDE
		}
		bytes = int(uploaded)
		draws = 2
		pixels = u64(bytes) / u64(instance.INSTANCE_STRIDE) * FULLSCREEN_BENCH_CELL_PIXELS
	case 1:
		if len(journal.scroll_ops) > 0 {
			render.render_compile_full_v2(&r.compiled_v2, term)
			tile.tile_map_mark_all(m)
		} else {
			render.render_compile_v2(&r.compiled_v2, term, journal, nil, nil, nil, nil, nil)
			tile.tile_map_mark_damage(m, journal)
		}
		ct: tile.Compute_Tile_Renderer
		ct.rows = FULLSCREEN_BENCH_ROWS
		ct.cols = FULLSCREEN_BENCH_COLS
		lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:tile.TILE_LUT_WORDS]
		bytes = int(tile.compute_tile_upload_cells(&ct, m, r.compiled_v2.cells, lut_words, false))
		if m.count > 0 {
			draws = 2 // 1 dispatch + 1 blit
		}
		pixels = u64(m.count) * u64(tile.TILE_W_DEFAULT) * u64(tile.TILE_H_DEFAULT) * FULLSCREEN_BENCH_CELL_PIXELS
	case 2:
		if _fullscreen_journal_has_damage(journal) {
			if len(journal.scroll_ops) > 0 {
				render.render_compile_full_v2(&r.compiled_v2, term)
			} else {
				render.render_compile_v2(&r.compiled_v2, term, journal, nil, nil, nil, nil, nil)
			}
			fr: fullscreen.Fullscreen_Renderer
			fr.rows = FULLSCREEN_BENCH_ROWS
			fr.cols = FULLSCREEN_BENCH_COLS
			cells := transmute([]u64)r.compiled_v2.cells
			lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:fullscreen.FULLSCREEN_LUT_WORDS]
			bytes = int(fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, false))
			draws = 1
			pixels = FULLSCREEN_BENCH_FB_PIXELS
		}
	}
	return
}

// _fullscreen_trace_frame runs one trace frame under a strategy and folds
// its submit-side totals into counters. cpu_submit_ns covers damage apply
// + compile + map + upload math.
_fullscreen_trace_frame :: proc(strategy: int, trace: int, counters: ^Fullscreen_Counters) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	m: tile.Tile_Map
	if !_fullscreen_bench_states(&term, &r, &d, &lut, &m) {
		return
	}
	defer _fullscreen_bench_teardown(&term, &r, &d, &m)

	start := platform.platform_now()
	_compute_tile_apply_trace(&term, trace)
	journal := termgrid.terminal_take_damage(&term)
	bytes, pixels, draws := _three_way_frame(strategy, &term, &r, &d, &lut, &m, &journal)
	termgrid.damage_journal_destroy(&journal)
	end := platform.platform_now()

	counters.cpu_submit_ns += platform.platform_ticks_to_ns(end - start)
	counters.bytes_uploaded += bytes
	counters.pixels_shaded += pixels
	counters.draws += draws
}

// bench_compare_three_way replays T1 typing x500, T2 line x200, T3 scroll
// x100, T4 fullscreen x50 under one strategy (0 instance, 1 compute,
// 2 fullscreen) with identical seed/LUT. Totals accumulate into ctx; the
// per-trace breakdown lands in FULLSCREEN_COMPARE_TRACES for the crossover
// table.
bench_compare_three_way :: proc(ctx: ^Benchmark_Context, strategy: int) {
	for ti in 0..<4 {
		counters: Fullscreen_Counters
		for _ in 0..<FULLSCREEN_TRACE_REPS[ti] {
			_fullscreen_trace_frame(strategy, ti + 1, &counters)
		}
		ctx.gpu_stats.bytes_uploaded += counters.bytes_uploaded
		ctx.gpu_stats.draw_calls += int(counters.draws)
		ctx.allocation_count += FULLSCREEN_TRACE_REPS[ti]
		FULLSCREEN_COMPARE_TRACES[ti] = Fullscreen_Trace_Summary{
			trace          = ti + 1,
			frames         = FULLSCREEN_TRACE_REPS[ti],
			bytes_uploaded = counters.bytes_uploaded,
			pixels_shaded  = counters.pixels_shaded,
			draws          = counters.draws,
			cpu_submit_ns  = counters.cpu_submit_ns,
		}
	}
}

// _fullscreen_sweep_frame builds one frame at pct% damage (first k rows
// full) and returns its per-strategy submit bytes (no timing).
_fullscreen_sweep_frame :: proc(strategy: int, pct: int) -> (bytes: int, pixels: u64, draws: u32) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	m: tile.Tile_Map
	if !_fullscreen_bench_states(&term, &r, &d, &lut, &m) {
		return 0, 0, 0
	}
	defer _fullscreen_bench_teardown(&term, &r, &d, &m)

	k := max(1, pct * FULLSCREEN_BENCH_ROWS / 100)
	for row in 0..<k {
		termgrid.damage_mark_row(&term.damage, row, 0)
	}
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)
	return _three_way_frame(strategy, &term, &r, &d, &lut, &m, &journal)
}

// bench_fullscreen_crossover runs the damage-extent sweep once per strategy
// and fills FULLSCREEN_CROSSOVER with per-% submit bytes. Table only: the
// crossover % (lowest % where fullscreen beats instance AND compute) is
// read off the table by Phase 16; no selector logic lives here.
bench_fullscreen_crossover :: proc(ctx: ^Benchmark_Context) {
	for si in 0..<len(FULLSCREEN_DAMAGE_SWEEP) {
		pct := FULLSCREEN_DAMAGE_SWEEP[si]
		ib, _, _ := _fullscreen_sweep_frame(0, pct)
		cb, _, _ := _fullscreen_sweep_frame(1, pct)
		fb, _, _ := _fullscreen_sweep_frame(2, pct)
		FULLSCREEN_CROSSOVER[si] = Fullscreen_Crossover_Row{
			pct              = pct,
			instance_bytes   = ib,
			compute_bytes    = cb,
			fullscreen_bytes = fb,
		}
		ctx.gpu_stats.bytes_uploaded += ib + cb + fb
		ctx.allocation_count += 3
	}
}

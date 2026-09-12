package bench

// Phase 12 async raster benchmarks: cold-miss storm compile (Phase-11 sync
// vs Phase-12 async) over a full 80x25 grid of distinct non-ASCII cells,
// plus a separately reported pop-in drain cycle and the ASCII gate pair.
//
// Gates: async >= 10x sync, async absolute < 2ms, ASCII ctx within ±10% of
// the legacy baseline. Drain + upload are reported separately from compile.

import "core:fmt"
import "core:time"
import thread "core:thread"
import render "../render"
import termgrid "../terminal"

RASTER_STORM_ROWS :: 25
RASTER_STORM_COLS :: 80
RASTER_STORM_N :: RASTER_STORM_ROWS * RASTER_STORM_COLS

RASTER_BENCH_PRIMARY :: "/System/Library/Fonts/Menlo.ttc"
RASTER_BENCH_ARABIC  :: "/System/Library/Fonts/GeezaPro.ttc"
RASTER_BENCH_CJK     :: "/System/Library/Fonts/Hiragino Sans GB.ttc"

// Package-level shared state, built lazily once.
_ra_ready:  bool
_ra_prim:   render.Font_Rasterizer
_ra_chain:  render.Fallback_Chain
_ra_atlas:  render.Atlas
_ra_storm:  termgrid.Terminal
_ra_drain_keys: [256]rune
_ra_drain_fi:   [256]int

// _ra_ensure loads fonts + atlas + the 2000-distinct storm fixture once.
_ra_ensure :: proc() {
	if _ra_ready {
		return
	}
	_ra_ready = true
	if render.font_rasterizer_init(&_ra_prim, RASTER_BENCH_PRIMARY, 16.0, nil) {
		paths := [2]string{RASTER_BENCH_ARABIC, RASTER_BENCH_CJK}
		render.fallback_chain_init(&_ra_chain, &_ra_prim, paths[:], 16.0, context.allocator)
		render.atlas_init(&_ra_atlas, &_ra_prim)
		render.atlas_prewarm_chain(&_ra_atlas, &_ra_chain)
	} else {
		render.atlas_init(&_ra_atlas, &_ra_prim)
	}
	termgrid.terminal_init(&_ra_storm, RASTER_STORM_ROWS, RASTER_STORM_COLS)
	i := 0
	for r in 0..<RASTER_STORM_ROWS {
		for c in 0..<RASTER_STORM_COLS {
			termgrid.grid_set_cell(&_ra_storm.grid, r, c, termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(rune(0x4E00 + i)), style = 0, width = 1,
			})
			i += 1
		}
	}
	// 256 covered keys (with resolving slots) for the drain cycle.
	found := 0
	for cp := rune(0x4E00); cp < 0x6000 && found < len(_ra_drain_keys); cp += 1 {
		if fi, covered := render.fallback_resolve(&_ra_chain, u32(cp), nil); covered {
			_ra_drain_keys[found] = cp
			_ra_drain_fi[found] = fi
			found += 1
		}
	}
}

// _ra_cold resets cache + dynamic region: the next compile misses everywhere.
_ra_cold :: proc(cache: ^render.Shape_Cache, counters: ^render.Fallback_Counters) {
	cache^ = render.Shape_Cache{}
	counters^ = render.Fallback_Counters{}
	_ra_atlas.fallback_cursor = 0
	for i in 0..<render.FALLBACK_SLOT_COUNT {
		_ra_atlas.fallback_tag[i] = 0
		_ra_atlas.fallback_fifo[i] = 0
	}
}

// bench_raster_storm_sync compiles the cold storm through the Phase-11
// sync path (resolve + rasterize per cell).
bench_raster_storm_sync :: proc(ctx: ^Benchmark_Context) {
	_ra_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_ra_cold(&cache, &counters)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, RASTER_STORM_ROWS, RASTER_STORM_COLS)
	defer render.render_compiler_destroy_v2(&frame)
	render.render_compile_full_v2(&frame, &_ra_storm, &_ra_chain, &cache, &_ra_atlas, &counters)
	ctx.allocation_count += int(frame.cell_count)
}

// bench_raster_storm_async compiles the cold storm through the Phase-12
// async path (resolve + enqueue/drop per cell, no rasterize). The queue is
// workerless: this measures exactly what the render thread pays per frame.
bench_raster_storm_async :: proc(ctx: ^Benchmark_Context) {
	_ra_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_ra_cold(&cache, &counters)
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	render.raster_queue_init(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, RASTER_STORM_ROWS, RASTER_STORM_COLS)
	defer render.render_compiler_destroy_v2(&frame)
	render.render_compile_full_v2(&frame, &_ra_storm, &_ra_chain, &cache, &_ra_atlas, &counters, &q)
	ctx.allocation_count += int(frame.cell_count) + int(rcounters.enqueued + rcounters.overflow)
}

// raster_async_bench_all returns the Phase 12 storm benchmark rungs.
raster_async_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 2)
	benches[0] = Benchmark{name = "raster_storm_sync", run = bench_raster_storm_sync, iterations = 5}
	benches[1] = Benchmark{name = "raster_storm_async", run = bench_raster_storm_async, iterations = 20}
	return benches
}

// raster_ascii_gate_all re-exports the Phase 11 ASCII regression pair so
// the gate is measured in the same build as the storm rungs.
raster_ascii_gate_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 2)
	benches[0] = Benchmark{name = "fallback_ascii_ctx", run = bench_fallback_ascii_ctx, iterations = 50}
	benches[1] = Benchmark{name = "fallback_ascii_legacy", run = bench_fallback_ascii_legacy, iterations = 50}
	return benches
}

// _ra_popin_drain_ns runs one full pop-in cycle (enqueue 256 with a live
// worker, wait, drain into the atlas) and returns the drain-only time in
// nanoseconds plus the drained count. Worker rasterize time is excluded by
// construction (the wait sits outside the timer); GPU upload is N/A in a
// headless bench (atlas_upload_gpu no-ops without a backend).
_ra_popin_drain_ns :: proc() -> (drain_ns: f64, applied: int) {
	_ra_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_ra_cold(&cache, &counters)
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	render.raster_queue_init(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &_ra_chain)
	for i in 0..<len(_ra_drain_keys) {
		k := render.Cluster_Key{base = _ra_drain_keys[i], join_form = .Isolated}
		for render.raster_request_async(&q, k, _ra_drain_fi[i], u32(_ra_drain_keys[i]), nil, true, termgrid.Damage_Target{}) != .Enqueued {
			thread.yield()
		}
	}
	for {
		reqs, _ := render.raster_pending_count(&q)
		if reqs == 0 {
			break
		}
		thread.yield()
	}
	start := time.tick_now()
	applied = render.raster_drain_completions(&q, &_ra_atlas, &cache, nil, &_ra_chain, &counters)
	drain_ns = f64(time.tick_since(start))
	// Settle: the last pop-to-push may still be in flight when reqs hits
	// zero; retry until the queues are empty (drain calls only on timer).
	for {
		reqs, comps := render.raster_pending_count(&q)
		if reqs == 0 && comps == 0 {
			break
		}
		start = time.tick_now()
		applied += render.raster_drain_completions(&q, &_ra_atlas, &cache, nil, &_ra_chain, &counters)
		drain_ns += f64(time.tick_since(start))
	}
	render.raster_worker_shutdown(&q)
	return drain_ns, applied
}

// raster_async_bench_report formats the storm speedup rows, the absolute
// gate, the separately reported pop-in drain, and the ASCII gate.
// The caller owns the returned string.
raster_async_bench_report :: proc(results: []Benchmark_Result) -> string {
	out := fmt.aprintf(
		"Async raster rows (cold-miss storm, 25x80 distinct non-ASCII):\n" +
		"  gates: async >= 10x sync | async absolute < 2ms | ascii_ctx within ±10%% of legacy\n",
	)
	sync_mean, async_mean := 0.0, 0.0
	for &r in results {
		line := fmt.aprintf("  %-22s mean %10.1fns p95 %10.1fns iters %d\n", r.name, r.stats.mean, r.stats.p95, r.iterations)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
		if r.name == "raster_storm_sync" {
			sync_mean = r.stats.mean
		}
		if r.name == "raster_storm_async" {
			async_mean = r.stats.mean
		}
	}
	if sync_mean > 0 && async_mean > 0 {
		line := fmt.aprintf(
			"  storm speedup x%.1f (sync %.2fms vs async %.3fms)\n",
			sync_mean / async_mean, sync_mean / 1e6, async_mean / 1e6,
		)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
	}
	drain_ns, applied := _ra_popin_drain_ns()
	line := fmt.aprintf(
		"  pop-in drain (separate): %.1fµs for %d completions (excludes worker rasterize; GPU upload N/A headless)\n",
		drain_ns / 1e3, applied,
	)
	next := fmt.aprintf("%s%s", out, line)
	delete(out)
	delete(line)
	out = next
	return out
}

package bench

// Phase 11 fallback/shaping benchmarks: cold miss cost vs hot hit cost per
// script (CJK, Arabic, emoji, Indic), plus the ASCII-with-context regression
// comparator (gate: within ±10% of the legacy compile_full_v2 baseline).
//
// Cold rungs reset the shape cache + dynamic region every call (every cell
// pays resolve+rasterize); hot rungs reuse warmed package state (every cell
// pays lookup+expand). The Indic row is deferred-honest: no conjunct
// shaping exists, so it measures the logical-unshaped/tofu path as-is.

import "core:fmt"
import render "../render"
import termgrid "../terminal"

FALLBACK_BENCH_ROWS :: 24
FALLBACK_BENCH_COLS :: 80
FALLBACK_BENCH_N :: FALLBACK_BENCH_ROWS * FALLBACK_BENCH_COLS

FALLBACK_BENCH_PRIMARY :: "/System/Library/Fonts/Menlo.ttc"
FALLBACK_BENCH_ARABIC  :: "/System/Library/Fonts/GeezaPro.ttc"
FALLBACK_BENCH_CJK     :: "/System/Library/Fonts/Hiragino Sans GB.ttc"

// Package-level shared state, built lazily once. Terminals hold the script
// fixtures; the atlas carries pixels across calls; chain holds the fonts.
_fb_ready: bool
_fb_prim:  render.Font_Rasterizer
_fb_chain: render.Fallback_Chain
_fb_atlas: render.Atlas
_fb_cjk:   termgrid.Terminal
_fb_arab:  termgrid.Terminal
_fb_emoji: termgrid.Terminal
_fb_indic: termgrid.Terminal
_fb_ascii: termgrid.Terminal

// _fb_wide_pair writes a wide lead + continuation pair at (row, col).
_fb_wide_pair :: proc(t: ^termgrid.Terminal, row, col: int, cp: rune) {
	termgrid.grid_set_cell(&t.grid, row, col, termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(cp), style = 0, width = 2,
	})
	termgrid.grid_set_cell(&t.grid, row, col + 1, termgrid.Semantic_Cell{
		content = 0, style = 0, width = 1, flags = .Wide_Continuation,
	})
}

// _fb_fill builds the five fixture grids once. Non-ASCII grids use many
// distinct codepoints so cold rungs pay per-glyph miss cost (resolve +
// rasterize) instead of amortizing one glyph over the grid.
_fb_fill :: proc() {
	termgrid.terminal_init(&_fb_cjk, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	k := 0
	for r in 0..<FALLBACK_BENCH_ROWS {
		c := 0
		for c + 1 < FALLBACK_BENCH_COLS {
			// 192 distinct glyphs: fits the 241-slot dynamic region, so the
			// hot rung measures pure lookup hits (larger sets thrash FIFO
			// by design; that path is unit-tested, not benched).
			_fb_wide_pair(&_fb_cjk, r, c, rune(0x4E00 + (k % 192)))
			k += 1
			c += 2
		}
	}

	arab_letters := [10]rune{0x0628, 0x062A, 0x062B, 0x062C, 0x0633, 0x0634, 0x0644, 0x0645, 0x0642, 0x0627}
	termgrid.terminal_init(&_fb_arab, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	for r in 0..<FALLBACK_BENCH_ROWS {
		for c in 0..<FALLBACK_BENCH_COLS {
			cp := arab_letters[(r * FALLBACK_BENCH_COLS + c) % len(arab_letters)]
			if c % 4 == 3 {
				cp = rune(0x20)
			}
			termgrid.grid_set_cell(&_fb_arab.grid, r, c, termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(cp), style = 0, width = 1,
			})
		}
	}

	termgrid.terminal_init(&_fb_emoji, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	k = 0
	for r in 0..<FALLBACK_BENCH_ROWS {
		c := 0
		for c + 1 < FALLBACK_BENCH_COLS {
			_fb_wide_pair(&_fb_emoji, r, c, rune(0x1F600 + (k % 64)))
			k += 1
			c += 2
		}
	}

	// Indic deferred-honest: logical KA cells, no conjunct shaping.
	termgrid.terminal_init(&_fb_indic, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	for r in 0..<FALLBACK_BENCH_ROWS {
		for c in 0..<FALLBACK_BENCH_COLS {
			cp := rune(0x0915 + ((r * FALLBACK_BENCH_COLS + c) % 64))
			termgrid.grid_set_cell(&_fb_indic.grid, r, c, termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(cp), style = 0, width = 1,
			})
		}
	}

	termgrid.terminal_init(&_fb_ascii, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	for r in 0..<FALLBACK_BENCH_ROWS {
		for c in 0..<FALLBACK_BENCH_COLS {
			termgrid.grid_set_cell(&_fb_ascii.grid, r, c, termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(rune(32 + ((r * FALLBACK_BENCH_COLS + c) % 95))),
				style   = 0,
				width   = 1,
			})
		}
	}
}

// _fb_ensure loads fonts + atlas + fixtures once. Missing fonts degrade to
// whatever subset loads (chain count shrinks, never fails).
_fb_ensure :: proc() {
	if _fb_ready {
		return
	}
	_fb_ready = true
	if render.font_rasterizer_init(&_fb_prim, FALLBACK_BENCH_PRIMARY, 16.0, nil) {
		paths := [2]string{FALLBACK_BENCH_ARABIC, FALLBACK_BENCH_CJK}
		render.fallback_chain_init(&_fb_chain, &_fb_prim, paths[:], 16.0, context.allocator)
		render.atlas_init(&_fb_atlas, &_fb_prim)
		render.atlas_prewarm_chain(&_fb_atlas, &_fb_chain)
	} else {
		render.atlas_init(&_fb_atlas, &_fb_prim)
	}
	_fb_fill()
}

// _fb_cold resets cache + dynamic region: the next compile misses everywhere.
_fb_cold :: proc(cache: ^render.Shape_Cache, counters: ^render.Fallback_Counters) {
	cache^ = render.Shape_Cache{}
	counters^ = render.Fallback_Counters{}
	_fb_atlas.fallback_cursor = 0
	for i in 0..<render.FALLBACK_SLOT_COUNT {
		_fb_atlas.fallback_tag[i] = 0
		_fb_atlas.fallback_fifo[i] = 0
	}
}

// _fb_compile compiles a fixture terminal into a fresh V2 frame.
_fb_compile :: proc(
	ctx: ^Benchmark_Context,
	term: ^termgrid.Terminal,
	cache: ^render.Shape_Cache,
	counters: ^render.Fallback_Counters,
) {
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	defer render.render_compiler_destroy_v2(&frame)
	render.render_compile_full_v2(&frame, term, &_fb_chain, cache, &_fb_atlas, counters)
	ctx.allocation_count += int(frame.cell_count)
}

// Cold rungs: every cell pays resolve + rasterize.
bench_fallback_cjk_cold :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_fb_cold(&cache, &counters)
	_fb_compile(ctx, &_fb_cjk, &cache, &counters)
}

bench_fallback_arabic_cold :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_fb_cold(&cache, &counters)
	_fb_compile(ctx, &_fb_arab, &cache, &counters)
}

bench_fallback_emoji_cold :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_fb_cold(&cache, &counters)
	_fb_compile(ctx, &_fb_emoji, &cache, &counters)
}

bench_fallback_indic_cold :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_fb_cold(&cache, &counters)
	_fb_compile(ctx, &_fb_indic, &cache, &counters)
}

// Hot rungs: warmed package caches, every call is a lookup hit.
_fb_hot_cjk_cache:    render.Shape_Cache
_fb_hot_cjk_counters: render.Fallback_Counters
_fb_hot_arab_cache:    render.Shape_Cache
_fb_hot_arab_counters: render.Fallback_Counters

bench_fallback_cjk_hot :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	_fb_compile(ctx, &_fb_cjk, &_fb_hot_cjk_cache, &_fb_hot_cjk_counters)
}

bench_fallback_arabic_hot :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	_fb_compile(ctx, &_fb_arab, &_fb_hot_arab_cache, &_fb_hot_arab_counters)
}

// ASCII regression pair: shaped-context vs legacy compile over the SAME
// fixture, so the ±10% gate compares like with like.
bench_fallback_ascii_ctx :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	_fb_compile(ctx, &_fb_ascii, &cache, &counters)
	ctx.allocation_count += int(counters.probe_miss + counters.fallback_miss)
}

// bench_fallback_ascii_legacy compiles the same ASCII fixture with nil
// fallback context (pure pack, pre-Phase-11 behavior).
bench_fallback_ascii_legacy :: proc(ctx: ^Benchmark_Context) {
	_fb_ensure()
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, FALLBACK_BENCH_ROWS, FALLBACK_BENCH_COLS)
	defer render.render_compiler_destroy_v2(&frame)
	render.render_compile_full_v2(&frame, &_fb_ascii)
	ctx.allocation_count += int(frame.cell_count)
}

// fallback_bench_all returns the Phase 11 benchmark rungs.
fallback_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 8)
	benches[0] = Benchmark{name = "fallback_cjk_cold", run = bench_fallback_cjk_cold, iterations = 10}
	benches[1] = Benchmark{name = "fallback_cjk_hot", run = bench_fallback_cjk_hot, iterations = 100}
	benches[2] = Benchmark{name = "fallback_arabic_cold", run = bench_fallback_arabic_cold, iterations = 10}
	benches[3] = Benchmark{name = "fallback_arabic_hot", run = bench_fallback_arabic_hot, iterations = 100}
	benches[4] = Benchmark{name = "fallback_emoji_cold", run = bench_fallback_emoji_cold, iterations = 10}
	benches[5] = Benchmark{name = "fallback_indic_cold", run = bench_fallback_indic_cold, iterations = 10}
	benches[6] = Benchmark{name = "fallback_ascii_ctx", run = bench_fallback_ascii_ctx, iterations = 50}
	benches[7] = Benchmark{name = "fallback_ascii_legacy", run = bench_fallback_ascii_legacy, iterations = 50}
	return benches
}

// fallback_bench_report formats cold/hot miss-cost rows plus the ASCII gate
// comparator. The caller owns the returned string.
fallback_bench_report :: proc(results: []Benchmark_Result) -> string {
	out := fmt.aprintf(
		"Fallback/shaping rows (cold miss cost vs hot hit cost, 24x80 grid):\n" +
		"  cold = fresh cache+atlas per call | hot = warmed cache | ascii_ctx gates ±10%% vs compile_full_v2\n",
	)
	for &r in results {
		line := fmt.aprintf("  %-22s mean %10.1fns p95 %10.1fns iters %d\n", r.name, r.stats.mean, r.stats.p95, r.iterations)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
	}
	return out
}

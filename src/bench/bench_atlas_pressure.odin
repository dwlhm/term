package bench

// Phase 18 Step 1: atlas pressure trace harness. Seven deterministic kinds
// replay through render_compile_full_v2 on a sliding 24x80 window with a
// drain per frame; each replay snapshots Atlas_Pressure and decides
// Keep_Fifo vs Generational via atlas_policy_decide.
//
// Capture reuses the Trace save/load round-trip: the kind's codepoint
// stream is UTF-8 encoded into a Trace, saved, loaded back, and decoded,
// so the replayed bytes are exactly what the trace layer persisted.
// The shape cache is reset per frame to isolate atlas pressure from
// shape-cache amortization (every visible glyph pays lookup every frame).

import "core:fmt"
import "core:time"
import "core:os"
import "core:unicode/utf8"
import render "../render"
import termgrid "../terminal"

// Atlas_Trace_Kind aliases the canonical render enum (atlas_policy_decide
// takes it in the render package; this alias keeps the bench-side name).
Atlas_Trace_Kind :: render.Atlas_Trace_Kind

// Atlas_Bench_Policy selects the replay path. Step 0 measures FIFO only:
// Generational replays FIFO (no policy mechanism exists until the gate
// fires and Step 2b lands).
Atlas_Bench_Policy :: enum {
	Fifo,
	Generational,
}

// Atlas_Pressure_Report is one kind's replay outcome.
Atlas_Pressure_Report :: struct {
	kind:            Atlas_Trace_Kind,
	frames:          int,
	hit_rate:        f32,
	evict_rate:      f32,
	reraster_rate:   f32,
	wraps:           u64,
	shape_evictions: u64,
	mean_compile_ns: f64,
	decision:        render.ATLAS_POLICY_DECISION,
}

PRESSURE_ROWS :: 24
PRESSURE_COLS :: 80
PRESSURE_CELLS :: PRESSURE_ROWS * PRESSURE_COLS

PRESSURE_PRIMARY :: "/System/Library/Fonts/Menlo.ttc"
PRESSURE_ARABIC  :: "/System/Library/Fonts/GeezaPro.ttc"
PRESSURE_CJK     :: "/System/Library/Fonts/Hiragino Sans GB.ttc"

// Package-level shared state, built lazily once. Fixtures own their
// Atlas/Trace per replay: the dynamic region, cache, counters, and
// pressure snapshot are reset per kind, so no cross-bench contamination.
_ap_ready:   bool
_ap_prim:    render.Font_Rasterizer
_ap_chain:   render.Fallback_Chain
_ap_atlas:   render.Atlas
_ap_reports: [7]Atlas_Pressure_Report
_ap_have:    [7]bool

// _ap_ensure loads fonts + atlas + fixtures once, then runs the one-time
// pin audit after the prewarm-chain fill.
_ap_ensure :: proc() {
	if _ap_ready {
		return
	}
	_ap_ready = true
	if render.font_rasterizer_init(&_ap_prim, PRESSURE_PRIMARY, 16.0, nil) {
		paths := [2]string{PRESSURE_ARABIC, PRESSURE_CJK}
		render.fallback_chain_init(&_ap_chain, &_ap_prim, paths[:], 16.0, context.allocator)
		render.atlas_init(&_ap_atlas, &_ap_prim)
		render.atlas_prewarm_chain(&_ap_atlas, &_ap_chain)
		render.atlas_pin_audit(&_ap_atlas, &_ap_chain)
	} else {
		render.atlas_init(&_ap_atlas, &_ap_prim)
	}
}

// _ap_frames_for returns the replay frame count per kind.
_ap_frames_for :: proc(kind: Atlas_Trace_Kind) -> int {
	switch kind {
	case .Shell, .Vim, .Htop:
		return 50
	case .Cjk_Doc, .Emoji:
		return 20
	case .Scan, .Storm:
		return 5
	}
	return 0
}

// _ap_stream builds the kind's deterministic codepoint stream
// (frames * 1920 runes). Sparse non-ASCII in shell/vim/htop mirrors real
// prompts (CJK filenames, emoji) so the pressure snapshot is non-empty;
// scan spreads 960 distinct CJK one-pass (192 new per frame); storm
// rotates a 320-set steadily (hot-set > the 241-slot region).
_ap_stream :: proc(kind: Atlas_Trace_Kind, frames: int) -> []rune {
	total := frames * PRESSURE_CELLS
	out := make([]rune, total, context.allocator)
	switch kind {
	case .Shell:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				r, c := j / PRESSURE_COLS, j % PRESSURE_COLS
				switch {
				case r == 0 && c == 0:
					out[base + j] = '$'
				case r == 0 && c == 1:
					out[base + j] = ' '
				case r == 0 && c >= 2 && c < 8:
					prompt := "ls -la"
					out[base + j] = rune(prompt[c - 2])
				case j % 97 == 0:
					out[base + j] = rune(0x4E00 + ((f * 7 + j) % 20))
				case j % 211 == 0:
					out[base + j] = rune(0x1F600 + ((f + j) % 8))
				case:
					out[base + j] = rune(32 + ((f * 131 + j) % 95))
				}
			}
		}
	case .Vim:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				r, c := j / PRESSURE_COLS, j % PRESSURE_COLS
				switch {
				case c == 0 && r < PRESSURE_ROWS - 1:
					out[base + j] = rune('0' + ((f + r) % 10))
				case r == PRESSURE_ROWS - 1 && c < 16:
					out[base + j] = rune(0xE0B0 + ((c < 8) ? 0 : 1))
				case j % 113 == 0:
					out[base + j] = rune(0x4E00 + ((f * 3 + j) % 20))
				case:
					out[base + j] = rune(32 + ((f * 37 + j * 3) % 95))
				}
			}
		}
	case .Htop:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				r, c := j / PRESSURE_COLS, j % PRESSURE_COLS
				switch {
				case c < 10 && r > 1:
					frac := (f * 13 + r * 7 + c) % 10
					if c < frac {
						out[base + j] = rune(0x2581 + (frac % 8))
					} else {
						out[base + j] = ' '
					}
				case j % 127 == 0:
					out[base + j] = rune(0x4E00 + ((f * 5 + j) % 20))
				case:
					out[base + j] = rune(32 + ((f * 17 + j * 5) % 95))
				}
			}
		}
	case .Cjk_Doc:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				if j % 40 == 39 {
					out[base + j] = rune(' ')
				} else {
					out[base + j] = rune(0x4E00 + ((f * 11 + j) % 150))
				}
			}
		}
	case .Emoji:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				if j % 24 == 23 {
					out[base + j] = rune(' ')
				} else {
					out[base + j] = rune(0x1F600 + ((f * 5 + j) % 64))
				}
			}
		}
	case .Scan:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				if j < 192 {
					out[base + j] = rune(0x4E00 + f * 192 + j)
				} else {
					out[base + j] = rune('x')
				}
			}
		}
	case .Storm:
		for f in 0..<frames {
			base := f * PRESSURE_CELLS
			for j in 0..<PRESSURE_CELLS {
				out[base + j] = rune(0x4E00 + ((f * 37 + j) % 320))
			}
		}
	}
	return out
}

// _ap_trace_roundtrip encodes runes as UTF-8 into a Trace, persists it,
// loads it back, and decodes. The returned runes are exactly what the
// trace layer persisted.
_ap_trace_roundtrip :: proc(kind: Atlas_Trace_Kind, stream: []rune) -> []rune {
	nbytes := 0
	for r in stream {
		_, n := utf8.encode_rune(r)
		nbytes += n
	}
	tr := trace_init("atlas_pressure", nbytes + 1, false)
	defer trace_destroy(&tr)
	for r in stream {
		buf, n := utf8.encode_rune(r)
		for i in 0..<n {
			trace_record(&tr, buf[i])
		}
	}
	path := fmt.aprintf("/tmp/atlas_pressure_%v.trce", kind)
	defer delete(path)
	if trace_save(&tr, path) {
		if loaded, ok := trace_load(path); ok {
			defer trace_destroy(&loaded)
			out := make([dynamic]rune, 0, len(stream), context.allocator)
			i := 0
			for i < loaded.data_count {
				r, n := utf8.decode_rune_in_bytes(loaded.data[i:loaded.data_count])
				if n <= 0 {
					r, n = 0xFFFD, 1
				}
				append(&out, r)
				i += n
			}
			os.remove(path)
			if len(out) == len(stream) {
				res := make([]rune, len(out), context.allocator)
				copy(res, out[:])
				delete(out)
				return res
			}
			delete(out)
		} else {
			os.remove(path)
		}
	}
	dup := make([]rune, len(stream), context.allocator)
	copy(dup, stream)
	return dup
}

// _ap_reset_dynamic clears the dynamic region (pinned slots persist).
_ap_reset_dynamic :: proc() {
	_ap_atlas.fallback_cursor = 0
	for i in 0..<render.FALLBACK_SLOT_COUNT {
		_ap_atlas.fallback_tag[i] = 0
		_ap_atlas.fallback_fifo[i] = 0
	}
}

// bench_atlas_pressure_replay replays one kind through Compile_V2 on a
// sliding 24x80 window with a drain per frame and returns its pressure
// report. policy is reserved for the Step 6 comparison; Step 0 always
// replays FIFO (no policy mechanism exists).
bench_atlas_pressure_replay :: proc(
	kind: Atlas_Trace_Kind,
	policy: Atlas_Bench_Policy = .Fifo,
) -> Atlas_Pressure_Report {
	_ = policy
	_ap_ensure()
	frames := _ap_frames_for(kind)

	stream := _ap_stream(kind, frames)
	defer delete(stream)
	runes := _ap_trace_roundtrip(kind, stream)
	defer delete(runes)

	_ap_reset_dynamic()
	cache: render.Shape_Cache
	counters: render.Fallback_Counters
	pressure: render.Atlas_Pressure
	_ap_atlas.pressure = &pressure
	defer _ap_atlas.pressure = nil

	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	render.raster_queue_init(&q, &rcounters)
	defer render.raster_queue_destroy(&q)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, PRESSURE_ROWS, PRESSURE_COLS)
	defer termgrid.terminal_destroy(&term)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, PRESSURE_ROWS, PRESSURE_COLS)
	defer render.render_compiler_destroy_v2(&frame)

	// Bench-side evicted-tag history for re-raster correlation (Step 0
	// has no ghost ring; history lives in the harness, never in render).
	evicted := make(map[u64]bool, context.allocator)
	defer delete(evicted)
	prev: [render.FALLBACK_SLOT_COUNT]u64

	total_ns: i64 = 0
	for f in 0..<frames {
		// Fresh cache per frame: isolates atlas pressure from
		// shape-cache amortization (every visible glyph pays lookup).
		cache = render.Shape_Cache{}

		base := f * PRESSURE_CELLS
		for j in 0..<PRESSURE_CELLS {
			termgrid.grid_set_cell(&term.grid, j / PRESSURE_COLS, j % PRESSURE_COLS, termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(runes[base + j]), style = 0, width = 1,
			})
		}
		start := time.tick_now()
		render.render_compile_full_v2(&frame, &term, &_ap_chain, &cache, &_ap_atlas, &counters)
		total_ns += i64(time.tick_since(start))
		render.raster_drain_completions(&q, &_ap_atlas, &cache, &_ap_chain, &counters)

		for i in 0..<render.FALLBACK_SLOT_COUNT {
			old, new := prev[i], _ap_atlas.fallback_tag[i]
			if old != new {
				if old != 0 {
					evicted[old] = true
				}
				if new != 0 && evicted[new] {
					render.atlas_pressure_note_reraster(&pressure)
				}
				prev[i] = new
			}
		}
	}

	rep := Atlas_Pressure_Report{
		kind            = kind,
		frames          = frames,
		hit_rate        = render.atlas_pressure_hit_rate(&pressure),
		evict_rate      = render.atlas_pressure_evict_rate(&pressure),
		reraster_rate   = render.atlas_pressure_reraster_rate(&pressure),
		wraps           = pressure.fifo_wraps,
		shape_evictions = cache.evictions,
		mean_compile_ns = f64(total_ns) / f64(frames),
		decision        = render.atlas_policy_decide(&pressure, kind),
	}
	_ap_reports[int(kind)] = rep
	_ap_have[int(kind)] = true
	return rep
}

// Cold rungs: shell/vim/htop replay 50 frames; CJK/emoji 20; scan/storm 5.
bench_atlas_pressure_shell :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Shell)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_vim :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Vim)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_htop :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Htop)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_cjk :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Cjk_Doc)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_emoji :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Emoji)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_scan :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Scan)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

bench_atlas_pressure_storm :: proc(ctx: ^Benchmark_Context) {
	rep := bench_atlas_pressure_replay(.Storm)
	ctx.allocation_count += rep.frames * PRESSURE_CELLS
}

// atlas_pressure_bench_all returns the Phase 18 pressure rungs.
atlas_pressure_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 7)
	benches[0] = Benchmark{name = "atlas_pressure_shell", run = bench_atlas_pressure_shell, iterations = 50}
	benches[1] = Benchmark{name = "atlas_pressure_vim", run = bench_atlas_pressure_vim, iterations = 50}
	benches[2] = Benchmark{name = "atlas_pressure_htop", run = bench_atlas_pressure_htop, iterations = 50}
	benches[3] = Benchmark{name = "atlas_pressure_cjk", run = bench_atlas_pressure_cjk, iterations = 20}
	benches[4] = Benchmark{name = "atlas_pressure_emoji", run = bench_atlas_pressure_emoji, iterations = 20}
	benches[5] = Benchmark{name = "atlas_pressure_scan", run = bench_atlas_pressure_scan, iterations = 5}
	benches[6] = Benchmark{name = "atlas_pressure_storm", run = bench_atlas_pressure_storm, iterations = 5}
	return benches
}

// _ap_kind_is_realistic reports whether a kind counts toward the gate.
// Scan and Storm are synthetic adversaries; only Shell/Vim/Htop/Cjk_Doc/
// Emoji can fire the generational gate.
_ap_kind_is_realistic :: proc(kind: Atlas_Trace_Kind) -> bool {
	switch kind {
	case .Shell, .Vim, .Htop, .Cjk_Doc, .Emoji:
		return true
	case .Scan, .Storm:
		return false
	}
	return false
}

// atlas_pressure_bench_report formats the per-kind pressure table plus the
// verdict line. The caller owns the returned string.
atlas_pressure_bench_report :: proc(results: []Benchmark_Result) -> string {
	out := fmt.aprintf(
		"Atlas pressure rows (Compile_V2 sliding 24x80, drain/frame, FIFO):\n" +
		"  %-8s %6s %8s %8s %8s %8s %8s %12s %s\n",
		"kind", "frames", "hit", "evict", "reraster", "wraps", "shapeEv", "meanCompile", "decision",
	)
	gate := false
	for i in 0..<len(_ap_reports) {
		if !_ap_have[i] {
			continue
		}
		rep := &_ap_reports[i]
		dec := "KEEP-FIFO"
		if rep.decision == .Generational {
			dec = "GENERATIONAL"
		} else if rep.decision == .Undecided {
			dec = "UNDECIDED"
		}
		line := fmt.aprintf(
			"  %-8v %6d %8.3f %8.3f %8.3f %8d %8d %10.1fns %s\n",
			rep.kind, rep.frames, rep.hit_rate, rep.evict_rate, rep.reraster_rate,
			rep.wraps, rep.shape_evictions, rep.mean_compile_ns, dec,
		)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
		if rep.decision == .Generational && _ap_kind_is_realistic(rep.kind) {
			gate = true
		}
	}
	verdict := "VERDICT: KEEP-FIFO (no realistic trace justifies generational; no policy code lands)"
	if gate {
		verdict = "VERDICT: GENERATIONAL-JUSTIFIED (gate fired on a realistic trace)"
	}
	next := fmt.aprintf("%s  %s\n", out, verdict)
	delete(out)
	out = next
	for &r in results {
		line := fmt.aprintf("  %-22s mean %10.1fns p95 %10.1fns iters %d\n", r.name, r.stats.mean, r.stats.p95, r.iterations)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
	}
	return out
}

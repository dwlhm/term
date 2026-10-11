package bench

// Phase 19 Step 5: SDF/MSDF generation micro-benchmarks over the 95-glyph
// ASCII set. Each rung times field generation from cached hi-res planes
// only (raster/atlas/GPU uninvolved); the MSDF rung additionally builds the
// median from its three channels on every iteration.

import sdf_experiment "../render/experiments"
import render "../render"

_SDF_BENCH_FONT :: "/System/Library/Fonts/Menlo.ttc"
_SDF_BENCH_N :: 95
_SDF_BENCH_THRESHOLD :: 0.5

// _Sdf_Bench_Glyph caches one glyph's hi-res planes: base plus the +/-1px
// horizontal probes that feed the MSDF G/B channels.
_Sdf_Bench_Glyph :: struct {
	w:    int,
	h:    int,
	base: []u8,
	gl:   []u8,
	gr:   []u8,
}

_sdf_bench_ready:  bool
_sdf_bench_glyphs: [_SDF_BENCH_N]_Sdf_Bench_Glyph
_sdf_bench_params := sdf_experiment.Sdf_Params{
	hires_px  = sdf_experiment.SDF_EXPERIMENT_HIRES_PX,
	spread_px = f32(sdf_experiment.SDF_EXPERIMENT_SPREAD_PX),
	threshold = _SDF_BENCH_THRESHOLD,
}

// _sdf_bench_ensure rasterizes the ASCII set once at hi-res and caches the
// three MSDF planes per glyph. Mirrors the _ap_ensure lazy pattern; owns no
// Atlas/GPU state.
_sdf_bench_ensure :: proc() {
	if _sdf_bench_ready {
		return
	}
	_sdf_bench_ready = true
	r: render.Font_Rasterizer
	if !render.font_rasterizer_init(&r, _SDF_BENCH_FONT, 64.0, nil, context.allocator) {
		return
	}
	defer render.font_rasterizer_destroy(&r)
	for cp in 0 ..< _SDF_BENCH_N {
		g := render.font_rasterize_glyph(&r, u32(sdf_experiment.SDF_EXPERIMENT_ASCII_LO + cp), context.allocator)
		if g.width <= 0 || g.height <= 0 || g.pixels == nil {
			if g.pixels != nil {
				delete(g.pixels, context.allocator)
			}
			continue
		}
		slot := &_sdf_bench_glyphs[cp]
		slot.w, slot.h = g.width, g.height
		slot.base = g.pixels
		slot.gl = make([]u8, len(g.pixels), context.allocator)
		slot.gr = make([]u8, len(g.pixels), context.allocator)
		for y in 0 ..< g.height {
			for x in 0 ..< g.width {
				slot.gl[y * g.width + x] = g.pixels[y * g.width + min(x + 1, g.width - 1)]
				slot.gr[y * g.width + x] = g.pixels[y * g.width + max(x - 1, 0)]
			}
		}
	}
}

// bench_sdf_generation_ascii times single-channel SDF generation over the
// cached ASCII set.
bench_sdf_generation_ascii :: proc(ctx: ^Benchmark_Context) {
	_sdf_bench_ensure()
	for cp in 0 ..< _SDF_BENCH_N {
		slot := &_sdf_bench_glyphs[cp]
		if slot.w <= 0 {
			continue
		}
		tile := sdf_experiment.sdf_generate_from_bitmap(slot.base, slot.w, slot.h, _sdf_bench_params, context.allocator)
		ctx.allocation_count += slot.w * slot.h
		delete(tile.pixels, context.allocator)
	}
}

// bench_msdf_generation_ascii times 3-channel MSDF generation over the
// cached ASCII set.
bench_msdf_generation_ascii :: proc(ctx: ^Benchmark_Context) {
	_sdf_bench_ensure()
	for cp in 0 ..< _SDF_BENCH_N {
		slot := &_sdf_bench_glyphs[cp]
		if slot.w <= 0 {
			continue
		}
		tile := sdf_experiment.msdf_generate_from_bitmap(
			slot.base,
			slot.gl,
			slot.gr,
			slot.w,
			slot.h,
			_sdf_bench_params,
			context.allocator,
		)
		ctx.allocation_count += 3 * slot.w * slot.h
		delete(tile.pixels, context.allocator)
	}
}

// sdf_bench_all returns the Phase 19 generation rungs.
sdf_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 2)
	benches[0] = Benchmark{name = "sdf_generation_ascii", run = bench_sdf_generation_ascii, iterations = 50}
	benches[1] = Benchmark{name = "msdf_generation_ascii", run = bench_msdf_generation_ascii, iterations = 20}
	return benches
}

package sdf_experiment

// Phase 19 tests: baseline self-diff, stem survival, MSDF corner
// no-regression, and the decide threshold table.

import "core:testing"
import render "../"

SDF_TEST_FONT :: "/System/Library/Fonts/Menlo.ttc"

_sdf_test_params :: proc() -> Sdf_Params {
	return Sdf_Params{
		hires_px  = SDF_EXPERIMENT_HIRES_PX,
		spread_px = f32(SDF_EXPERIMENT_SPREAD_PX),
		threshold = _SDF_THRESHOLD,
	}
}

@(test)
test_sdf_baseline_selfdiff_zero :: proc(t: ^testing.T) {
	r: render.Font_Rasterizer
	testing.expect(t, render.font_rasterizer_init(&r, SDF_TEST_FONT, 16.0, nil, context.allocator), "test font must load")
	defer render.font_rasterizer_destroy(&r)

	bad := 0
	n := 0
	for cp in SDF_EXPERIMENT_ASCII_LO ..= SDF_EXPERIMENT_ASCII_HI {
		g := render.font_rasterize_glyph(&r, u32(cp), context.allocator)
		if g.width > 0 && g.height > 0 && g.pixels != nil {
			n += 1
			slot := make([]u8, g.width * g.height, context.allocator)
			render.font_rasterize_glyph_into(&r, u32(cp), slot, g.width, 0, 0, g.width, g.height)
			d := sdf_diff_vs_reference(g.pixels, slot, g.width, g.height)
			if d.mae != 0 || d.max_err != 0 {
				bad += 1
			}
			delete(slot, context.allocator)
		}
		if g.pixels != nil {
			delete(g.pixels, context.allocator)
		}
	}
	testing.expect(t, n == 94, "94 of 95 ASCII glyphs must rasterize non-empty at 16px (space is empty)")
	testing.expect_value(t, bad, 0)
}

@(test)
test_sdf_stem_survival_il_dot :: proc(t: ^testing.T) {
	r16, r64: render.Font_Rasterizer
	testing.expect(t, render.font_rasterizer_init(&r16, SDF_TEST_FONT, 16.0, nil, context.allocator), "test font must load")
	testing.expect(t, render.font_rasterizer_init(&r64, SDF_TEST_FONT, 64.0, nil, context.allocator), "test font must load")
	defer render.font_rasterizer_destroy(&r16)
	defer render.font_rasterizer_destroy(&r64)
	params := _sdf_test_params()

	stems := [3]u32{0x69, 0x6C, 0x2E} // i, l, .
	for cp in stems {
		g16 := render.font_rasterize_glyph(&r16, cp, context.allocator)
		g64 := render.font_rasterize_glyph(&r64, cp, context.allocator)
		testing.expect(t, g16.width > 0 && g64.width > 0, "stem glyph must rasterize")
		if g16.width > 0 && g64.width > 0 && g16.pixels != nil && g64.pixels != nil {
			tile := sdf_generate_from_bitmap(g64.pixels, g64.width, g64.height, params, context.allocator)
			samp := sdf_sample_cpu(&tile, g16.width, g16.height, context.allocator)
			d := sdf_diff_vs_reference(g16.pixels, samp, g16.width, g16.height)
			testing.expect_value(t, d.stem_lost, 0)
			delete(samp, context.allocator)
			delete(tile.pixels, context.allocator)
		}
		if g16.pixels != nil {
			delete(g16.pixels, context.allocator)
		}
		if g64.pixels != nil {
			delete(g64.pixels, context.allocator)
		}
	}
}

@(test)
test_msdf_corner_no_regression :: proc(t: ^testing.T) {
	r16, r64: render.Font_Rasterizer
	testing.expect(t, render.font_rasterizer_init(&r16, SDF_TEST_FONT, 16.0, nil, context.allocator), "test font must load")
	testing.expect(t, render.font_rasterizer_init(&r64, SDF_TEST_FONT, 64.0, nil, context.allocator), "test font must load")
	defer render.font_rasterizer_destroy(&r16)
	defer render.font_rasterizer_destroy(&r64)
	params := _sdf_test_params()

	n := 0
	for cp in SDF_EXPERIMENT_CORNER_SET {
		g16 := render.font_rasterize_glyph(&r16, cp, context.allocator)
		g64 := render.font_rasterize_glyph(&r64, cp, context.allocator)
		testing.expect(t, g16.width > 0 && g64.width > 0, "corner glyph must rasterize")
		if g16.width > 0 && g64.width > 0 && g16.pixels != nil && g64.pixels != nil {
			n += 1
			tile := sdf_generate_from_bitmap(g64.pixels, g64.width, g64.height, params, context.allocator)
			ss := sdf_sample_cpu(&tile, g16.width, g16.height, context.allocator)
			ds := sdf_diff_vs_reference(g16.pixels, ss, g16.width, g16.height)
			gl := _sdf_shifted(g64.pixels, g64.width, g64.height, 1, context.allocator)
			gr := _sdf_shifted(g64.pixels, g64.width, g64.height, -1, context.allocator)
			mt := msdf_generate_from_bitmap(g64.pixels, gl, gr, g64.width, g64.height, params, context.allocator)
			ms := msdf_sample_cpu(&mt, g16.width, g16.height, context.allocator)
			dm := sdf_diff_vs_reference(g16.pixels, ms, g16.width, g16.height)
			testing.expect(t, dm.edge_mae <= ds.edge_mae*1.05 + 0.001, "MSDF corner must not regress vs SDF")
			delete(ss, context.allocator)
			delete(tile.pixels, context.allocator)
			delete(ms, context.allocator)
			delete(mt.pixels, context.allocator)
			delete(gl, context.allocator)
			delete(gr, context.allocator)
		}
		if g16.pixels != nil {
			delete(g16.pixels, context.allocator)
		}
		if g64.pixels != nil {
			delete(g64.pixels, context.allocator)
		}
	}
	testing.expect_value(t, n, len(SDF_EXPERIMENT_CORNER_SET))
}

@(test)
test_sdf_decide_thresholds :: proc(t: ^testing.T) {
	pass1 := Sdf_Diff{mae = 0.01, max_err = 12, edge_mae = 0.02, stem_lost = 0}
	pass2 := Sdf_Diff{mae = 0.005, max_err = 8, edge_mae = 0.01, stem_lost = 0}
	cost := Sdf_Cost{gen_ms_mean = 0.05, gen_ms_p95 = 0.10, atlas_bytes = 1000, shader_extra_alu = 6}

	testing.expect(t, sdf_decide(pass1, pass2, 0.045, cost) == .Retain_Sdf, "all-pass mid-band corner retains SDF")
	testing.expect(t, sdf_decide(pass1, pass2, 0.03, cost) == .Retain_Msdf, "all-pass low corner retains MSDF")

	at1 := Sdf_Diff{mae = SDF_RETAIN_MAX_MAE_1X, stem_lost = 0}
	testing.expect(t, sdf_decide(at1, pass2, 0.045, cost) == .Retain_Sdf, "mae_1x at threshold retains")
	at2 := Sdf_Diff{mae = SDF_RETAIN_MAX_MAE_2X}
	testing.expect(t, sdf_decide(pass1, at2, 0.045, cost) == .Retain_Sdf, "mae_2x at threshold retains")
	atp := Sdf_Cost{gen_ms_mean = 0.05, gen_ms_p95 = SDF_RETAIN_MAX_GEN_MS, atlas_bytes = 1000, shader_extra_alu = 6}
	testing.expect(t, sdf_decide(pass1, pass2, 0.045, atp) == .Retain_Sdf, "gen_p95 at threshold retains")

	over1 := Sdf_Diff{mae = SDF_RETAIN_MAX_MAE_1X + 0.001, stem_lost = 0}
	testing.expect(t, sdf_decide(over1, pass2, 0.045, cost) == .Discard, "mae_1x over threshold discards")
	stem := Sdf_Diff{mae = 0.01, stem_lost = 1}
	testing.expect(t, sdf_decide(stem, pass2, 0.045, cost) == .Discard, "any stem loss discards")
	over2 := Sdf_Diff{mae = SDF_RETAIN_MAX_MAE_2X + 0.001}
	testing.expect(t, sdf_decide(pass1, over2, 0.045, cost) == .Discard, "mae_2x over threshold discards")
	testing.expect(t, sdf_decide(pass1, pass2, 0.051, cost) == .Discard, "corner over SDF bar discards")
	overp := Sdf_Cost{gen_ms_mean = 0.05, gen_ms_p95 = SDF_RETAIN_MAX_GEN_MS + 0.01, atlas_bytes = 1000, shader_extra_alu = 6}
	testing.expect(t, sdf_decide(pass1, pass2, 0.045, overp) == .Discard, "gen_p95 over budget discards")
}

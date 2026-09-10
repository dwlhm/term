package sdf_experiment

// Phase 19: SDF/MSDF-vs-bitmap experiment harness.
//
// Expectation: DISCARD (close, keep bitmaps). RETAIN requires every
// pre-registered threshold in sdf_decide to hold simultaneously.
// This phase ends at the verdict line: no integration, no pipeline edits.
//
// Data flow (harness only):
//   LoadFont -> RasterHiRes -> RasterBase16 -> GenSDF -> Sample1x -> Diff1x -> Decide
//   RasterHiRes -> GenMSDF -> Sample1x
//   RasterHiRes -> RasterBase32 -> Sample2x -> Diff2x -> Decide
//   GenSDF -> Sample2x
//   GenMSDF -> Sample2x
//   GenSDF -> CostTable -> Decide
//   GenMSDF -> CostTable
//   Sample1x -> CostTable
//
// Isolation: zero writes to Atlas/slots/texture/gpu_dirty. All buffers are
// owned with the explicit allocator and freed before return (Sdf_Report
// carries scalars only). One-way dependency sdf_experiment -> render, using
// font_rasterize_glyph / font_rasterize_glyph_into as pure readers. No GPU
// state, no globals (each run owns local Font_Rasterizers, destroyed on
// return). File I/O: font read plus optional still dumps under
// /tmp/sdf_phase19/ only. Deleting src/render/experiments/ plus the bench
// file leaves zero residue.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"
import render "../"

// Glyph footprint under test (base resolution, pixels).
SDF_EXPERIMENT_GLYPH_PX :: 16
// Hi-res raster source for field generation (pixels).
SDF_EXPERIMENT_HIRES_PX :: 64
// SDF spread in hi-res pixels (half-width of the [0,1] ramp).
SDF_EXPERIMENT_SPREAD_PX :: 8
// ASCII sweep bounds, inclusive.
SDF_EXPERIMENT_ASCII_LO :: 0x20
SDF_EXPERIMENT_ASCII_HI :: 0x7E
// Corner-stress glyphs: M, W, 7, BOX DRAWINGS LIGHT HORIZONTAL.
SDF_EXPERIMENT_CORNER_SET :: [4]u32{0x4D, 0x57, 0x37, 0x2500}
// RETAIN gates (all must hold; see sdf_decide).
SDF_RETAIN_MAX_MAE_1X :: 0.04
SDF_RETAIN_MAX_MAE_2X :: 0.02
SDF_RETAIN_MAX_GEN_MS :: 0.50

// Inside/outside classification threshold, normalized (maps to 128/255).
_SDF_THRESHOLD :: 0.5
// Chamfer 3-4 diagonal weight (sqrt(2)).
_SDF_DIAG :: 1.41421356
// Stored-tile padding per side, in base pixels (bilinear edge guard).
_SDF_STORE_PAD :: 2
// Corner bar for the SDF allowance: any retained field must clear it.
_SDF_RETAIN_MAX_CORNER_SDF :: 0.05
// MSDF sub-bar: 20% better than the SDF allowance elects Retain_Msdf.
_SDF_RETAIN_MAX_CORNER_MSDF :: 0.04
// Worst-case emulated shader delta vs fs_main single-fetch (MSDF:
// smoothstep + median3). SDF-only would be 3 (smoothstep).
_SDF_SHADER_EXTRA_ALU_MSDF :: 6
// Still-dump directory (sole write target besides stdout).
_SDF_STILL_DIR :: "/tmp/sdf_phase19/"
// Spot-check codepoints, informational only (never gate): CJK, emoji, Arabic.
_SDF_SPOT_SET :: [3]u32{0x4E00, 0x1F600, 0x0628}
// HiDPI leg base size (the 2x raster); ratios derive from the size consts.
_SDF_HIDPI_PX :: 32
_SDF_RATIO_1X :: f32(SDF_EXPERIMENT_HIRES_PX) / f32(SDF_EXPERIMENT_GLYPH_PX)
_SDF_RATIO_2X :: f32(SDF_EXPERIMENT_HIRES_PX) / f32(_SDF_HIDPI_PX)

// Sdf_Params configures field generation.
Sdf_Params :: struct {
	hires_px:  int, // hi-res source size (informational; caller rasters it)
	spread_px: f32, // spread in hi-res pixels
	threshold: f32, // normalized inside threshold
}

// Sdf_Tile is a single-channel field, values map 0..255 <-> 0..1.
Sdf_Tile :: struct {
	width:  int,
	height: int,
	spread: f32,
	pixels: []u8,
}

// Msdf_Tile is a 3-channel field, interleaved RGB, 0..255 <-> 0..1.
Msdf_Tile :: struct {
	width:  int,
	height: int,
	spread: f32,
	pixels: []u8,
}

// Sdf_Diff compares a resampled field against a reference bitmap.
// `a` is the reference, `b` is the sample.
Sdf_Diff :: struct {
	mae:       f32, // mean |ref-samp|/255 over all pixels
	max_err:   u8, // worst single-pixel |ref-samp|
	edge_mae:  f32, // MAE over edge pixels only (ref alpha in (16,235))
	stem_lost: int, // pixels with ref>200 but samp<64 (dropout count)
}

// Sdf_Cost is the generation/atlas/shader table for Decide.
Sdf_Cost :: struct {
	gen_ms_mean:     f64, // per-glyph generation mean, ms (worst of SDF/MSDF)
	gen_ms_p95:      f64, // per-glyph generation p95, ms (worst of SDF/MSDF)
	atlas_bytes:     int, // SDF stored bytes, 1ch (MSDF ~= 3x; see verdict line)
	shader_extra_alu: int, // emulated ALU delta vs fs_main single-fetch
}

// Sdf_Verdict is the terminal Decide outcome.
Sdf_Verdict :: enum {
	Discard,
	Retain_Sdf,
	Retain_Msdf,
}

// Sdf_Report is the full Decide input plus the verdict.
Sdf_Report :: struct {
	diff_1x:    Sdf_Diff,
	diff_2x:    Sdf_Diff,
	corner_mae: f32, // winning corner MAE (MSDF iff >=20% better than SDF)
	cost:       Sdf_Cost,
	verdict:    Sdf_Verdict,
}

// _Sdf_Acc accumulates one diff over many variable-size glyph pairs.
_Sdf_Acc :: struct {
	abs_sum:   f64,
	n:         i64,
	edge_sum:  f64,
	edge_n:    i64,
	max_err:   u8,
	stem_lost: int,
}

_sdf_acc_add :: proc(ac: ^_Sdf_Acc, ref: []u8, samp: []u8) {
	n := min(len(ref), len(samp))
	for i in 0 ..< n {
		ad := abs(int(ref[i]) - int(samp[i]))
		ac.abs_sum += f64(ad)
		ac.n += 1
		if u8(ad) > ac.max_err {
			ac.max_err = u8(ad)
		}
		if ref[i] > 16 && ref[i] < 235 {
			ac.edge_sum += f64(ad)
			ac.edge_n += 1
		}
		if ref[i] > 200 && samp[i] < 64 {
			ac.stem_lost += 1
		}
	}
}

_sdf_acc_diff :: proc(ac: ^_Sdf_Acc) -> Sdf_Diff {
	d := Sdf_Diff{max_err = ac.max_err, stem_lost = ac.stem_lost}
	if ac.n > 0 {
		d.mae = f32(ac.abs_sum / 255.0 / f64(ac.n))
	}
	if ac.edge_n > 0 {
		d.edge_mae = f32(ac.edge_sum / 255.0 / f64(ac.edge_n))
	}
	return d
}

// _sdf_chamfer computes the 3-4 chamfer distance to the nearest set pixel:
// dist is 0 where zero_where != 0, else the distance to the nearest set
// pixel. Forward + backward passes (two-pass chamfer EDT).
_sdf_chamfer :: proc(zero_where: []u8, w: int, h: int, dist: []f32) {
	INF := f32(w * h + w + h)
	for i in 0 ..< w * h {
		if zero_where[i] != 0 {
			dist[i] = 0
		} else {
			dist[i] = INF
		}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			i := y * w + x
			if dist[i] == 0 {
				continue
			}
			best := dist[i]
			if x > 0 {
				best = min(best, dist[i - 1] + 1)
			}
			if y > 0 {
				best = min(best, dist[i - w] + 1)
				if x > 0 {
					best = min(best, dist[i - w - 1] + _SDF_DIAG)
				}
				if x < w - 1 {
					best = min(best, dist[i - w + 1] + _SDF_DIAG)
				}
			}
			dist[i] = best
		}
	}
	y := h - 1
	for y >= 0 {
		x := w - 1
		for x >= 0 {
			i := y * w + x
			if dist[i] != 0 {
				best := dist[i]
				if x < w - 1 {
					best = min(best, dist[i + 1] + 1)
				}
				if y < h - 1 {
					best = min(best, dist[i + w] + 1)
					if x < w - 1 {
						best = min(best, dist[i + w + 1] + _SDF_DIAG)
					}
					if x > 0 {
						best = min(best, dist[i + w - 1] + _SDF_DIAG)
					}
				}
				dist[i] = best
			}
			x -= 1
		}
		y -= 1
	}
}

// sdf_generate_from_bitmap builds a single-channel SDF from a hi-res
// grayscale bitmap (brute-force two-pass chamfer; 95 ASCII only per harness).
// Inside (hi >= threshold) ramps 0.5->1 over +spread; outside ramps 0.5->0.
sdf_generate_from_bitmap :: proc(
	hi: []u8,
	w: int,
	h: int,
	params: Sdf_Params,
	allocator: runtime.Allocator,
) -> Sdf_Tile {
	tile := Sdf_Tile{width = w, height = h, spread = params.spread_px}
	n := w * h
	if w <= 0 || h <= 0 || len(hi) < n {
		return tile
	}
	out := make([]u8, n, allocator)
	tile.pixels = out
	thr := u8(params.threshold * 255.0)
	if params.spread_px <= 0 {
		for i in 0 ..< n {
			out[i] = 255 if hi[i] >= thr else 0
		}
		return tile
	}
	inner := make([]u8, n, allocator)
	defer delete(inner, allocator)
	outer := make([]u8, n, allocator)
	defer delete(outer, allocator)
	inside_n := 0
	for i in 0 ..< n {
		if hi[i] >= thr {
			inner[i] = 1
			inside_n += 1
		} else {
			outer[i] = 1
		}
	}
	if inside_n == 0 {
		return tile
	}
	if inside_n == n {
		for i in 0 ..< n {
			out[i] = 255
		}
		return tile
	}
	d_in := make([]f32, n, allocator)
	defer delete(d_in, allocator)
	d_out := make([]f32, n, allocator)
	defer delete(d_out, allocator)
	_sdf_chamfer(outer, w, h, d_in)
	_sdf_chamfer(inner, w, h, d_out)
	inv := 1.0 / (2.0 * params.spread_px)
	for i in 0 ..< n {
		v := 0.5 + d_in[i] * inv if inner[i] != 0 else 0.5 - d_out[i] * inv
		out[i] = u8(clamp(v, 0.0, 1.0) * 255.0 + 0.5)
	}
	return tile
}

// msdf_generate_from_bitmap builds a 3-channel pseudo-MSDF from three hi-res
// planes (R/G/B classifications; the harness derives G/B as +/-1px probes of
// the same raster). No vector source exists here (analytic work is an explicit
// non-goal); the median of the three channels still disambiguates corners
// better than any single threshold, which is what the corner leg measures.
msdf_generate_from_bitmap :: proc(
	hi_r: []u8,
	hi_g: []u8,
	hi_b: []u8,
	w: int,
	h: int,
	params: Sdf_Params,
	allocator: runtime.Allocator,
) -> Msdf_Tile {
	tile := Msdf_Tile{width = w, height = h, spread = params.spread_px}
	n := w * h
	if w <= 0 || h <= 0 || len(hi_r) < n || len(hi_g) < n || len(hi_b) < n {
		return tile
	}
	out := make([]u8, 3 * n, allocator)
	tile.pixels = out
	thr := u8(params.threshold * 255.0)
	planes := [3][]u8{hi_r, hi_g, hi_b}
	if params.spread_px <= 0 {
		for c in 0 ..< 3 {
			for i in 0 ..< n {
				out[3 * i + c] = 255 if planes[c][i] >= thr else 0
			}
		}
		return tile
	}
	inner := make([]u8, n, allocator)
	defer delete(inner, allocator)
	outer := make([]u8, n, allocator)
	defer delete(outer, allocator)
	d_in := make([]f32, n, allocator)
	defer delete(d_in, allocator)
	d_out := make([]f32, n, allocator)
	defer delete(d_out, allocator)
	inv := 1.0 / (2.0 * params.spread_px)
	for c in 0 ..< 3 {
		inside_n := 0
		for i in 0 ..< n {
			if planes[c][i] >= thr {
				inner[i] = 1
				outer[i] = 0
				inside_n += 1
			} else {
				inner[i] = 0
				outer[i] = 1
			}
		}
		if inside_n == 0 || inside_n == n {
			fill := u8(0) if inside_n == 0 else u8(255)
			for i in 0 ..< n {
				out[3 * i + c] = fill
			}
			continue
		}
		_sdf_chamfer(outer, w, h, d_in)
		_sdf_chamfer(inner, w, h, d_out)
		for i in 0 ..< n {
			v := 0.5 + d_in[i] * inv if inner[i] != 0 else 0.5 - d_out[i] * inv
			out[3 * i + c] = u8(clamp(v, 0.0, 1.0) * 255.0 + 0.5)
		}
	}
	return tile
}

// _sdf_bilinear samples one channel with clamp-to-edge bilinear filtering.
_sdf_bilinear :: proc(px: []u8, w: int, h: int, u: f32, v: f32) -> f32 {
	fx := clamp(u * f32(w) - 0.5, 0.0, f32(w - 1))
	fy := clamp(v * f32(h) - 0.5, 0.0, f32(h - 1))
	x0 := int(fx)
	y0 := int(fy)
	tx := fx - f32(x0)
	ty := fy - f32(y0)
	x1 := min(x0 + 1, w - 1)
	y1 := min(y0 + 1, h - 1)
	a := f32(px[y0 * w + x0]) / 255.0
	b := f32(px[y0 * w + x1]) / 255.0
	c := f32(px[y1 * w + x0]) / 255.0
	d := f32(px[y1 * w + x1]) / 255.0
	return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty
}

_msdf_bilinear :: proc(px: []u8, w: int, h: int, u: f32, v: f32, c: int) -> f32 {
	fx := clamp(u * f32(w) - 0.5, 0.0, f32(w - 1))
	fy := clamp(v * f32(h) - 0.5, 0.0, f32(h - 1))
	x0 := int(fx)
	y0 := int(fy)
	tx := fx - f32(x0)
	ty := fy - f32(y0)
	x1 := min(x0 + 1, w - 1)
	y1 := min(y0 + 1, h - 1)
	a := f32(px[(y0 * w + x0) * 3 + c]) / 255.0
	b := f32(px[(y0 * w + x1) * 3 + c]) / 255.0
	cc := f32(px[(y1 * w + x0) * 3 + c]) / 255.0
	d := f32(px[(y1 * w + x1) * 3 + c]) / 255.0
	return a + (b - a) * tx + (cc - a) * ty + (a - b - cc + d) * tx * ty
}

_msdf_median3 :: proc(a: f32, b: f32, c: f32) -> f32 {
	lo := min(a, min(b, c))
	hi := max(a, max(b, c))
	return a + b + c - lo - hi
}

// _sdf_coverage maps a normalized field value to output coverage, mirroring
// the candidate WGSL (sdf_candidate.wgsl): signed distance in output pixels,
// biased by half a pixel, then smoothstepped.
_sdf_coverage :: proc(v: f32, spread_hires: f32, scale: f32) -> u8 {
	d := (v - 0.5) * 2.0 * spread_hires * scale
	a := clamp(d + 0.5, 0.0, 1.0)
	a = a * a * (3.0 - 2.0 * a)
	return u8(a * 255.0 + 0.5)
}

// sdf_sample_cpu resamples a tile to out_w x out_h coverage (smoothstep
// around 0.5; bit-near candidate WGSL: sdf_candidate.wgsl fs_sdf_main).
sdf_sample_cpu :: proc(
	tile: ^Sdf_Tile,
	out_w: int,
	out_h: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if tile == nil || tile.width <= 0 || tile.height <= 0 || out_w <= 0 || out_h <= 0 {
		return nil
	}
	if len(tile.pixels) < tile.width * tile.height {
		return nil
	}
	out := make([]u8, out_w * out_h, allocator)
	scale := f32(out_w) / f32(tile.width)
	for oy in 0 ..< out_h {
		for ox in 0 ..< out_w {
			u := (f32(ox) + 0.5) / f32(out_w)
			v := (f32(oy) + 0.5) / f32(out_h)
			f := _sdf_bilinear(tile.pixels, tile.width, tile.height, u, v)
			out[oy * out_w + ox] = _sdf_coverage(f, tile.spread, scale)
		}
	}
	return out
}

// msdf_sample_cpu resamples a 3-channel tile: bilinear per channel, median,
// then the same coverage mapping (candidate WGSL: fs_msdf_main).
msdf_sample_cpu :: proc(
	tile: ^Msdf_Tile,
	out_w: int,
	out_h: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if tile == nil || tile.width <= 0 || tile.height <= 0 || out_w <= 0 || out_h <= 0 {
		return nil
	}
	if len(tile.pixels) < 3 * tile.width * tile.height {
		return nil
	}
	out := make([]u8, out_w * out_h, allocator)
	scale := f32(out_w) / f32(tile.width)
	for oy in 0 ..< out_h {
		for ox in 0 ..< out_w {
			u := (f32(ox) + 0.5) / f32(out_w)
			v := (f32(oy) + 0.5) / f32(out_h)
			r := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 0)
			g := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 1)
			b := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 2)
			out[oy * out_w + ox] = _sdf_coverage(_msdf_median3(r, g, b), tile.spread, scale)
		}
	}
	return out
}

// _sdf_sample_canvas resamples a tile onto a base-pen canvas: canvas pixel
// (cx,cy) is centered at pen (ox+cx+0.5, oy+cy+0.5), mapped into hi-pen
// space by ratio (hi_px/base_px) and offset by the hi bearing. Out-of-box
// samples clamp to the tile edge.
_sdf_sample_canvas :: proc(
	tile: ^Sdf_Tile,
	hi_bx: f32,
	hi_by: f32,
	ratio: f32,
	ox: f32,
	oy: f32,
	out_w: int,
	out_h: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if tile == nil || tile.width <= 0 || tile.height <= 0 || out_w <= 0 || out_h <= 0 || ratio <= 0 {
		return nil
	}
	if len(tile.pixels) < tile.width * tile.height {
		return nil
	}
	out := make([]u8, out_w * out_h, allocator)
	scale := 1.0 / ratio
	for cy in 0 ..< out_h {
		for cx in 0 ..< out_w {
			hx := (ox + f32(cx) + 0.5) * ratio - hi_bx
			hy := (oy + f32(cy) + 0.5) * ratio - hi_by
			u := (hx + 0.5) / f32(tile.width)
			v := (hy + 0.5) / f32(tile.height)
			f := _sdf_bilinear(tile.pixels, tile.width, tile.height, u, v)
			out[cy * out_w + cx] = _sdf_coverage(f, tile.spread, scale)
		}
	}
	return out
}

_msdf_sample_canvas :: proc(
	tile: ^Msdf_Tile,
	hi_bx: f32,
	hi_by: f32,
	ratio: f32,
	ox: f32,
	oy: f32,
	out_w: int,
	out_h: int,
	allocator: runtime.Allocator,
) -> []u8 {
	if tile == nil || tile.width <= 0 || tile.height <= 0 || out_w <= 0 || out_h <= 0 || ratio <= 0 {
		return nil
	}
	if len(tile.pixels) < 3 * tile.width * tile.height {
		return nil
	}
	out := make([]u8, out_w * out_h, allocator)
	scale := 1.0 / ratio
	for cy in 0 ..< out_h {
		for cx in 0 ..< out_w {
			hx := (ox + f32(cx) + 0.5) * ratio - hi_bx
			hy := (oy + f32(cy) + 0.5) * ratio - hi_by
			u := (hx + 0.5) / f32(tile.width)
			v := (hy + 0.5) / f32(tile.height)
			r := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 0)
			g := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 1)
			b := _msdf_bilinear(tile.pixels, tile.width, tile.height, u, v, 2)
			out[cy * out_w + cx] = _sdf_coverage(_msdf_median3(r, g, b), tile.spread, scale)
		}
	}
	return out
}

// _sdf_union_canvas computes the base-pen union box of a base bitmap and a
// hi-res bitmap (bearings in their own pixel units, ratio = hi/base).
// Returns the integer canvas origin/size; empty canvas reports w <= 0.
_sdf_union_canvas :: proc(
	base_bx: f32,
	base_by: f32,
	base_w: int,
	base_h: int,
	hi_bx: f32,
	hi_by: f32,
	hi_w: int,
	hi_h: int,
	ratio: f32,
) -> (ox: f32, oy: f32, w: int, h: int) {
	x0 := math.floor(min(base_bx, hi_bx / ratio))
	y0 := math.floor(min(base_by, hi_by / ratio))
	x1 := math.ceil(max(base_bx + f32(base_w), (hi_bx + f32(hi_w)) / ratio))
	y1 := math.ceil(max(base_by + f32(base_h), (hi_by + f32(hi_h)) / ratio))
	w = int(x1 - x0)
	h = int(y1 - y0)
	if w <= 0 || h <= 0 || w > 512 || h > 512 {
		return 0, 0, 0, 0
	}
	return x0, y0, w, h
}

// _sdf_blit places a tight bitmap into a canvas at its pen bearing.
_sdf_blit :: proc(canvas: []u8, cw: int, ch: int, ox: f32, oy: f32, g: ^render.Glyph_Bitmap) {
	dx := int(g.bearing_x - ox)
	dy := int(g.bearing_y - oy)
	for y in 0 ..< g.height {
		for x in 0 ..< g.width {
			px, py := dx + x, dy + y
			if px >= 0 && px < cw && py >= 0 && py < ch {
				canvas[py * cw + px] = g.pixels[y * g.width + x]
			}
		}
	}
}

// _sdf_leg_sdf diffs one SDF tile against its base reference on the
// bearing-registered union canvas.
_sdf_leg_sdf :: proc(
	gb: ^render.Glyph_Bitmap,
	gh: ^render.Glyph_Bitmap,
	tile: ^Sdf_Tile,
	ratio: f32,
	acc: ^_Sdf_Acc,
	allocator: runtime.Allocator,
) {
	ox, oy, w, h := _sdf_union_canvas(gb.bearing_x, gb.bearing_y, gb.width, gb.height, gh.bearing_x, gh.bearing_y, gh.width, gh.height, ratio)
	if w <= 0 {
		return
	}
	ref := make([]u8, w * h, allocator)
	defer delete(ref, allocator)
	_sdf_blit(ref, w, h, ox, oy, gb)
	samp := _sdf_sample_canvas(tile, gh.bearing_x, gh.bearing_y, ratio, ox, oy, w, h, allocator)
	defer delete(samp, allocator)
	_sdf_acc_add(acc, ref, samp)
}

// _sdf_leg_msdf diffs one MSDF tile against its base reference (same canvas).
_sdf_leg_msdf :: proc(
	gb: ^render.Glyph_Bitmap,
	gh: ^render.Glyph_Bitmap,
	tile: ^Msdf_Tile,
	ratio: f32,
	acc: ^_Sdf_Acc,
	allocator: runtime.Allocator,
) {
	ox, oy, w, h := _sdf_union_canvas(gb.bearing_x, gb.bearing_y, gb.width, gb.height, gh.bearing_x, gh.bearing_y, gh.width, gh.height, ratio)
	if w <= 0 {
		return
	}
	ref := make([]u8, w * h, allocator)
	defer delete(ref, allocator)
	_sdf_blit(ref, w, h, ox, oy, gb)
	samp := _msdf_sample_canvas(tile, gh.bearing_x, gh.bearing_y, ratio, ox, oy, w, h, allocator)
	defer delete(samp, allocator)
	_sdf_acc_add(acc, ref, samp)
}

// sdf_diff_vs_reference compares sample `b` against reference `a`
// (MAE + max + edge_mae over ref alpha in (16,235) + stem_lost where
// ref>200 but samp<64).
sdf_diff_vs_reference :: proc(a: []u8, b: []u8, w: int, h: int) -> Sdf_Diff {
	d := Sdf_Diff{}
	n := w * h
	if n <= 0 || len(a) < n || len(b) < n {
		return d
	}
	abs_sum: f64 = 0
	edge_sum: f64 = 0
	edge_n: i64 = 0
	for i in 0 ..< n {
		ad := abs(int(a[i]) - int(b[i]))
		abs_sum += f64(ad)
		if u8(ad) > d.max_err {
			d.max_err = u8(ad)
		}
		if a[i] > 16 && a[i] < 235 {
			edge_sum += f64(ad)
			edge_n += 1
		}
		if a[i] > 200 && b[i] < 64 {
			d.stem_lost += 1
		}
	}
	d.mae = f32(abs_sum / 255.0 / f64(n))
	if edge_n > 0 {
		d.edge_mae = f32(edge_sum / 255.0 / f64(edge_n))
	}
	return d
}

// sdf_decide returns RETAIN iff every pre-registered gate holds:
// mae_1x<=0.04 AND stem_lost==0 AND mae_2x<=0.02 AND corner clears the SDF
// bar (0.05) AND gen_p95<=0.50ms; the MSDF sub-bar (0.04, i.e. >=20% better
// than the SDF allowance) elects Retain_Msdf over Retain_Sdf. Else Discard.
// (The atlas-size gate, sdf_bytes < bmp32_bytes, is applied by
// sdf_experiment_run, which owns both byte totals.)
sdf_decide :: proc(
	diff_1x: Sdf_Diff,
	diff_2x: Sdf_Diff,
	corner_mae: f32,
	cost: Sdf_Cost,
) -> Sdf_Verdict {
	if diff_1x.mae > SDF_RETAIN_MAX_MAE_1X {
		return .Discard
	}
	if diff_1x.stem_lost != 0 {
		return .Discard
	}
	if diff_2x.mae > SDF_RETAIN_MAX_MAE_2X {
		return .Discard
	}
	if corner_mae > _SDF_RETAIN_MAX_CORNER_SDF {
		return .Discard
	}
	if cost.gen_ms_p95 > SDF_RETAIN_MAX_GEN_MS {
		return .Discard
	}
	if corner_mae <= _SDF_RETAIN_MAX_CORNER_MSDF {
		return .Retain_Msdf
	}
	return .Retain_Sdf
}

// _sdf_shifted builds a +/-1px horizontal probe plane of a hi-res bitmap
// (MSDF's G/B channels for the harness: directional edge disambiguation).
_sdf_shifted :: proc(hi: []u8, w: int, h: int, dx: int, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, w * h, allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			sx := clamp(x + dx, 0, w - 1)
			out[y * w + x] = hi[y * w + sx]
		}
	}
	return out
}

// _sdf_write_pgm dumps a grayscale still (P5) for offline inspection.
_sdf_write_pgm :: proc(path: string, px: []u8, w: int, h: int, allocator: runtime.Allocator) {
	if w <= 0 || h <= 0 || len(px) < w * h {
		return
	}
	hdr := fmt.aprintf("P5\n%d %d\n255\n", w, h, allocator = allocator)
	defer delete(hdr, allocator)
	data := make([]u8, len(hdr) + w * h, allocator)
	defer delete(data, allocator)
	copy(data, transmute([]u8)hdr)
	copy(data[len(hdr):], px[:w * h])
	_ = os.write_entire_file(path, data)
}

// sdf_experiment_run executes the full Phase 19 harness against font_path:
// baseline self-diff, SDF/MSDF generation, 1x/2x sampling, corner legs, cost
// table, spot checks, still dumps, and the verdict line. Owns all buffers;
// frees everything before return. Prints the VERDICT line with numbers.
sdf_experiment_run :: proc(font_path: string, allocator: runtime.Allocator) -> Sdf_Report {
	rep := Sdf_Report{verdict = .Discard}
	params := Sdf_Params{
		hires_px  = SDF_EXPERIMENT_HIRES_PX,
		spread_px = f32(SDF_EXPERIMENT_SPREAD_PX),
		threshold = _SDF_THRESHOLD,
	}

	r16, r32, r64: render.Font_Rasterizer
	ok16 := render.font_rasterizer_init(&r16, font_path, 16.0, nil, allocator)
	ok32 := render.font_rasterizer_init(&r32, font_path, 32.0, nil, allocator)
	ok64 := render.font_rasterizer_init(&r64, font_path, 64.0, nil, allocator)
	defer render.font_rasterizer_destroy(&r16)
	defer render.font_rasterizer_destroy(&r32)
	defer render.font_rasterizer_destroy(&r64)
	if !ok16 || !ok32 || !ok64 {
		fmt.printf("SDF phase19: font load failed (%s)\nVERDICT: DISCARD (font load failed)\n", font_path)
		return rep
	}

	// Step 1: skeleton + baseline (load, raster 64/16/32, self-diff green).
	acc1x, acc2x: _Sdf_Acc
	acc_sdf_corner, acc_msdf_corner: _Sdf_Acc
	worst_ms := make([dynamic]f64, 0, 128, allocator)
	defer delete(worst_ms)
	baseline_bad := 0
	ascii_n := 0
	sdf_stored := 0
	bmp32_total := 0
	for cp in SDF_EXPERIMENT_ASCII_LO ..= SDF_EXPERIMENT_ASCII_HI {
		g16 := render.font_rasterize_glyph(&r16, u32(cp), allocator)
		// Baseline: into-path must be byte-identical to the direct raster.
		if g16.width > 0 && g16.height > 0 && g16.pixels != nil {
			slot := make([]u8, g16.width * g16.height, allocator)
			render.font_rasterize_glyph_into(&r16, u32(cp), slot, g16.width, 0, 0, g16.width, g16.height)
			for i in 0 ..< len(slot) {
				if slot[i] != g16.pixels[i] {
					baseline_bad += 1
					break
				}
			}
			delete(slot, allocator)
		}
		g64 := render.font_rasterize_glyph(&r64, u32(cp), allocator)
		g32 := render.font_rasterize_glyph(&r32, u32(cp), allocator)
		if g16.width > 0 && g16.height > 0 && g64.width > 0 && g64.height > 0 && g32.width > 0 && g32.height > 0 {
			ascii_n += 1
			// Step 2: SDF generate + sample + diff (Diff1x) + HiDPI leg.
			t0 := time.tick_now()
			tile := sdf_generate_from_bitmap(g64.pixels, g64.width, g64.height, params, allocator)
			sdf_ms := time.duration_milliseconds(time.tick_since(t0))
			gl := _sdf_shifted(g64.pixels, g64.width, g64.height, 1, allocator)
			gr := _sdf_shifted(g64.pixels, g64.width, g64.height, -1, allocator)
			t1 := time.tick_now()
			mtile := msdf_generate_from_bitmap(g64.pixels, gl, gr, g64.width, g64.height, params, allocator)
			msdf_ms := time.duration_milliseconds(time.tick_since(t1))
			append(&worst_ms, max(sdf_ms, msdf_ms))

			_sdf_leg_sdf(&g16, &g64, &tile, _SDF_RATIO_1X, &acc1x, allocator)
			_sdf_leg_sdf(&g32, &g64, &tile, _SDF_RATIO_2X, &acc2x, allocator)
			delete(tile.pixels, allocator)
			delete(mtile.pixels, allocator)
			delete(gl, allocator)
			delete(gr, allocator)

			sdf_stored += (g16.width + 2 * _SDF_STORE_PAD) * (g16.height + 2 * _SDF_STORE_PAD)
			bmp32_total += g32.width * g32.height
		}
		if g16.pixels != nil {
			delete(g16.pixels, allocator)
		}
		if g64.pixels != nil {
			delete(g64.pixels, allocator)
		}
		if g32.pixels != nil {
			delete(g32.pixels, allocator)
		}
	}

	// Step 4: MSDF corners + corner MAE (M, W, 7, U+2500).
	corner_n := 0
	for cp in SDF_EXPERIMENT_CORNER_SET {
		g16 := render.font_rasterize_glyph(&r16, cp, allocator)
		g64 := render.font_rasterize_glyph(&r64, cp, allocator)
		if g16.width > 0 && g64.width > 0 && g16.pixels != nil && g64.pixels != nil {
			corner_n += 1
			tile := sdf_generate_from_bitmap(g64.pixels, g64.width, g64.height, params, allocator)
			_sdf_leg_sdf(&g16, &g64, &tile, _SDF_RATIO_1X, &acc_sdf_corner, allocator)
			delete(tile.pixels, allocator)
			gl := _sdf_shifted(g64.pixels, g64.width, g64.height, 1, allocator)
			gr := _sdf_shifted(g64.pixels, g64.width, g64.height, -1, allocator)
			mtile := msdf_generate_from_bitmap(g64.pixels, gl, gr, g64.width, g64.height, params, allocator)
			_sdf_leg_msdf(&g16, &g64, &mtile, _SDF_RATIO_1X, &acc_msdf_corner, allocator)
			delete(mtile.pixels, allocator)
			delete(gl, allocator)
			delete(gr, allocator)
		}
		if g16.pixels != nil {
			delete(g16.pixels, allocator)
		}
		if g64.pixels != nil {
			delete(g64.pixels, allocator)
		}
	}

	// Step 5: cost table + decide + still dumps. STOP (no integration).
	rep.diff_1x = _sdf_acc_diff(&acc1x)
	rep.diff_2x = _sdf_acc_diff(&acc2x)
	sdf_corner := _sdf_acc_diff(&acc_sdf_corner).edge_mae
	msdf_corner := _sdf_acc_diff(&acc_msdf_corner).edge_mae
	rep.corner_mae = sdf_corner
	if sdf_corner > 0 && msdf_corner <= sdf_corner*0.8 {
		rep.corner_mae = msdf_corner
	}
	rep.cost.shader_extra_alu = _SDF_SHADER_EXTRA_ALU_MSDF
	rep.cost.atlas_bytes = sdf_stored
	if len(worst_ms) > 0 {
		sum: f64 = 0
		for t in worst_ms {
			sum += t
		}
		rep.cost.gen_ms_mean = sum / f64(len(worst_ms))
		cp := make([]f64, len(worst_ms), allocator)
		defer delete(cp, allocator)
		copy(cp, worst_ms[:])
		slice.sort(cp)
		idx := clamp((95 * len(cp) + 99) / 100 - 1, 0, len(cp) - 1)
		rep.cost.gen_ms_p95 = cp[idx]
	}

	verdict := sdf_decide(rep.diff_1x, rep.diff_2x, rep.corner_mae, rep.cost)
	// Atlas-size gate (owns both byte totals): retained field must be
	// smaller than the 32px-bitmap alternative. MSDF costs ~3x SDF bytes.
	size_ok := sdf_stored < bmp32_total
	if verdict == .Retain_Msdf {
		size_ok = 3 * sdf_stored < bmp32_total
	}
	if !size_ok {
		verdict = .Discard
	}
	if baseline_bad != 0 {
		verdict = .Discard
	}
	rep.verdict = verdict

	// Stills for offline inspection (glyph 'A'): reference, SDF and MSDF
	// samples share one bearing-registered canvas, so they are comparable.
	still := render.font_rasterize_glyph(&r16, 0x41, allocator)
	still_hi := render.font_rasterize_glyph(&r64, 0x41, allocator)
	if still.width > 0 && still_hi.width > 0 && still.pixels != nil && still_hi.pixels != nil {
		os.make_directory(_SDF_STILL_DIR)
		_sdf_write_pgm(_SDF_STILL_DIR + "hi64.pgm", still_hi.pixels, still_hi.width, still_hi.height, allocator)
		ox, oy, w, h := _sdf_union_canvas(
			still.bearing_x, still.bearing_y, still.width, still.height,
			still_hi.bearing_x, still_hi.bearing_y, still_hi.width, still_hi.height,
			_SDF_RATIO_1X,
		)
		if w > 0 {
			ref := make([]u8, w * h, allocator)
			_sdf_blit(ref, w, h, ox, oy, &still)
			_sdf_write_pgm(_SDF_STILL_DIR + "ref16.pgm", ref, w, h, allocator)
			delete(ref, allocator)
			st := sdf_generate_from_bitmap(still_hi.pixels, still_hi.width, still_hi.height, params, allocator)
			ss := _sdf_sample_canvas(&st, still_hi.bearing_x, still_hi.bearing_y, _SDF_RATIO_1X, ox, oy, w, h, allocator)
			_sdf_write_pgm(_SDF_STILL_DIR + "sdf16.pgm", ss, w, h, allocator)
			delete(ss, allocator)
			delete(st.pixels, allocator)
			sgl := _sdf_shifted(still_hi.pixels, still_hi.width, still_hi.height, 1, allocator)
			sgr := _sdf_shifted(still_hi.pixels, still_hi.width, still_hi.height, -1, allocator)
			mt := msdf_generate_from_bitmap(still_hi.pixels, sgl, sgr, still_hi.width, still_hi.height, params, allocator)
			ms := _msdf_sample_canvas(&mt, still_hi.bearing_x, still_hi.bearing_y, _SDF_RATIO_1X, ox, oy, w, h, allocator)
			_sdf_write_pgm(_SDF_STILL_DIR + "msdf16.pgm", ms, w, h, allocator)
			delete(ms, allocator)
			delete(mt.pixels, allocator)
			delete(sgl, allocator)
			delete(sgr, allocator)
		}
	}
	if still.pixels != nil {
		delete(still.pixels, allocator)
	}
	if still_hi.pixels != nil {
		delete(still_hi.pixels, allocator)
	}

	// CJK/complex spot checks: reported, excluded from the gate, never fires RETAIN.
	spot_px: [3][]u8
	spot_empty: [3]bool
	spot_list := _SDF_SPOT_SET
	for i in 0 ..< len(spot_list) {
		cp := spot_list[i]
		g := render.font_rasterize_glyph(&r16, cp, allocator)
		spot_empty[i] = g.width <= 0 || g.pixels == nil
		if !spot_empty[i] {
			dup := make([]u8, len(g.pixels), allocator)
			copy(dup, g.pixels)
			spot_px[i] = dup
		}
		state := "covered"
		if spot_empty[i] {
			state = "empty/missing-in-primary (needs fallback chain; out of gate)"
		}
		fmt.printf("SDF phase19 spot cp=%d: %dx%d %s\n", cp, g.width, g.height, state)
		if g.pixels != nil {
			delete(g.pixels, allocator)
		}
	}
	same := !spot_empty[0] && !spot_empty[1] && !spot_empty[2] &&
		len(spot_px[0]) == len(spot_px[1]) && len(spot_px[1]) == len(spot_px[2])
	if same {
		for i in 0 ..< len(spot_px[0]) {
			if spot_px[0][i] != spot_px[1][i] || spot_px[1][i] != spot_px[2][i] {
				same = false
				break
			}
		}
	}
	if same {
		fmt.printf("SDF phase19 spot: all three scripts byte-identical -> .notdef tofu, topology untested\n")
	}
	for px in spot_px {
		delete(px, allocator)
	}

	vstr := "DISCARD"
	if rep.verdict == .Retain_Sdf {
		vstr = "RETAIN-SDF"
	} else if rep.verdict == .Retain_Msdf {
		vstr = "RETAIN-MSDF"
	}
	fmt.printf(
		"SDF phase19: ascii=%d corners=%d baseline_bad=%d mae1x=%.4f max1x=%d edge1x=%.4f stem_lost=%d mae2x=%.4f max2x=%d corner_sdf=%.4f corner_msdf=%.4f corner_used=%.4f gen_mean=%.3fms gen_p95=%.3fms sdf_bytes=%d bmp32_bytes=%d msdf_bytes=%d alu_extra=%d\nVERDICT: %s\n",
		ascii_n,
		corner_n,
		baseline_bad,
		rep.diff_1x.mae,
		rep.diff_1x.max_err,
		rep.diff_1x.edge_mae,
		rep.diff_1x.stem_lost,
		rep.diff_2x.mae,
		rep.diff_2x.max_err,
		sdf_corner,
		msdf_corner,
		rep.corner_mae,
		rep.cost.gen_ms_mean,
		rep.cost.gen_ms_p95,
		sdf_stored,
		bmp32_total,
		3 * sdf_stored,
		rep.cost.shader_extra_alu,
		vstr,
	)
	return rep
}

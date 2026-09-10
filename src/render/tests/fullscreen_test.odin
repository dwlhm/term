package render_tests

// Phase 15 fullscreen fragment tests (nil backend, no GPU):
// empty skip (clean + first-clean flip), flood byte accounting,
// partial-damage constant cost, unavailable fallback verbatim,
// resize false paths, format rejection with old-intact, and V2
// unpack parity against the tile_compute bit math.

import "core:testing"
import render "../"
import fullscreen "../fullscreen"
import gpu "../gpu"
import termgrid "../../terminal"

FULLSCREEN_TEST_ROWS :: 24
FULLSCREEN_TEST_COLS :: 80
FULLSCREEN_TEST_N :: FULLSCREEN_TEST_ROWS * FULLSCREEN_TEST_COLS

// _fullscreen_test_state builds a CPU-only fullscreen renderer state:
// nil backend, valid geometry. No GPU resources.
_fullscreen_test_state :: proc() -> fullscreen.Fullscreen_Renderer {
	return fullscreen.Fullscreen_Renderer{
		rows    = FULLSCREEN_TEST_ROWS,
		cols    = FULLSCREEN_TEST_COLS,
		cell_w  = 8,
		cell_h  = 16,
		fb_w_px = FULLSCREEN_TEST_COLS * 8,
		fb_h_px = FULLSCREEN_TEST_ROWS * 16,
		format  = gpu.Gpu_Format.BGRA8_Unorm,
	}
}

@(test)
test_fullscreen_empty_skip :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FULLSCREEN_TEST_ROWS, FULLSCREEN_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	lut := _dirty_test_lut()

	r: render.Renderer
	r.strategy = render.Render_Strategy.Fullscreen
	r.fullscreen.available = true

	// Empty clean: skip, no upload, no draw.
	testing.expect(t, !render.renderer_frame_fullscreen(&r, &term, &lut), "empty frame must skip")
	testing.expect(t, !r.last_dirty, "empty frame must leave last_dirty false")

	// Dirty frame with nil backend: backend guard fails after arming dirty.
	termgrid.terminal_move_cursor(&term, 12, 40)
	termgrid.terminal_put_char(&term, 'Q')
	testing.expect(t, !render.renderer_frame_fullscreen(&r, &term, &lut), "nil-backend dirty frame must return false")
	testing.expect(t, r.last_dirty, "dirty frame must arm last_dirty")

	// Empty first-clean: flip last_dirty=false, still no upload/draw.
	testing.expect(t, !render.renderer_frame_fullscreen(&r, &term, &lut), "first clean frame must skip")
	testing.expect(t, !r.last_dirty, "first clean frame must flip last_dirty false")
}

@(test)
test_fullscreen_flood_bytes :: proc(t: ^testing.T) {
	fr := _fullscreen_test_state()

	cells := make([]u64, FULLSCREEN_TEST_N)
	defer delete(cells)
	for i in 0..<FULLSCREEN_TEST_N {
		cells[i] = u64(render.render_cell_pack_v2(u32(32 + (i % 95)), u16(i % 8), render.RENDER_CELL_V2_WIDTH_NARROW, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED))
	}
	lut_words := make([]u32, fullscreen.FULLSCREEN_LUT_WORDS)
	defer delete(lut_words)

	want_grid := u64(FULLSCREEN_TEST_N) * fullscreen.FULLSCREEN_CELL_BYTES
	testing.expect_value(t, fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, false), want_grid)

	// LUT rebuild adds exactly one full LUT upload.
	testing.expect_value(t, fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, true), want_grid + fullscreen.FULLSCREEN_LUT_BYTES)

	// Short LUT words carry no LUT bytes even when rebuilt.
	short_lut := make([]u32, 100)
	defer delete(short_lut)
	testing.expect_value(t, fullscreen.fullscreen_upload_grid(&fr, cells, short_lut, true), want_grid)

	// Empty cells upload nothing for the grid; the rebuilt LUT still counts.
	testing.expect_value(t, fullscreen.fullscreen_upload_grid(&fr, nil, lut_words, true), u64(fullscreen.FULLSCREEN_LUT_BYTES))
	testing.expect_value(t, fullscreen.fullscreen_upload_grid(&fr, nil, lut_words, false), u64(0))
}

@(test)
test_fullscreen_partial_constant_cost :: proc(t: ^testing.T) {
	fr := _fullscreen_test_state()

	cells := make([]u64, FULLSCREEN_TEST_N)
	defer delete(cells)
	lut_words := make([]u32, fullscreen.FULLSCREEN_LUT_WORDS)
	defer delete(lut_words)

	// The fullscreen upload is damage-independent: 1-cell, 1-row, and
	// flood extents all cost the same full-grid constant.
	one_cell := fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, false)
	one_row := fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, false)
	flood := fullscreen.fullscreen_upload_grid(&fr, cells, lut_words, false)
	testing.expect_value(t, one_cell, u64(FULLSCREEN_TEST_N) * fullscreen.FULLSCREEN_CELL_BYTES)
	testing.expect_value(t, one_row, one_cell)
	testing.expect_value(t, flood, one_cell)
}

@(test)
test_fullscreen_unavailable_fallback :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FULLSCREEN_TEST_ROWS, FULLSCREEN_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	lut := _dirty_test_lut()

	// Zero renderer: strategy defaults to Instance, fullscreen unavailable.
	r: render.Renderer
	testing.expect(t, !render.renderer_frame_fullscreen(&r, &term, &lut), "unavailable fullscreen must fall back and skip")
	testing.expect_value(t, r.frame_count, u64(1))
	testing.expect(t, !r.fullscreen.available, "fallback must never latch available")

	// Fullscreen strategy but unavailable: same verbatim delegation.
	r2: render.Renderer
	r2.strategy = render.Render_Strategy.Fullscreen
	testing.expect(t, !r2.fullscreen.available, "zero fullscreen must be unavailable")
	testing.expect(t, !render.renderer_frame_fullscreen(&r2, &term, &lut), "unavailable strategy frame must fall back and skip")
	testing.expect_value(t, r2.frame_count, u64(1))
	testing.expect(t, !r2.fullscreen.available, "fallback must never latch available")
}

@(test)
test_fullscreen_resize :: proc(t: ^testing.T) {
	fr := _fullscreen_test_state()

	// Nil backend: every resize fails without touching geometry.
	testing.expect(t, !fullscreen.fullscreen_resize(&fr, FULLSCREEN_TEST_ROWS, FULLSCREEN_TEST_COLS, 8, 16, gpu.Gpu_Format.BGRA8_Unorm), "nil-backend resize must fail")
	testing.expect_value(t, fr.rows, i32(FULLSCREEN_TEST_ROWS))
	testing.expect_value(t, fr.cols, i32(FULLSCREEN_TEST_COLS))
	testing.expect_value(t, fr.fb_w_px, u32(FULLSCREEN_TEST_COLS * 8))
	testing.expect_value(t, fr.fb_h_px, u32(FULLSCREEN_TEST_ROWS * 16))

	// Degenerate geometry fails even before the backend check.
	testing.expect(t, !fullscreen.fullscreen_resize(&fr, 0, FULLSCREEN_TEST_COLS, 8, 16, gpu.Gpu_Format.BGRA8_Unorm), "degenerate resize must fail")

	// Renderer-level resize disables fullscreen on failure (never latches).
	r: render.Renderer
	r.rows = FULLSCREEN_TEST_ROWS
	r.cols = FULLSCREEN_TEST_COLS
	r.cell_width = 8
	r.cell_height = 16
	r.fullscreen = _fullscreen_test_state()
	r.fullscreen.available = true
	render.renderer_resize(&r, 640, 384)
	testing.expect(t, !r.fullscreen.available, "failed renderer resize must disable fullscreen")
	testing.expect_value(t, r.surface_w, u32(640))
	testing.expect_value(t, r.surface_h, u32(384))
}

@(test)
test_fullscreen_format_reject :: proc(t: ^testing.T) {
	fr := _fullscreen_test_state()

	// Format change rejects with old resources intact.
	testing.expect(t, !fullscreen.fullscreen_resize(&fr, FULLSCREEN_TEST_ROWS, FULLSCREEN_TEST_COLS, 8, 16, gpu.Gpu_Format.RGBA8_Unorm), "format change must reject")
	testing.expect_value(t, fr.rows, i32(FULLSCREEN_TEST_ROWS))
	testing.expect_value(t, fr.cols, i32(FULLSCREEN_TEST_COLS))
	testing.expect_value(t, fr.cell_w, f32(8))
	testing.expect_value(t, fr.cell_h, f32(16))
	testing.expect_value(t, fr.fb_w_px, u32(FULLSCREEN_TEST_COLS * 8))
	testing.expect_value(t, fr.fb_h_px, u32(FULLSCREEN_TEST_ROWS * 16))
	testing.expect_value(t, fr.format, gpu.Gpu_Format.BGRA8_Unorm)
}

@(test)
test_fullscreen_unpack_parity :: proc(t: ^testing.T) {
	// Pack V2 cells, split into u32 words, decode with the fullscreen /
	// tile_compute bit math, and compare against render_cell_unpack_v2.
	contents := [?]u32{0x20, 0x41, 0x2500, 0x4E2D, 0, 0x1FFFFF}
	styles := [?]u16{0, 1, 512, 1023}
	widths := [?]u8{render.RENDER_CELL_V2_WIDTH_CONTINUATION, render.RENDER_CELL_V2_WIDTH_NARROW, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD}
	slots := [?]u16{0, 42, 511, render.RENDER_CELL_V2_SLOT_UNRESOLVED}
	for content in contents {
		for style in styles {
			for width in widths {
				for slot in slots {
					v := render.render_cell_pack_v2(content, style, width, 0, slot)
					lo := u32(u64(v) & 0xFFFFFFFF)
					hi := u32(u64(v) >> 32)
					d_content := lo & u32(0x1FFFFF)
					d_style := (lo >> u32(21)) & u32(0x3FF)
					d_width := ((lo >> u32(31)) & u32(1)) | ((hi & u32(1)) << u32(1))
					d_slot := (hi >> u32(8)) & u32(0x1FF)
					e_content, e_style, e_width, _, e_slot := render.render_cell_unpack_v2(v)
					testing.expect_value(t, d_content, e_content)
					testing.expect_value(t, d_style, u32(e_style))
					testing.expect_value(t, d_width, u32(e_width))
					testing.expect_value(t, d_slot, u32(e_slot))
				}
			}
		}
	}
}

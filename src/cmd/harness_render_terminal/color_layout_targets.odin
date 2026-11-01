package main

// Scene builders for the GPU colour-layout regression (see
// color_layout_regression.odin): one grid that carries truecolor fg/bg and an
// SGR 4:3 curly underline colour on every cell, encoded through all three
// render strategies into equal-sized off-screen targets.

import "vendor:wgpu"

import atlas "../../core/render/atlas"
import contract "../../core/render/contract"
import terminal "../../core/render/terminal"
import fullscreen "../../core/render/terminal/fullscreen"
import terminal_instance "../../core/render/terminal/instance"
import tile "../../core/render/terminal/tile"

COLOR_TEST_COLS :: u32(32)
COLOR_TEST_ROWS :: u32(8)
COLOR_TEST_W :: u32(COLOR_TEST_COLS * 10)
COLOR_TEST_H :: u32(COLOR_TEST_ROWS * 20)
COLOR_TEST_CELL_W :: f32(10.0)
COLOR_TEST_CELL_H :: f32(20.0)
COLOR_TEST_DEFAULT_BG :: [4]f64 {2.0 / 31.0, 5.0 / 63.0, 3.0 / 31.0, 1.0}

_Color_Target :: struct {
	tex:  contract.Gpu_Texture,
	view: contract.Gpu_TextureView,
	buf:  contract.Gpu_Buffer,
}

_color_argb :: #force_inline proc "contextless" (r, g, b: u8) -> u32 {
	return 0xFF000000 | (u32(r) << 16) | (u32(g) << 8) | u32(b)
}

// _fill_color_test_cells paints one grid where every cell authorises a
// truecolor fg/bg and a red curly underline; every 5th cell leaves the
// underline word 0 (SGR 59 -> falls back to fg) and every 7th bg 0 (LUT
// fallback), so both words and their fallbacks are exercised.
_fill_color_test_cells :: proc(t: ^Synthetic_Terminal) {
	for r in 0..<t.rows {
		for c in 0..<t.cols {
			idx := r * t.cols + c
			ch := rune('A') + rune(c % 26)
			t.cells[idx] = pack_cell(u32(ch), 0, 1, 0, UNRESOLVED_SLOT)
			fg := _color_argb(u8(60 + r * 12), u8(40 + c * 5), 190)
			bg := _color_argb(20, u8(30 + c * 3), u8(40 + r * 8))
			ul := _color_argb(255, 0, 0)
			if (r + c) % 7 == 0 do bg = 0
			if (r + c) % 5 == 0 do ul = 0
			synthetic_terminal_set_direct_color(t, r, c, fg, bg, ul, 3) // SGR 4:3
		}
	}
}

_encode_instance_target :: proc(
	h: ^Harness_State,
	enc: contract.Gpu_CommandEncoder,
	inst: ^terminal_instance.Instance_Renderer,
	decor: ^terminal_instance.Instance_Renderer,
	t: ^Synthetic_Terminal,
	view: contract.Gpu_TextureView,
) {
	terminal_instance.instance_renderer_begin(inst)
	terminal_instance.instance_renderer_begin(decor)
	u_data := [4]f32{f32(COLOR_TEST_W), f32(COLOR_TEST_H), COLOR_TEST_CELL_W, COLOR_TEST_CELL_H}
	contract.write_buffer(h.queue, inst.uniform_buffer, 0, &u_data, size_of([4]f32))
	contract.write_buffer(h.queue, decor.uniform_buffer, 0, &u_data, size_of([4]f32))
	for r in 0..<COLOR_TEST_ROWS {
		for c in 0..<COLOR_TEST_COLS {
			_push_cell_instance(inst, t, r, c, COLOR_TEST_CELL_W, COLOR_TEST_CELL_H, false, decor)
		}
	}
	terminal_instance.instance_renderer_flush(inst)
	terminal_instance.instance_renderer_flush(decor)

	pass := contract.begin_render_pass(enc, view, COLOR_TEST_DEFAULT_BG, .Clear)
	if rawptr(pass) != nil {
		bg_bind := inst.bg_bind_group if rawptr(inst.bg_bind_group) != nil else inst.bind_group
		contract.render_set_pipeline(pass, h.bg_pipeline)
		contract.render_set_bind_group(pass, 0, bg_bind)
		contract.render_set_vertex_buffer(pass, 0, inst.instance_buffer, 0)
		contract.render_draw(pass, 6, inst.active_count)
		terminal_instance.instance_renderer_draw(inst, pass)
		// Underline quads land on top of glyph ink, matching ul_band() in the
		// cell shaders (production paints decorations under glyphs instead).
		if decor.active_count > 0 {
			decor_bind := decor.bg_bind_group if rawptr(decor.bg_bind_group) != nil else decor.bind_group
			contract.render_set_pipeline(pass, h.bg_pipeline)
			contract.render_set_bind_group(pass, 0, decor_bind)
			contract.render_set_vertex_buffer(pass, 0, decor.instance_buffer, 0)
			contract.render_draw(pass, 6, decor.active_count)
		}
		contract.end_render_pass(pass)
	}
}

_encode_tile_target :: proc(
	h: ^Harness_State,
	enc: contract.Gpu_CommandEncoder,
	r: ^tile.Compute_Tile_Renderer,
	t: ^Synthetic_Terminal,
	color_buf: contract.Gpu_Buffer,
	view: contract.Gpu_TextureView,
) {
	contract.write_buffer(h.queue, r.cell_buffer, 0, raw_data(t.cells), u64(len(t.cells) * size_of(u64)))
	_upload_color_words(h, color_buf, t)
	contract.write_buffer(h.queue, r.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
	params := tile.Tile_Params{
		screen_w     = f32(COLOR_TEST_W),
		screen_h     = f32(COLOR_TEST_H),
		cols         = COLOR_TEST_COLS,
		rows         = COLOR_TEST_ROWS,
		cell_w       = COLOR_TEST_CELL_W,
		cell_h       = COLOR_TEST_CELL_H,
		pad_x        = 0.0,
		pad_y        = 0.0,
		tile_w       = r.tile_w,
		tile_h       = r.tile_h,
		tiles_x      = r.tiles_x,
		tiles_y      = r.tiles_y,
		atlas_w      = atlas.ATLAS_WIDTH,
		atlas_h      = atlas.ATLAS_HEIGHT,
		bg_opacity   = 1.0,
		cell_opacity = 1.0,
	}
	contract.write_buffer(h.queue, r.params_buffer, 0, &params, size_of(tile.Tile_Params))
	tile_list := make([]u32, int(r.tile_count), context.temp_allocator)
	for i in 0..<len(tile_list) do tile_list[i] = u32(i)
	contract.write_buffer(h.queue, r.tile_list_buffer, 0, raw_data(tile_list), u64(len(tile_list)) * size_of(u32))
	tile.compute_tile_dispatch(r, enc, u32(len(tile_list)))

	pass := contract.begin_render_pass(enc, view, COLOR_TEST_DEFAULT_BG, .Clear)
	if rawptr(pass) != nil {
		contract.render_set_pipeline(pass, r.blit_pipeline)
		contract.render_set_bind_group(pass, 0, r.blit_bind_group)
		contract.render_draw(pass, 3, 1)
		contract.end_render_pass(pass)
	}
}

_encode_fullscreen_target :: proc(
	h: ^Harness_State,
	enc: contract.Gpu_CommandEncoder,
	r: ^fullscreen.Fullscreen_Renderer,
	t: ^Synthetic_Terminal,
	color_buf: contract.Gpu_Buffer,
	view: contract.Gpu_TextureView,
	words_per_cell: u32 = terminal.COLOR_WORDS_PER_CELL,
) {
	contract.write_buffer(h.queue, r.cell_buffer, 0, raw_data(t.cells), u64(len(t.cells) * size_of(u64)))
	_upload_color_words(h, color_buf, t, words_per_cell)
	contract.write_buffer(h.queue, r.lut_buffer, 0, &h.lut_words, size_of(h.lut_words))
	params := fullscreen.Fullscreen_Params{
		screen_w     = f32(COLOR_TEST_W),
		screen_h     = f32(COLOR_TEST_H),
		cols         = COLOR_TEST_COLS,
		rows         = COLOR_TEST_ROWS,
		cell_w       = COLOR_TEST_CELL_W,
		cell_h       = COLOR_TEST_CELL_H,
		pad_x        = 0.0,
		pad_y        = 0.0,
		atlas_w      = atlas.ATLAS_WIDTH,
		atlas_h      = atlas.ATLAS_HEIGHT,
		bg_opacity   = 1.0,
		cell_opacity = 1.0,
	}
	contract.write_buffer(h.queue, r.params_buffer, 0, &params, size_of(fullscreen.Fullscreen_Params))

	pass := contract.begin_render_pass(enc, view, COLOR_TEST_DEFAULT_BG, .Clear)
	if rawptr(pass) != nil {
		fullscreen.fullscreen_draw(r, pass)
		contract.end_render_pass(pass)
	}
}

_encode_readback :: proc(enc: contract.Gpu_CommandEncoder, tex: contract.Gpu_Texture, buf: contract.Gpu_Buffer, bytes_per_row: u32) {
	enc_wgpu := wgpu.CommandEncoder(rawptr(enc))
	src := wgpu.TexelCopyTextureInfo{texture = wgpu.Texture(rawptr(tex)), mipLevel = 0, origin = {0, 0, 0}, aspect = .All}
	dst := wgpu.TexelCopyBufferInfo{
		layout = {offset = 0, bytesPerRow = bytes_per_row, rowsPerImage = COLOR_TEST_H},
		buffer = wgpu.Buffer(rawptr(buf)),
	}
	size := wgpu.Extent3D{width = COLOR_TEST_W, height = COLOR_TEST_H, depthOrArrayLayers = 1}
	wgpu.CommandEncoderCopyTextureToBuffer(enc_wgpu, &src, &dst, &size)
}

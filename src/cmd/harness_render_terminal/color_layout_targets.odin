package main

// Scene builders for the GPU colour-layout and decoration regression (see
// color_layout_regression.odin): grids that carry truecolor fg/bg, a coloured
// SGR 4:n underline, strikethrough and bold/italic cell styles, encoded through
// Instance_Renderer into equal-sized off-screen targets.

import "vendor:wgpu"

import contract "../../core/render/contract"
import terminal_instance "../../core/render/terminal/instance"

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

// Scene A cycles every stored underline shape (SGR 4:1..4:5), strikethrough
// (SGR 9) and bold/italic cell styles over glyphs whose ink crosses the strike
// band. Every cell authorises truecolor fg/bg plus an RGB underline colour;
// every 5th leaves the underline word 0 (SGR 59 -> fg fallback) and every 7th
// bg 0 (LUT fallback), so both words and their fallbacks are exercised.
_fill_color_test_cells :: proc(t: ^Synthetic_Terminal) {
	glyphs := "Agjpqy_|W"
	for r in 0..<t.rows {
		for c in 0..<t.cols {
			idx := r * t.cols + c
			ch := rune(glyphs[int(r * 3 + c) % len(glyphs)])
			style := u32(1 << 3) // .Underline
			if (r + c) % 2 == 0 {
				style |= 1 // .Bold
			} else {
				style |= 1 << 2 // .Italic
			}
			if (r + c) % 3 == 0 do style |= 1 << 5 // .Strike
			t.cells[idx] = pack_cell(u32(ch), style, 1, 0, UNRESOLVED_SLOT)
			fg := _color_argb(u8(60 + r * 12), u8(40 + c * 5), 190)
			bg := _color_argb(20, u8(30 + c * 3), u8(40 + r * 8))
			ul := _color_argb(255, u8(c * 7), u8(r * 9))
			if (r + c) % 7 == 0 do bg = 0
			if (r + c) % 5 == 0 do ul = 0
			ul_style := u32(1 + c % 5) // single/double/curly/dotted/dashed
			synthetic_terminal_set_direct_color(t, r, c, fg, bg, ul, ul_style)
			if (r + c) % 3 == 0 do _set_cell_decor_bit(t, idx, GPU_CELL_DECOR_STRIKE_SHIFT)
		}
	}
}

// Scene B packs the italic decor bit so Instance_Renderer exercises the
// synthetic italic shear in glyph.wgsl alongside SGR 4:n and strikethrough.
_fill_italic_decor_cells :: proc(t: ^Synthetic_Terminal) {
	for r in 0..<t.rows {
		for c in 0..<t.cols {
			idx := r * t.cols + c
			ch := rune('M') + rune((r * 7 + c) % 5)
			style := u32(1 | 1 << 2 | 1 << 3 | 1 << 5) // bold+italic+underline+strike
			t.cells[idx] = pack_cell(u32(ch), style, 1, 0, UNRESOLVED_SLOT)
			fg := _color_argb(u8(180 - r * 8), u8(80 + c * 4), 210)
			bg := _color_argb(18, u8(26 + c * 2), u8(38 + r * 6))
			ul := _color_argb(0, 200, u8(c * 6))
			synthetic_terminal_set_direct_color(t, r, c, fg, bg, ul, u32(1 + c % 5))
			_set_cell_decor_bit(t, idx, GPU_CELL_DECOR_STRIKE_SHIFT)
			_set_cell_decor_bit(t, idx, GPU_CELL_DECOR_ITALIC_SHIFT)
		}
	}
}

_set_cell_decor_bit :: #force_inline proc(t: ^Synthetic_Terminal, idx: u32, shift: u32) {
	hi := u32(t.cells[idx] >> 32) | (u32(1) << shift)
	t.cells[idx] = u64(u32(t.cells[idx])) | (u64(hi) << 32)
}

// _Color_Mutation selects a deliberately broken encoding that the pixel
// regression must detect.
_Color_Mutation :: enum {
	None,
	Two_Word_Color_Stride,
	Decor_Under_Glyph,
	Strike_Offset,
	Disable_Italic_Shear,
}

_encode_instance_target :: proc(
	h: ^Harness_State,
	enc: contract.Gpu_CommandEncoder,
	inst: ^terminal_instance.Instance_Renderer,
	t: ^Synthetic_Terminal,
	view: contract.Gpu_TextureView,
	mutation: _Color_Mutation = .None,
) {
	terminal_instance.instance_renderer_begin(inst)
	u_data := [4]f32{f32(COLOR_TEST_W), f32(COLOR_TEST_H), COLOR_TEST_CELL_W, COLOR_TEST_CELL_H}
	contract.write_buffer(h.queue, inst.uniform_buffer, 0, &u_data, size_of([4]f32))
	for r in 0..<COLOR_TEST_ROWS {
		for c in 0..<COLOR_TEST_COLS {
			_push_cell_instance(inst, t, r, c, COLOR_TEST_CELL_W, COLOR_TEST_CELL_H, false, mutation)
		}
	}
	terminal_instance.instance_renderer_flush(inst)

	pass := contract.begin_render_pass(enc, view, COLOR_TEST_DEFAULT_BG, .Clear)
	if rawptr(pass) != nil {
		bg_bind := inst.bg_bind_group if rawptr(inst.bg_bind_group) != nil else inst.bind_group
		contract.render_set_pipeline(pass, h.bg_pipeline)
		contract.render_set_bind_group(pass, 0, bg_bind)
		if mutation == .Decor_Under_Glyph {
			// Mutation: paint everything (decorations included) first.
			contract.render_set_vertex_buffer(pass, 0, inst.instance_buffer, 0)
			contract.render_draw(pass, 6, inst.active_count)
			terminal_instance.instance_renderer_draw(inst, pass)
		} else {
			// Production order: backgrounds, glyphs, then the decoration tail.
			front := terminal_instance.instance_renderer_front_count(inst)
			contract.render_set_vertex_buffer(pass, 0, inst.instance_buffer, 0)
			contract.render_draw(pass, 6, front)
			terminal_instance.instance_renderer_draw(inst, pass)
			if inst.overlay_count > 0 {
				contract.render_set_pipeline(pass, h.bg_pipeline)
				contract.render_set_bind_group(pass, 0, bg_bind)
				terminal_instance.instance_renderer_draw_overlays(inst, pass)
			}
		}
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

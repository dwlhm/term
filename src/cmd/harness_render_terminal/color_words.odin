package main

// Shared per-cell colour layout for the GPU harness.
//
// The cell shaders read COLOR_WORDS_PER_CELL u32 words per cell (fg ARGB,
// bg ARGB, underline ARGB). The host owns the same layout through
// terminal.COLOR_WORDS_PER_CELL / terminal.COLOR_BYTES_PER_CELL, so colour
// buffers and uploads can never drift back to the old 8-byte/two-word stride.
// _upload_color_words(..., words_per_cell = 2) is the mutation probe the
// strategy-equality regression uses to prove such a drift is caught.

import "core:math"

import contract "../../core/render/contract"
import atlas "../../core/render/atlas"
import terminal "../../core/render/terminal"
import terminal_instance "../../core/render/terminal/instance"

// Packed-cell bits shared with the shaders (terminal_renderer.odin).
GPU_CELL_FLAG_DIRECT_COLOR :: u32(8) // cflags bit 3 (hi bit 4)
GPU_CELL_DECOR_UNDERLINE_SHIFT :: 17 // hi bit 17 == u64 bit 49
GPU_CELL_UL_STYLE_SHIFT :: 20 // hi bits 20..22 == u64 bits 52..54

// color_words_at returns the three colour words that belong to one cell.
color_words_at :: #force_inline proc "contextless" (t: ^Synthetic_Terminal, idx: int) -> (fg, bg, underline: u32) {
	base := idx * terminal.COLOR_WORDS_PER_CELL
	return t.colors[base], t.colors[base + 1], t.colors[base + 2]
}

// unpack_decor mirrors the shader's decor / ul_style extraction.
unpack_decor :: #force_inline proc "contextless" (packed: u64) -> (decor, ul_style: u32) {
	hi := u32(packed >> 32)
	return (hi >> GPU_CELL_DECOR_UNDERLINE_SHIFT) & 7, (hi >> GPU_CELL_UL_STYLE_SHIFT) & 7
}

// argb_to_rgba decodes a 0xFFRRGGBB word exactly like the shader's unpack_argb.
argb_to_rgba :: #force_inline proc "contextless" (argb: u32) -> [4]f32 {
	return {
		f32((argb >> 16) & 0xFF) / 255.0,
		f32((argb >> 8) & 0xFF) / 255.0,
		f32(argb & 0xFF) / 255.0,
		f32((argb >> 24) & 0xFF) / 255.0,
	}
}

// synthetic_terminal_set_direct_color paints the truecolor words for a cell and
// sets the matching packed flags. ul_style != 0 (or a non-zero underline word)
// also sets the underline decor bit, like SGR 4:n;58:2::r:g:b.
synthetic_terminal_set_direct_color :: proc(
	t: ^Synthetic_Terminal,
	r, c: u32,
	fg_argb, bg_argb, underline_argb: u32,
	ul_style: u32 = 0,
) {
	idx := r * t.cols + c
	hi := u32(t.cells[idx] >> 32)
	hi |= GPU_CELL_FLAG_DIRECT_COLOR << 1
	if ul_style != 0 || underline_argb != 0 {
		hi |= u32(1) << GPU_CELL_DECOR_UNDERLINE_SHIFT
		hi = (hi & ~(u32(7) << GPU_CELL_UL_STYLE_SHIFT)) | ((ul_style & 7) << GPU_CELL_UL_STYLE_SHIFT)
	}
	t.cells[idx] = u64(u32(t.cells[idx])) | (u64(hi) << 32)
	base := int(idx) * terminal.COLOR_WORDS_PER_CELL
	t.colors[base] = fg_argb
	t.colors[base + 1] = bg_argb
	t.colors[base + 2] = underline_argb
}

// _upload_color_words uploads the terminal's colour words. With a non-default
// words_per_cell it repacks at the old stride, which leaves the shaders reading
// the wrong words: the mutation probe for the layout regression.
_upload_color_words :: proc(
	h: ^Harness_State,
	buf: contract.Gpu_Buffer,
	t: ^Synthetic_Terminal,
	words_per_cell: u32 = terminal.COLOR_WORDS_PER_CELL,
) {
	if rawptr(buf) == nil || len(t.colors) == 0 do return
	if int(words_per_cell) == terminal.COLOR_WORDS_PER_CELL {
		contract.write_buffer(h.queue, buf, 0, raw_data(t.colors), u64(len(t.colors)) * size_of(u32))
		return
	}
	n_cells := int(t.cols * t.rows)
	out := make([]u32, n_cells * int(words_per_cell), context.temp_allocator)
	for i in 0..<n_cells {
		src := i * terminal.COLOR_WORDS_PER_CELL
		dst := i * int(words_per_cell)
		for w in 0..<int(words_per_cell) do out[dst + w] = t.colors[src + w]
	}
	contract.write_buffer(h.queue, buf, 0, raw_data(out), u64(len(out)) * size_of(u32))
}

// _cell_colors resolves the fg/bg an instance record must use: selection wins,
// then the per-cell ARGB words, then the palette LUT.
_cell_colors :: proc(
	t: ^Synthetic_Terminal,
	idx: int,
	style: u32,
	cflags: u32,
) -> (fg, bg: [4]f32) {
	if (cflags & 2) != 0 do return SELECTED_FG_FLOAT, SELECTED_BG_FLOAT
	fg, bg = palette_style_colors(style)
	if (cflags & GPU_CELL_FLAG_DIRECT_COLOR) == 0 do return
	fg_argb, bg_argb, _ := color_words_at(t, idx)
	if fg_argb != 0 do fg = argb_to_rgba(fg_argb)
	if bg_argb != 0 do bg = argb_to_rgba(bg_argb)
	return
}

// _push_decoration_rec paints one solid quad through the background instance
// pass (uv_rect zero = solid fill, matching the production decoration record).
_push_decoration_rec :: #force_inline proc(inst: ^terminal_instance.Instance_Renderer, x, y, w, h: f32, color: [4]f32) {
	rec := contract.Instance_Record{
		pos_size = {x, y, w, h},
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = color,
	}
	terminal_instance.instance_renderer_push(inst, rec)
}

// _underline_band mirrors ul_band() in tile_compute.wgsl / fullscreen.wgsl for
// one pixel centre (integer pixel + 0.5).
_underline_band :: proc(
	ul_style: u32,
	px, py, cell_x0, cell_y0, cell_w, cell_h: f32,
) -> bool {
	style := ul_style if ul_style != 0 else u32(1)
	thickness := max(1.0, math.floor(cell_h * 0.06))
	bottom := cell_y0 + cell_h - thickness
	gw := max(cell_w, 1.0)
	fx := (px - cell_x0) / gw
	switch style {
	case 2: // double
		return py >= bottom || (py >= bottom - thickness * 2.0 && py < bottom - thickness)
	case 3: // curly
		wave := cell_y0 + cell_h - thickness * 2.0 + math.sin(fx * 6.2831853) * cell_h * 0.08
		return abs(py - wave) < thickness * 0.5
	case 4, 5: // dotted / dashed
		n := max(1.0, math.floor(gw / (3.0 if style == 4 else 4.0)))
		seg := (fx if fx < 0.999 else 0.999) * n
		seg -= math.floor(seg)
		return py >= bottom && seg < (0.5 if style == 4 else 0.6)
	}
	return py >= bottom
}

// _push_underline emits one quad per contiguous horizontal run of band pixels,
// matching the shader's pixel coverage for the stored SGR 4:n shape.
_push_underline :: proc(
	inst: ^terminal_instance.Instance_Renderer,
	ul_style: u32,
	x, y, w, cell_h: f32,
	color: [4]f32,
) {
	rows := max(1, int(math.ceil(cell_h)))
	cols := max(1, int(math.ceil(w)))
	for row in 0..<rows {
		py := y + f32(row) + 0.5
		run_start := -1
		for col in 0..=cols {
			hit := col < cols && _underline_band(ul_style, x + f32(col) + 0.5, py, x, y, w, cell_h)
			if hit && run_start < 0 do run_start = col
			if !hit && run_start >= 0 {
				_push_decoration_rec(inst, x + f32(run_start), y + f32(row), f32(col - run_start), 1.0, color)
				run_start = -1
			}
		}
	}
}

// _push_cell_instance renders one packed cell through the instance strategy,
// consuming the same colour words and underline decor as the shaders. With
// skip_blank it leaves default blank cells to the pass clear colour (partial
// redraws); a full redraw must pass false so erased cells repaint. decorations
// go to decor_inst (drawn after the glyph pass, like the shaders) when given.
_push_cell_instance :: proc(
	inst: ^terminal_instance.Instance_Renderer,
	t: ^Synthetic_Terminal,
	r, c: u32,
	cell_w, cell_h: f32,
	skip_blank: bool = false,
	decor_inst: ^terminal_instance.Instance_Renderer = nil,
) -> bool {
	idx := int(r * t.cols + c)
	packed := t.cells[idx]
	content, style, _, cflags, slot := unpack_cell(packed)
	decor, ul_style := unpack_decor(packed)
	has_direct := (cflags & GPU_CELL_FLAG_DIRECT_COLOR) != 0
	has_underline := (decor & 1) != 0
	if skip_blank && content == ' ' && style == 0 && !has_direct && (cflags & 2) == 0 && !has_underline {
		return false
	}

	u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
	if slot == UNRESOLVED_SLOT && content >= 32 && content <= 126 {
		u0, v0, u1, v1 = atlas.atlas_slot_uv(content - 32, cell_w, cell_h)
	}
	fg, bg := _cell_colors(t, idx, style, cflags)
	x := f32(c) * cell_w
	y := f32(r) * cell_h
	rec := contract.Instance_Record{
		pos_size = {x, y, cell_w, cell_h},
		uv_rect  = {u0, v0, u1, v1},
		fg_color = fg,
		bg_color = bg,
	}
	terminal_instance.instance_renderer_push(inst, rec)
	if has_underline {
		_, _, ul_argb := color_words_at(t, idx)
		ul_color := argb_to_rgba(ul_argb) if ul_argb != 0 else fg
		target := decor_inst if decor_inst != nil else inst
		_push_underline(target, ul_style, x, y, cell_w, cell_h, ul_color)
	}
	return true
}

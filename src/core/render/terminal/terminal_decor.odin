package render_terminal

// Quad Emission, Text Decorations & Programming Ligature Run Shaping.

import "core:math"
import contract "../contract"
import "instance"
import cell "../../terminal/cell"
import grid "../../terminal/grid"
import plat_font "../../../platform/font"

_terminal_renderer_push_emoji :: #force_inline proc(
	r: ^Terminal_Renderer,
	eg: plat_font.Emoji_Glyph,
	x_pos, y_pos, gw, cell_h: f32,
	bg: [4]f32,
	is_focused: bool = true,
) {
	bg_rec := contract.Instance_Record{
		pos_size = {x_pos, y_pos, gw, cell_h},
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = bg,
	}
	instance.instance_renderer_push(&r.inst_rend, bg_rec)

	base_h := cell_h * 0.95
	scale := base_h / max(1.0, eg.height)
	draw_w := eg.width * scale
	draw_h := eg.height * scale
	offset_x := (gw - draw_w) * 0.5
	offset_y := (cell_h - draw_h) * 0.5

	emoji_rec := contract.Instance_Record{
		pos_size = {x_pos + offset_x, y_pos + offset_y, draw_w, draw_h},
		uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
		fg_color = {1, 1, 1, 1.0 if is_focused else 0.50},
		bg_color = {0, 0, 0, 0},
	}
	instance.instance_renderer_push(&r.emoji_rend, emoji_rec)
}

// _terminal_renderer_push_decoration paints a 1-2px rule using the background
// instance pass: uv_rect == {0,0,0,0} means "solid fill, ignore the atlas".
// Rules go through the overlay tail so they draw after glyph ink.
_terminal_renderer_push_decoration :: #force_inline proc(
	r: ^Terminal_Renderer,
	x, y, w, h: f32,
	color: [4]f32,
) {
	rec := contract.Instance_Record{
		pos_size = {x, y, w, h},
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = color,
	}
	instance.instance_renderer_push_overlay(&r.inst_rend, rec)
}

// _terminal_renderer_push_underline draws the stored SGR 4:n shape
// (single/double/dotted/dashed/curly).
_terminal_renderer_push_underline :: proc(
	r: ^Terminal_Renderer,
	ul_style: cell.Underline_Style,
	x, y, w, cell_h: f32,
	color: [4]f32,
) {
	thickness := max(1.0, math.floor(cell_h * 0.06))
	base_y := y + cell_h - thickness
	switch ul_style {
	case .Double:
		_terminal_renderer_push_decoration(r, x, base_y, w, thickness, color)
		_terminal_renderer_push_decoration(r, x, base_y - thickness * 2.0, w, thickness, color)
	case .Curly:
		n := max(1, int(w / max(1.0, thickness * 2.0)))
		seg_w := w / f32(n)
		for i in 0 ..< n {
			fx := (f32(i) + 0.5) / f32(n)
			wave := math.sin(fx * 6.2831853) * cell_h * 0.08
			_terminal_renderer_push_decoration(r, x + f32(i) * seg_w, base_y - thickness + wave, seg_w, thickness, color)
		}
	case .Dotted:
		n := max(1, int(w / 3.0))
		seg_w := w / f32(n)
		for i in 0 ..< n {
			_terminal_renderer_push_decoration(r, x + f32(i) * seg_w, base_y, seg_w * 0.5, thickness, color)
		}
	case .Dashed:
		n := max(1, int(w / 4.0))
		seg_w := w / f32(n)
		for i in 0 ..< n {
			_terminal_renderer_push_decoration(r, x + f32(i) * seg_w, base_y, seg_w * 0.6, thickness, color)
		}
	case .Single, .None:
		_terminal_renderer_push_decoration(r, x, base_y, w, thickness, color)
	}
}

_terminal_renderer_push_decorations :: #force_inline proc(
	r: ^Terminal_Renderer,
	style: cell.Style_Flags,
	dc: cell.Direct_Color,
	x, y, w, cell_h: f32,
	fg: [4]f32,
) {
	if .Underline in style {
		ul_style := dc.underline_style
		if ul_style == .None do ul_style = .Single
		_terminal_renderer_push_underline(r, ul_style, x, y, w, cell_h, _terminal_renderer_underline_rgb(dc, fg))
	}
	if .Strike in style {
		thickness := max(1.0, math.floor(cell_h * 0.06))
		_terminal_renderer_push_decoration(r, x, y + cell_h * 0.55, w, thickness, fg)
	}
}

_terminal_renderer_push_glyph :: #force_inline proc(
	r: ^Terminal_Renderer,
	gam: ^plat_font.Glyph_Atlas_Manager,
	slot: u32,
	x_pos, y_pos, cell_h: f32,
	fg, bg: [4]f32,
	is_italic: bool = false,
	is_bold: bool = false,
) {
	slot_info := gam.atlas.slots[slot]
	u1 := -slot_info.u1 if is_italic else slot_info.u1
	v1 := -slot_info.v1 if is_bold else slot_info.v1
	rec := contract.Instance_Record{
		pos_size = {x_pos + slot_info.offset_x, y_pos, slot_info.draw_w, cell_h},
		uv_rect  = {slot_info.u0, slot_info.v0, u1, v1},
		fg_color = fg,
		bg_color = bg,
	}
	instance.instance_renderer_push(&r.inst_rend, rec)
}

_apply_row_ligatures :: proc(
	cache: ^plat_font.Ligature_Cache,
	r: ^plat_font.Font_Rasterizer,
	row: ^grid.Row,
	cols: int,
	out_chars: []u32,
) {
	limit := min(cols, len(row.cells), len(out_chars))
	for c in 0..<limit {
		out_chars[c] = u32(row.cells[c].char)
	}
	if cache == nil || r == nil || r.hb_font == nil do return

	run_buf: [plat_font.LIGATURE_RUN_MAX]u8
	col := 0
	for col < limit {
		run_len := 0
		for col + run_len < limit && run_len < len(run_buf) {
			ch := row.cells[col + run_len].char
			if ch >= 128 || !plat_font.is_ligature_candidate(u8(ch)) do break
			run_buf[run_len] = u8(ch)
			run_len += 1
		}
		if run_len == 0 {
			col += 1
			continue
		}
		if glyphs, is_lig := plat_font.ligature_cache_lookup(cache, r, run_buf[:run_len]); is_lig {
			for g_id, i in glyphs {
				if g_id != 0 do out_chars[col + i] = plat_font.CONTENT_LIGATURE_BASE + g_id
			}
		}
		col += run_len
	}
}

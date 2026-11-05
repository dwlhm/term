package render_terminal

// Dedicated Cursor Cell Quad & Glyph Encoder.
// Part of Tier 1 Autonomous Core Render Engine (src/core/render/terminal/*).
//
// Invariant: ZERO OS/Platform dependencies, ZERO heap allocations during per-frame render loop.

import contract "../contract"
import "instance"
import plat_font "../../../platform/font"
import core_terminal "../../../core/terminal"

// terminal_renderer_encode_cursor rasters a single focused cursor cell (solid block, beam,
// or underline with optional high-contrast text glyph) directly onto target_view.
terminal_renderer_encode_cursor :: proc(
	r: ^Terminal_Renderer,
	enc: contract.Gpu_CommandEncoder,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	cell_w, cell_h: f32,
	ch: rune,
	is_wide, is_italic, is_bold: bool,
	shape: core_terminal.Cursor_Shape,
	cursor_color: [4]f32,
	cursor_text_color: [4]f32,
	border_radius: f32,
) {
	if r == nil || rawptr(enc) == nil || rawptr(target_view) == nil do return

	target_w := cell_w * 2.0 if is_wide else cell_w
	target_h := cell_h

	u_data := [4]f32{target_w, target_h, cell_w, cell_h}
	contract.write_buffer(r.queue, r.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	instance.instance_renderer_begin(&r.inst_rend)

	switch shape {
	case .Block:
		bg_rec := contract.Instance_Record{
			pos_size = {0, 0, target_w, target_h},
			uv_rect  = {target_w, target_h, border_radius, 1.0 if border_radius > 0.0 else 0.0},
			fg_color = {0, 0, 0, 0},
			bg_color = cursor_color,
		}
		instance.instance_renderer_push(&r.inst_rend, bg_rec)

		if ch > ' ' && text_atlas != nil {
			gam := &text_atlas.glyph_atlas
			slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
			if ok && int(slot) < len(gam.atlas.slots) {
				slot_info := gam.atlas.slots[slot]
				u1 := -slot_info.u1 if is_italic else slot_info.u1
				v1 := -slot_info.v1 if is_bold else slot_info.v1
				rec := contract.Instance_Record{
					pos_size = {slot_info.offset_x, 0, slot_info.draw_w, cell_h},
					uv_rect  = {slot_info.u0, slot_info.v0, u1, v1},
					fg_color = cursor_text_color,
					bg_color = {0, 0, 0, 0},
				}
				instance.instance_renderer_push(&r.inst_rend, rec)
			}
		}

	case .Beam:
		beam_w := max(f32(1.5), f32(2.0))
		instance.instance_renderer_push(&r.inst_rend, contract.Instance_Record{
			pos_size = {0, 0, beam_w, target_h},
			uv_rect  = {beam_w, target_h, 0.0, 0.0},
			fg_color = {0, 0, 0, 0},
			bg_color = cursor_color,
		})

	case .Underline:
		line_h := max(f32(1.5), f32(2.0))
		instance.instance_renderer_push(&r.inst_rend, contract.Instance_Record{
			pos_size = {0, target_h - line_h, target_w, line_h},
			uv_rect  = {target_w, line_h, 0.0, 0.0},
			fg_color = {0, 0, 0, 0},
			bg_color = cursor_color,
		})
	}

	instance.instance_renderer_flush(&r.inst_rend)

	pass := contract.begin_render_pass(enc, target_view, {0, 0, 0, 0}, .Clear)
	if rawptr(pass) != nil {
		front_count := instance.instance_renderer_front_count(&r.inst_rend)
		if front_count > 0 {
			contract.render_set_pipeline(pass, r.bg_pipeline)
			contract.render_set_bind_group(pass, 0, r.inst_rend.bg_bind_group)
			contract.render_set_vertex_buffer(pass, 0, r.inst_rend.instance_buffer, 0)
			contract.render_draw(pass, 6, front_count)

			instance.instance_renderer_draw(&r.inst_rend, pass)
		}
		contract.end_render_pass(pass)
	}
}

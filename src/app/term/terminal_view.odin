package term

// Terminal Grid Instance Batching, Cursor & Selection Render Pass
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import atlas "../../core/render/atlas"
import contract "../../core/render/contract"
import terminal_instance "../../core/render/terminal/instance"
import terminal_grid "../../core/terminal/grid"
import egc "../../core/terminal/egc"
import sess_feat "../../features/session"

GLYPH_WGSL :: #load("../../core/render/shaders/glyph.wgsl", string)
BG_WGSL    :: #load("../../core/render/shaders/bg.wgsl", string)
EMOJI_WGSL :: #load("../../core/render/shaders/emoji.wgsl", string)

Terminal_View :: struct {
	device:         contract.Gpu_Device,
	queue:          contract.Gpu_Queue,
	format:         contract.Gpu_Format,
	inst_rend:      terminal_instance.Instance_Renderer,
	glyph_pipeline: contract.Gpu_RenderPipeline,
	glyph_layout:   contract.Gpu_BindGroupLayout,
	bg_pipeline:    contract.Gpu_RenderPipeline,
	bg_layout:      contract.Gpu_BindGroupLayout,
	emoji_rend:     terminal_instance.Instance_Renderer,
	emoji_pipeline: contract.Gpu_RenderPipeline,
	emoji_layout:   contract.Gpu_BindGroupLayout,
}

terminal_view_init :: proc(
	tv: ^Terminal_View,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	atlas_view: contract.Gpu_TextureView,
	emoji_view: contract.Gpu_TextureView,
) -> bool {
	if tv == nil do return false
	tv.device = device
	tv.queue = queue
	tv.format = format

	glyph_mod := contract.create_shader_module(device, GLYPH_WGSL)
	if rawptr(glyph_mod) == nil do return false
	defer contract.destroy_shader_module(glyph_mod)

	attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	layouts := []contract.Gpu_Vertex_Layout{
		{array_stride = size_of(contract.Instance_Record), step_mode = .Instance, attributes = attrs},
	}

	tv.glyph_pipeline = contract.create_render_pipeline(
		device, glyph_mod, "vs_main", glyph_mod, "fs_main", layouts, format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(tv.glyph_pipeline) == nil do return false
	tv.glyph_layout = contract.pipeline_get_bind_group_layout(tv.glyph_pipeline, 0)

	bg_mod := contract.create_shader_module(device, BG_WGSL)
	if rawptr(bg_mod) == nil do return false
	defer contract.destroy_shader_module(bg_mod)

	bg_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 48, shader_location = 3},
	}
	bg_layouts := []contract.Gpu_Vertex_Layout{
		{array_stride = size_of(contract.Instance_Record), step_mode = .Instance, attributes = bg_attrs},
	}

	tv.bg_pipeline = contract.create_render_pipeline(
		device, bg_mod, "vs_main", bg_mod, "fs_main", bg_layouts, format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(tv.bg_pipeline) == nil do return false
	tv.bg_layout = contract.pipeline_get_bind_group_layout(tv.bg_pipeline, 0)

	if !terminal_instance.instance_renderer_init(&tv.inst_rend, device, queue, 8192, atlas_view, format) {
		return false
	}

	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = tv.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = atlas_view, entry_type = .Texture_View},
		{binding = 2, sampler = tv.inst_rend.sampler, entry_type = .Sampler},
	}
	tv.inst_rend.bind_group = contract.create_bind_group(device, tv.glyph_layout, entries)

	bg_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = tv.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
	}
	tv.inst_rend.bg_bind_group = contract.create_bind_group(device, tv.bg_layout, bg_entries)
	tv.inst_rend.pipeline = tv.glyph_pipeline

	// Color emoji pipeline + instance batch (RGBA8 atlas sampled directly).
	emoji_mod := contract.create_shader_module(device, EMOJI_WGSL)
	if rawptr(emoji_mod) == nil do return false
	defer contract.destroy_shader_module(emoji_mod)

	emoji_attrs := []contract.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	emoji_layouts := []contract.Gpu_Vertex_Layout{
		{array_stride = size_of(contract.Instance_Record), step_mode = .Instance, attributes = emoji_attrs},
	}
	tv.emoji_pipeline = contract.create_render_pipeline(
		device, emoji_mod, "vs_main", emoji_mod, "fs_main", emoji_layouts, format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(tv.emoji_pipeline) == nil do return false
	tv.emoji_layout = contract.pipeline_get_bind_group_layout(tv.emoji_pipeline, 0)

	if !terminal_instance.instance_renderer_init(&tv.emoji_rend, device, queue, 4096, emoji_view, format) {
		return false
	}

	emoji_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = tv.emoji_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = emoji_view, entry_type = .Texture_View},
		{binding = 2, sampler = tv.emoji_rend.sampler, entry_type = .Sampler},
	}
	tv.emoji_rend.bind_group = contract.create_bind_group(device, tv.emoji_layout, emoji_entries)
	tv.emoji_rend.pipeline = tv.emoji_pipeline

	return true
}

terminal_view_destroy :: proc(tv: ^Terminal_View) {
	if tv == nil do return
	terminal_instance.instance_renderer_destroy(&tv.inst_rend)
	terminal_instance.instance_renderer_destroy(&tv.emoji_rend)
	if rawptr(tv.glyph_pipeline) != nil do contract.destroy_render_pipeline(tv.glyph_pipeline)
	if rawptr(tv.bg_pipeline) != nil do contract.destroy_render_pipeline(tv.bg_pipeline)
	if rawptr(tv.emoji_pipeline) != nil do contract.destroy_render_pipeline(tv.emoji_pipeline)
}

terminal_view_render_pane :: proc(
	tv: ^Terminal_View,
	sess: ^sess_feat.Terminal_Session,
	pane_rect: [4]f32,
	is_focused: bool,
	mouse: ^Mouse_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
	gam: ^Glyph_Atlas_Manager,
	emoji_atlas: ^Emoji_Atlas_Manager,
	metrics: Visual_Metrics,
	screen_w, screen_h: f32,
) {
	if tv == nil || sess == nil || rawptr(target_view) == nil || gam == nil do return

	cell_w := metrics.cell_w
	cell_h := metrics.cell_h
	pad_x := metrics.pane_pad_x
	pad_y := metrics.pane_pad_y

	terminal_instance.instance_renderer_begin(&tv.inst_rend)
	terminal_instance.instance_renderer_begin(&tv.emoji_rend)
	u_data := [4]f32{screen_w, screen_h, cell_w, cell_h}
	contract.write_buffer(tv.queue, tv.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))
	contract.write_buffer(tv.queue, tv.emoji_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	// 1. Emit Solid Background Card for Pane
	pane_bg := contract.Instance_Record{
		pos_size = pane_rect,
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = COLOR_PANE_BG,
	}
	terminal_instance.instance_renderer_push(&tv.inst_rend, pane_bg)

	g := &sess.term.grid
	rows := min(sess.term.rows, int((pane_rect[3] - 2.0 * pad_y) / cell_h))
	cols := min(sess.term.cols, int((pane_rect[2] - 2.0 * pad_x) / cell_w))

	// 2. Physical cells to instance records in screen coordinates
	for r in 0..<rows {
		phy_r := terminal_grid.grid_physical_row(g, r - sess.scroll_offset)
		if phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]
		y_pos := pane_rect[1] + pad_y + f32(r) * cell_h

		for c in 0..<cols {
			if c >= len(row.cells) do break
			cell_val := row.cells[c]

			// Skip wide continuation cell as it was already drawn by the lead cell
			if .Wide_Continuation in cell_val.flags {
				continue
			}

			if (cell_val.char == 0 || cell_val.char == ' ') && cell_val.bg == 0 && cell_val.style == {} {
				continue
			}

			ch := cell_val.char
			is_wide := .Wide_Lead in cell_val.flags

			fg := color_from_palette_256(cell_val.fg)
			bg := color_from_palette_256(cell_val.bg) if cell_val.bg != 0 else COLOR_PANE_BG
			if .Bold in cell_val.style && cell_val.fg < 8 {
				fg = PALETTE_COLORS[(cell_val.fg + 8) & 15]
			}
			if .Dim in cell_val.style {
				fg[0] *= 0.6; fg[1] *= 0.6; fg[2] *= 0.6
			}
			if .Invert in cell_val.style {
				fg, bg = bg, fg
			}

			// Active selection highlight
			if mouse != nil && mouse.selection.active {
				min_r := min(mouse.selection.start_cell.row, mouse.selection.end_cell.row)
				max_r := max(mouse.selection.start_cell.row, mouse.selection.end_cell.row)
				min_c := min(mouse.selection.start_cell.col, mouse.selection.end_cell.col)
				max_c := max(mouse.selection.start_cell.col, mouse.selection.end_cell.col)
				if r >= min_r && r <= max_r && c >= min_c && c <= max_c {
					fg = {1.0, 1.0, 1.0, 1.0}
					bg = COLOR_SELECTION_BG
				}
			}

			gw := cell_w * 2.0 if is_wide else cell_w
			x_pos := pane_rect[0] + pad_x + f32(c) * cell_w

			// Grapheme cluster (combining marks, ZWJ emoji, keycap, RI pair, VS16).
			if .Has_Egc in cell_val.flags {
				if runes := egc.egc_pool_get(&sess.term.egc_pool, int(ch - egc.EGC_INDEX_BASE)); runes != nil && len(runes) > 0 {
					handled := false
					if emoji_atlas != nil && is_emoji_cluster(runes) {
						if eg, eok := emoji_atlas_get_runes(emoji_atlas, runes); eok {
							bg_rec := contract.Instance_Record{
								pos_size = {x_pos, y_pos, gw, cell_h},
								uv_rect  = {0, 0, 0, 0},
								fg_color = {0, 0, 0, 0},
								bg_color = bg,
							}
							terminal_instance.instance_renderer_push(&tv.inst_rend, bg_rec)
							emoji_rec := contract.Instance_Record{
								pos_size = {x_pos, y_pos, gw, cell_h},
								uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
								fg_color = {1, 1, 1, 1},
								bg_color = {0, 0, 0, 0},
							}
							terminal_instance.instance_renderer_push(&tv.emoji_rend, emoji_rec)
							handled = true
						}
					}
					if !handled {
						if slot, sok := glyph_atlas_get_or_rasterize_cluster(gam, runes, is_wide); sok {
							u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, gw, cell_h)
							rec := contract.Instance_Record{
								pos_size = {x_pos, y_pos, gw, cell_h},
								uv_rect  = {u0, v0, u1, v1},
								fg_color = fg,
								bg_color = bg,
							}
							terminal_instance.instance_renderer_push(&tv.inst_rend, rec)
							handled = true
						}
					}
					if handled do continue
					ch = runes[0] // Fall back to rendering the base rune.
				} else {
					continue // Unresolvable EGC: background only.
				}
			}

			// Color emoji: background stays in the main batch (drawn by the bg
			// pass); the color bitmap goes to the dedicated emoji batch so it is
			// sampled unchanged from the RGBA8 emoji atlas.
			if emoji_atlas != nil && is_emoji_codepoint(ch) {
				bg_rec := contract.Instance_Record{
					pos_size = {x_pos, y_pos, gw, cell_h},
					uv_rect  = {0, 0, 0, 0},
					fg_color = {0, 0, 0, 0},
					bg_color = bg,
				}
				terminal_instance.instance_renderer_push(&tv.inst_rend, bg_rec)

				if eg, eok := emoji_atlas_get(emoji_atlas, ch); eok {
					emoji_rec := contract.Instance_Record{
						pos_size = {x_pos, y_pos, gw, cell_h},
						uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
						fg_color = {1, 1, 1, 1},
						bg_color = {0, 0, 0, 0},
					}
					terminal_instance.instance_renderer_push(&tv.emoji_rend, emoji_rec)
				}
				continue
			}

			slot, ok := glyph_atlas_get_or_rasterize(gam, ch, is_wide)
			if !ok {
				slot = 0 // Space
			}
			u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, gw, cell_h)

			rec := contract.Instance_Record{
				pos_size = {x_pos, y_pos, gw, cell_h},
				uv_rect  = {u0, v0, u1, v1},
				fg_color = fg,
				bg_color = bg,
			}
			terminal_instance.instance_renderer_push(&tv.inst_rend, rec)
		}
	}

	// Synchronize GPU atlas texture if new glyphs were dynamically rasterized
	if gam.atlas.gpu_dirty {
		glyph_atlas_upload(gam, tv.device, tv.queue)
	}
	if emoji_atlas != nil && emoji_atlas.gpu_dirty {
		emoji_atlas_upload(emoji_atlas, tv.device, tv.queue)
	}

	terminal_instance.instance_renderer_flush(&tv.inst_rend)
	terminal_instance.instance_renderer_flush(&tv.emoji_rend)

	enc := contract.create_command_encoder(tv.device)
	if rawptr(enc) == nil do return

	pass := contract.begin_render_pass(enc, target_view, {0.08, 0.09, 0.12, 1.0}, .Load)
	if rawptr(pass) != nil {
		if tv.inst_rend.active_count > 0 {
			contract.render_set_pipeline(pass, tv.bg_pipeline)
			contract.render_set_bind_group(pass, 0, tv.inst_rend.bg_bind_group)
			contract.render_set_vertex_buffer(pass, 0, tv.inst_rend.instance_buffer, 0)
			contract.render_draw(pass, 6, tv.inst_rend.active_count)

			terminal_instance.instance_renderer_draw(&tv.inst_rend, pass)
		}
		if tv.emoji_rend.active_count > 0 {
			terminal_instance.instance_renderer_draw(&tv.emoji_rend, pass)
		}
		contract.end_render_pass(pass)
	}

	cmd := contract.finish_command_buffer(enc)
	if rawptr(cmd) != nil {
		contract.submit(tv.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.release_command_encoder(enc)
}

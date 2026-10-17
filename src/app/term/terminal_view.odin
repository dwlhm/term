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
import plat_font "../../platform/font"

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

	if !terminal_instance.instance_renderer_init(&tv.inst_rend, device, queue, 16384, atlas_view, format) {
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

terminal_view_resolve_active_bg :: proc(sess: ^sess_feat.Terminal_Session) -> [4]f32 {
	if sess == nil do return COLOR_PANE_BG

	// 1. Explicit OSC 11 background
	if sess.has_custom_bg {
		return sess.custom_bg
	}

	// 2. Active TUI grid background sampling
	// Sample center of screen first, then top/bottom corners
	g := &sess.term.grid
	rows := sess.term.rows
	cols := sess.term.cols
	if rows <= 0 || cols <= 0 || len(g.rows) == 0 do return COLOR_PANE_BG

	mid_r := rows / 2
	mid_c := cols / 2
	probe_points := [4][2]int{
		{mid_r, mid_c}, // Dead center of TUI canvas
		{0, 0},         // Top left
		{1, 0},         // Second row left (below header)
		{rows - 1, 0},  // Bottom row left (statusline or command line)
	}

	for pt in probe_points {
		r := pt[0]
		c := pt[1]
		if r < 0 || r >= rows do continue
		phy_r := terminal_grid.grid_physical_row(g, r - sess.scroll_offset)
		if phy_r < 0 || phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]
		if c < 0 || c >= len(row.cells) do continue

		cell_val := row.cells[c]
		if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) && row.direct_colors[c].has_bg {
			dc := row.direct_colors[c].bg
			return [4]f32{f32(dc[0]) / 255.0, f32(dc[1]) / 255.0, f32(dc[2]) / 255.0, 1.0}
		}
		if cell_val.bg != 0 {
			return color_from_palette_256(cell_val.bg)
		}
	}

	// 3. Parser active background if cursor has direct color bg
	if sess.term.parser.cursor.direct_color.has_bg {
		dc := sess.term.parser.cursor.direct_color.bg
		return [4]f32{f32(dc[0]) / 255.0, f32(dc[1]) / 255.0, f32(dc[2]) / 255.0, 1.0}
	}
	if sess.term.parser.cursor.active_bg != 0 {
		return color_from_palette_256(sess.term.parser.cursor.active_bg)
	}

	return COLOR_PANE_BG
}

terminal_view_render_pane :: proc(
	tv: ^Terminal_View,
	sess: ^sess_feat.Terminal_Session,
	pane_id: u32,
	pane_rect: [4]f32,
	is_focused: bool,
	mouse: ^Mouse_State,
	time_elapsed: f32,
	target_view: contract.Gpu_TextureView,
	text_atlas: ^plat_font.Text_Atlas,
	metrics: Visual_Metrics,
	screen_w, screen_h: f32,
) {
	if tv == nil || sess == nil || rawptr(target_view) == nil || text_atlas == nil do return

	gam := &text_atlas.glyph_atlas
	emoji_atlas := &text_atlas.emoji_atlas

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
	active_bg := terminal_view_resolve_active_bg(sess)
	pane_bg := contract.Instance_Record{
		pos_size = pane_rect,
		uv_rect  = {0, 0, 0, 0},
		fg_color = {0, 0, 0, 0},
		bg_color = active_bg,
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

			// Skip wide continuation cell only if its predecessor is an active wide lead
			if .Wide_Continuation in cell_val.flags {
				if c > 0 && .Wide_Lead in row.cells[c - 1].flags {
					continue
				}
			}

			has_direct_bg := false
			if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) {
				has_direct_bg = row.direct_colors[c].has_bg
			}

			if (cell_val.char == 0 || cell_val.char == ' ') && cell_val.bg == 0 && cell_val.style == {} && !has_direct_bg {
				continue
			}

			ch := cell_val.char
			is_wide := .Wide_Lead in cell_val.flags

			fg := color_from_palette_256(cell_val.fg)
			bg := color_from_palette_256(cell_val.bg) if cell_val.bg != 0 else COLOR_PANE_BG
			if .Has_Direct_Color in cell_val.flags && c < len(row.direct_colors) {
				dc := row.direct_colors[c]
				if dc.has_fg {
					fg = {f32(dc.fg[0]) / 255.0, f32(dc.fg[1]) / 255.0, f32(dc.fg[2]) / 255.0, 1.0}
				}
				if dc.has_bg {
					bg = {f32(dc.bg[0]) / 255.0, f32(dc.bg[1]) / 255.0, f32(dc.bg[2]) / 255.0, 1.0}
				}
			}
			if .Bold in cell_val.style && cell_val.fg < 8 && (.Has_Direct_Color not_in cell_val.flags || !row.direct_colors[c].has_fg) {
				fg = PALETTE_COLORS[(cell_val.fg + 8) & 15]
			}
			if .Dim in cell_val.style {
				fg[0] *= 0.6; fg[1] *= 0.6; fg[2] *= 0.6
			}
			if .Invert in cell_val.style {
				fg, bg = bg, fg
			}

			// Active selection highlight (dynamically attached to buffer logical row)
			cell_logical_r := r - sess.scroll_offset
			if mouse != nil && mouse.selection.active && mouse.selection.pane_id == pane_id && selection_contains_cell(mouse.selection, cell_logical_r, c) {
				fg = {1.0, 1.0, 1.0, 1.0}
				bg = COLOR_SELECTION_BG
			}

			gw := cell_w * 2.0 if is_wide else cell_w
			x_pos := pane_rect[0] + pad_x + f32(c) * cell_w

			// Grapheme cluster (combining marks, ZWJ emoji, keycap, RI pair, VS16).
			if .Has_Egc in cell_val.flags {
				if runes := egc.egc_pool_get(&sess.term.egc_pool, int(ch - egc.EGC_INDEX_BASE)); runes != nil && len(runes) > 0 {
					handled := false
					if emoji_atlas != nil && plat_font.is_emoji_cluster(runes) {
						if eg, eok := plat_font.emoji_atlas_get_runes(emoji_atlas, runes); eok {
							bg_rec := contract.Instance_Record{
								pos_size = {x_pos, y_pos, gw, cell_h},
								uv_rect  = {0, 0, 0, 0},
								fg_color = {0, 0, 0, 0},
								bg_color = bg,
							}
							terminal_instance.instance_renderer_push(&tv.inst_rend, bg_rec)

							base_h := cell_h * 0.95
							scale := base_h / max(1.0, eg.height)
							draw_w := eg.width * scale
							draw_h := eg.height * scale
							offset_x := (gw - draw_w) * 0.5
							offset_y := (cell_h - draw_h) * 0.5

							emoji_rec := contract.Instance_Record{
								pos_size = {x_pos + offset_x, y_pos + offset_y, draw_w, draw_h},
								uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
								fg_color = {1, 1, 1, 1},
								bg_color = {0, 0, 0, 0},
							}
							terminal_instance.instance_renderer_push(&tv.emoji_rend, emoji_rec)
							handled = true
						}
					}
					if !handled {
						if slot, sok := plat_font.glyph_atlas_get_or_rasterize_cluster(gam, runes, is_wide); sok {
							slot_info := gam.atlas.slots[slot]
							rec := contract.Instance_Record{
								pos_size = {x_pos + slot_info.offset_x, y_pos, slot_info.draw_w, cell_h},
								uv_rect  = {slot_info.u0, slot_info.v0, slot_info.u1, slot_info.v1},
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
			if emoji_atlas != nil && plat_font.is_emoji_codepoint(ch) {
				bg_rec := contract.Instance_Record{
					pos_size = {x_pos, y_pos, gw, cell_h},
					uv_rect  = {0, 0, 0, 0},
					fg_color = {0, 0, 0, 0},
					bg_color = bg,
				}
				terminal_instance.instance_renderer_push(&tv.inst_rend, bg_rec)

				if eg, eok := plat_font.emoji_atlas_get(emoji_atlas, ch); eok {
					base_h := cell_h * 0.95
					scale := base_h / max(1.0, eg.height)
					draw_w := eg.width * scale
					draw_h := eg.height * scale
					offset_x := (gw - draw_w) * 0.5
					offset_y := (cell_h - draw_h) * 0.5

					emoji_rec := contract.Instance_Record{
						pos_size = {x_pos + offset_x, y_pos + offset_y, draw_w, draw_h},
						uv_rect  = {eg.u0, eg.v0, eg.u1, eg.v1},
						fg_color = {1, 1, 1, 1},
						bg_color = {0, 0, 0, 0},
					}
					terminal_instance.instance_renderer_push(&tv.emoji_rend, emoji_rec)
				}
				continue
			}

			slot, ok := plat_font.glyph_atlas_get_or_rasterize(gam, ch, is_wide)
			if !ok {
				slot = 0 // Space
			}
			slot_info := gam.atlas.slots[slot]

			rec := contract.Instance_Record{
				pos_size = {x_pos + slot_info.offset_x, y_pos, slot_info.draw_w, cell_h},
				uv_rect  = {slot_info.u0, slot_info.v0, slot_info.u1, slot_info.v1},
				fg_color = fg,
				bg_color = bg,
			}
			terminal_instance.instance_renderer_push(&tv.inst_rend, rec)
		}
	}

	// Synchronize GPU atlas texture if new glyphs were dynamically rasterized
	plat_font.text_atlas_sync_gpu(text_atlas, tv.device, tv.queue)

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

package main

// Terminal Text Rasterization & Glyph Pipeline
// Part of Tier 3 Application Shell (app_*).

import "base:runtime"
import "core:os"
import "core:math"
import "vendor:sdl3"

import helper "../cmd/harness_helper"
import contract "../core/render/contract"
import atlas "../core/render/atlas"
import terminal_instance "../core/render/terminal/instance"
import terminal_grid "../core/terminal/grid"
import three_d "../core/render/three_d"
import tabs_feat "../features/tabs"
import mux_feat "../features/multiplexer"
import inter_feat "../features/interaction"
import sess_feat "../features/session"

GLYPH_WGSL :: #load("../core/render/shaders/glyph.wgsl", string)
BG_WGSL :: #load("../core/render/shaders/bg.wgsl", string)

CELL_WIDTH:  f32 : 9.5
CELL_HEIGHT: f32 : 19.0

RAW_PALETTE_COLORS := [16][4]f32{
	{0.08, 0.09, 0.11, 1.0}, // 0: Default dark bg
	{0.88, 0.42, 0.46, 1.0}, // 1: Red
	{0.60, 0.76, 0.47, 1.0}, // 2: Green
	{0.90, 0.75, 0.48, 1.0}, // 3: Yellow
	{0.38, 0.69, 0.94, 1.0}, // 4: Blue
	{0.78, 0.47, 0.87, 1.0}, // 5: Magenta
	{0.34, 0.71, 0.76, 1.0}, // 6: Cyan
	{0.67, 0.70, 0.75, 1.0}, // 7: Light Gray
	{0.36, 0.39, 0.44, 1.0}, // 8: Dark Gray
	{1.00, 0.47, 0.51, 1.0}, // 9: Bright Red
	{0.67, 0.86, 0.51, 1.0}, // 10: Bright Green
	{1.00, 0.82, 0.51, 1.0}, // 11: Bright Yellow
	{0.43, 0.75, 1.00, 1.0}, // 12: Bright Blue
	{0.86, 0.55, 0.94, 1.0}, // 13: Bright Magenta
	{0.39, 0.78, 0.86, 1.0}, // 14: Bright Cyan
	{0.94, 0.94, 0.96, 1.0}, // 15: Bright White
}

init_terminal_renderer :: proc(app: ^Term_App) -> bool {
	if !atlas.atlas_init(&app.atlas) do return false

	font_path := "assets/fonts/MapleMono-NF-Regular.ttf"
	r: helper.Font_Rasterizer
	has_font := false
	if os.is_file(font_path) {
		err: helper.Font_Error
		has_font = helper.font_rasterizer_init(&r, font_path, 32.0, &err)
	}

	if has_font {
		defer helper.font_rasterizer_destroy(&r)
		for cp in u32(32)..=126 {
			slot := cp - 32
			px, py := atlas.atlas_slot_origin(slot)
			helper.font_rasterize_glyph_into(
				&r,
				cp,
				app.atlas.pixels,
				atlas.ATLAS_WIDTH,
				int(px),
				int(py),
				atlas.ATLAS_GLYPH_SIZE,
				atlas.ATLAS_GLYPH_SIZE,
			)
			app.atlas.slots[slot].valid = true
		}
	} else {
		for cp in u32(33)..=126 {
			slot := cp - 32
			px, py := atlas.atlas_slot_origin(slot)
			for y in 14..<48 {
				for x in 16..<36 {
					if x == 16 || x == 35 || y == 14 || y == 47 || ((x * 3 + y * 7 + int(cp)) % 5 == 0) {
						app.atlas.pixels[(int(py) + y) * atlas.ATLAS_WIDTH + (int(px) + x)] = 255
					}
				}
			}
			app.atlas.slots[slot].valid = true
		}
	}

	if !atlas.atlas_upload_gpu(&app.atlas, app.device, app.queue) do return false

	glyph_mod := contract.create_shader_module(app.device, GLYPH_WGSL)
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

	app.glyph_pipeline = contract.create_render_pipeline(
		app.device, glyph_mod, "vs_main", glyph_mod, "fs_main", layouts, app.format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(app.glyph_pipeline) == nil do return false
	app.glyph_layout = contract.pipeline_get_bind_group_layout(app.glyph_pipeline, 0)

	bg_mod := contract.create_shader_module(app.device, BG_WGSL)
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

	app.bg_pipeline = contract.create_render_pipeline(
		app.device, bg_mod, "vs_main", bg_mod, "fs_main", bg_layouts, app.format, .Alpha_Blend, .Triangle_List,
	)
	if rawptr(app.bg_pipeline) == nil do return false
	app.bg_layout = contract.pipeline_get_bind_group_layout(app.bg_pipeline, 0)

	if !terminal_instance.instance_renderer_init(&app.inst_rend, app.device, app.queue, 4096, app.atlas.gpu_view, app.format) {
		return false
	}

	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = app.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
		{binding = 1, view = app.atlas.gpu_view, entry_type = .Texture_View},
		{binding = 2, sampler = app.inst_rend.sampler, entry_type = .Sampler},
	}
	app.inst_rend.bind_group = contract.create_bind_group(app.device, app.glyph_layout, entries)

	bg_entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = app.inst_rend.uniform_buffer, offset = 0, size = 0, entry_type = .Buffer},
	}
	app.inst_rend.bg_bind_group = contract.create_bind_group(app.device, app.bg_layout, bg_entries)
	app.inst_rend.pipeline = app.glyph_pipeline

	return true
}

destroy_terminal_renderer :: proc(app: ^Term_App) {
	if app == nil do return
	terminal_instance.instance_renderer_destroy(&app.inst_rend)
	if rawptr(app.glyph_pipeline) != nil do contract.destroy_render_pipeline(app.glyph_pipeline)
	if rawptr(app.bg_pipeline) != nil do contract.destroy_render_pipeline(app.bg_pipeline)
	atlas.atlas_destroy(&app.atlas)
}

render_terminal_grid :: proc(app: ^Term_App, pane: ^mux_feat.Pane_Entry, view: contract.Gpu_TextureView, pane_w, pane_h: f32) {
	if app == nil || pane == nil || pane.session == nil || rawptr(view) == nil do return

	terminal_instance.instance_renderer_begin(&app.inst_rend)
	u_data := [4]f32{pane_w, pane_h, CELL_WIDTH, CELL_HEIGHT}
	contract.write_buffer(app.queue, app.inst_rend.uniform_buffer, 0, &u_data, size_of([4]f32))

	g := &pane.session.term.grid
	rows := min(pane.session.term.rows, int((pane_h - 16.0) / CELL_HEIGHT))
	cols := min(pane.session.term.cols, int((pane_w - 24.0) / CELL_WIDTH))

	for r in 0..<rows {
		phy_r := terminal_grid.grid_physical_row(g, r)
		if phy_r >= len(g.rows) do continue
		row := &g.rows[phy_r]
		y_pos := 8.0 + f32(r) * CELL_HEIGHT

		for c in 0..<cols {
			if c >= len(row.cells) do break
			cell_val := row.cells[c]
			if (cell_val.char == 0 || cell_val.char == ' ') && cell_val.bg == 0 && cell_val.style == {} {
				continue
			}

			ch := cell_val.char
			slot: u32 = 0
			if ch >= 32 && ch <= 126 {
				slot = u32(ch - 32)
			}
			u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, f32(atlas.ATLAS_GLYPH_SIZE), f32(atlas.ATLAS_GLYPH_SIZE))

			fg := RAW_PALETTE_COLORS[cell_val.fg & 15] if cell_val.fg < 16 else RAW_PALETTE_COLORS[7]
			bg := RAW_PALETTE_COLORS[cell_val.bg & 15] if cell_val.bg < 16 else RAW_PALETTE_COLORS[0]
			if .Bold in cell_val.style && cell_val.fg < 8 {
				fg = RAW_PALETTE_COLORS[(cell_val.fg + 8) & 15]
			}
			if .Dim in cell_val.style {
				fg[0] *= 0.6; fg[1] *= 0.6; fg[2] *= 0.6
			}
			if .Invert in cell_val.style {
				fg, bg = bg, fg
			}

			if app.inter.selection.active && app.inter.selection.pane_id == pane.id {
				min_r := min(app.inter.selection.start_cell.row, app.inter.selection.end_cell.row)
				max_r := max(app.inter.selection.start_cell.row, app.inter.selection.end_cell.row)
				min_c := min(app.inter.selection.start_cell.col, app.inter.selection.end_cell.col)
				max_c := max(app.inter.selection.start_cell.col, app.inter.selection.end_cell.col)
				if r >= min_r && r <= max_r && c >= min_c && c <= max_c {
					fg = {1.0, 1.0, 1.0, 1.0}
					bg = {0.24, 0.42, 0.75, 1.0}
				}
			}

			rec := contract.Instance_Record{
				pos_size = {12.0 + f32(c) * CELL_WIDTH, y_pos, CELL_WIDTH, CELL_HEIGHT},
				uv_rect  = {u0, v0, u1, v1},
				fg_color = fg,
				bg_color = bg,
			}
			terminal_instance.instance_renderer_push(&app.inst_rend, rec)
		}
	}

	terminal_instance.instance_renderer_flush(&app.inst_rend)

	enc := contract.create_command_encoder(app.device)
	if rawptr(enc) == nil do return

	pass := contract.begin_render_pass(enc, view, {0.07, 0.08, 0.10, 1.0}, .Clear)
	if rawptr(pass) != nil {
		if app.inst_rend.active_count > 0 {
			contract.render_set_pipeline(pass, app.bg_pipeline)
			contract.render_set_bind_group(pass, 0, app.inst_rend.bg_bind_group)
			contract.render_set_vertex_buffer(pass, 0, app.inst_rend.instance_buffer, 0)
			contract.render_draw(pass, 6, app.inst_rend.active_count)

			terminal_instance.instance_renderer_draw(&app.inst_rend, pass)
		}
		contract.end_render_pass(pass)
	}

	cmd := contract.finish_command_buffer(enc)
	if rawptr(cmd) != nil {
		contract.submit(app.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.release_command_encoder(enc)
}

app_handle_key :: proc(app: ^Term_App, k: sdl3.Keycode, mod: sdl3.Keymod) {
	if k == sdl3.K_ESCAPE && (mod & sdl3.KMOD_SHIFT) != {} do app.running = false
	mods: inter_feat.Modifier_Flags
	if (mod & sdl3.KMOD_GUI) != {} do mods += {.Cmd}
	if (mod & sdl3.KMOD_SHIFT) != {} do mods += {.Shift}
	if (mod & sdl3.KMOD_CTRL) != {} do mods += {.Ctrl}
	if (mod & sdl3.KMOD_ALT) != {} do mods += {.Alt}

	p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	if .Cmd in mods {
		switch k {
		case sdl3.K_T:
			shell := os.get_env("SHELL", context.temp_allocator)
			if len(shell) == 0 do shell = "/bin/sh"
			term_cols := max(20, int((app.screen_w - 24.0) / CELL_WIDTH))
			term_rows := max(10, int((app.screen_h - CHROME_BAR_HEIGHT - 16.0) / CELL_HEIGHT))
			new_p, _ := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = term_rows, cols = term_cols})
			tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
		case sdl3.K_W:
			act_idx, _ := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
			if act_idx >= 0 do tabs_feat.tabs_manager_close_tab(&app.tabs_mgr, act_idx)
		case sdl3.K_V:
			if p != nil && p.session != nil && sdl3.HasClipboardText() {
				clip := sdl3.GetClipboardText()
				if clip != nil do sess_feat.session_write_string(p.session, string(cstring(rawptr(clip))))
			}
		case sdl3.K_3:
			mux_feat.multiplexer_toggle_zoom(&app.mux, app.primary_pane)
		case sdl3.K_EQUALS:
			three_d.three_d_set_mesh(&app.three_d_rend, (app.three_d_rend.active_mesh + 1) % 2)
		}
		act := inter_feat.interaction_on_key_press(&app.inter, &app.tabs_mgr, &app.mux, rune(k), mods)
		if act.kind == .Text_Copied && app.inter.clipboard_len > 0 {
			buf := make([]u8, app.inter.clipboard_len + 1, context.temp_allocator)
			copy(buf[:app.inter.clipboard_len], app.inter.clipboard_buf[:app.inter.clipboard_len])
			buf[app.inter.clipboard_len] = 0
			_ = sdl3.SetClipboardText(cstring(raw_data(buf)))
		}
	} else if .Ctrl in mods {
		if p != nil && p.session != nil {
			switch k {
			case sdl3.K_C: sess_feat.session_write_string(p.session, "\x03")
			case sdl3.K_D: sess_feat.session_write_string(p.session, "\x04")
			case sdl3.K_L: sess_feat.session_write_string(p.session, "\x0c")
			case sdl3.K_Z: sess_feat.session_write_string(p.session, "\x1a")
			case sdl3.K_A: sess_feat.session_write_string(p.session, "\x01")
			case sdl3.K_E: sess_feat.session_write_string(p.session, "\x05")
			case sdl3.K_U: sess_feat.session_write_string(p.session, "\x15")
			case sdl3.K_K: sess_feat.session_write_string(p.session, "\x0b")
			case sdl3.K_W: sess_feat.session_write_string(p.session, "\x17")
			case sdl3.K_R: sess_feat.session_write_string(p.session, "\x12")
			}
		}
	} else if p != nil && p.session != nil {
		switch k {
		case sdl3.K_RETURN, sdl3.K_KP_ENTER: sess_feat.session_write_string(p.session, "\r")
		case sdl3.K_BACKSPACE:              sess_feat.session_write_string(p.session, "\x7f")
		case sdl3.K_TAB:                    sess_feat.session_write_string(p.session, "\t")
		case sdl3.K_UP:                     sess_feat.session_write_string(p.session, "\x1b[A")
		case sdl3.K_DOWN:                   sess_feat.session_write_string(p.session, "\x1b[B")
		case sdl3.K_RIGHT:                  sess_feat.session_write_string(p.session, "\x1b[C")
		case sdl3.K_LEFT:                   sess_feat.session_write_string(p.session, "\x1b[D")
		case sdl3.K_HOME:                   sess_feat.session_write_string(p.session, "\x1b[H")
		case sdl3.K_END:                    sess_feat.session_write_string(p.session, "\x1b[F")
		case sdl3.K_PAGEUP:                 sess_feat.session_write_string(p.session, "\x1b[5~")
		case sdl3.K_PAGEDOWN:               sess_feat.session_write_string(p.session, "\x1b[6~")
		case sdl3.K_DELETE:                 sess_feat.session_write_string(p.session, "\x1b[3~")
		}
	}
}

package main

// Term Frame Presentation & Multi-Layer Composition
// Part of Tier 3 Application Shell (app_*).

import "base:runtime"
import "core:math"
import "vendor:wgpu"

import contract "../core/render/contract"
import composer "../core/composer"
import pipeline "../core/composer/pipeline"
import chrome_render "../core/render/chrome"
import chrome_dl "../core/chrome/draw_list"
import three_d "../core/render/three_d"
import tabs_feat "../features/tabs"
import mux_feat "../features/multiplexer"

_clear_layer :: proc(device: contract.Gpu_Device, queue: contract.Gpu_Queue, view: contract.Gpu_TextureView, col: [4]f64) {
	enc := contract.create_command_encoder(device)
	if rawptr(enc) == nil do return
	pass := contract.begin_render_pass(enc, view, col, .Clear)
	if rawptr(pass) != nil do contract.end_render_pass(pass)
	cmd := contract.finish_command_buffer(enc)
	if rawptr(cmd) != nil {
		contract.submit(queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.release_command_encoder(enc)
}

app_render_frame :: proc(app: ^Term_App) {
	tex, view, _ := contract.get_surface_texture(app.surface)
	if rawptr(view) == nil do return
	defer contract.release_surface_texture(tex, view)

	p_term := mux_feat.multiplexer_get_pane(&app.mux, app.primary_pane)
	p3 := mux_feat.multiplexer_get_pane(&app.mux, app.threed_pane)

	// 1. Layer 101: Terminal Pane (Render Monospace Cells + Backgrounds)
	if p_term != nil && p_term.rect[2] > 0 && p_term.rect[3] > 0 {
		w_t := max(u32(1), u32(p_term.rect[2]))
		h_t := max(u32(1), u32(p_term.rect[3]))
		l_t, ok := pipeline.composer_pipeline_acquire_layer(&app.composer_pipe, 101, .Terminal, w_t, h_t)
		if ok && l_t != nil {
			l_t.dest_rect = composer.rect_make(p_term.rect[0], p_term.rect[1], p_term.rect[2], p_term.rect[3])
			l_t.scissor_rect = l_t.dest_rect
			l_t.opacity = 1.0

			render_terminal_grid(app, p_term, l_t.view, p_term.rect[2], p_term.rect[3])
		}
	}

	// 2. Layer 102: 3D Canvas Pane (Gouraud Perspective Shader, only when visible)
	if p3 != nil && p3.rect[2] > 50 && p3.rect[3] > 50 {
		w_3 := max(u32(1), u32(p3.rect[2]))
		h_3 := max(u32(1), u32(p3.rect[3]))
		l_3, ok := pipeline.composer_pipeline_acquire_layer(&app.composer_pipe, 102, .Three_D, w_3, h_3, true)
		if ok && l_3 != nil && rawptr(l_3.depth_view) != nil {
			l_3.dest_rect = composer.rect_make(p3.rect[0], p3.rect[1], p3.rect[2], p3.rect[3])
			l_3.scissor_rect = l_3.dest_rect
			l_3.opacity = 1.0

			vp_h := max(f32(10), p3.rect[3] - 28.0)
			uniforms := three_d.interactor_compute_uniforms(&p3.interactor, p3.rect[2], vp_h, app.time_elapsed)
			wgpu_dev := wgpu.Device(rawptr(app.device))
			wgpu_enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
			if wgpu_enc != nil {
				color_att := wgpu.RenderPassColorAttachment{
					view       = wgpu.TextureView(rawptr(l_3.view)),
					loadOp     = .Clear,
					storeOp    = .Store,
					clearValue = wgpu.Color{ 0.04, 0.05, 0.08, 1.0 },
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				}
				depth_att := wgpu.RenderPassDepthStencilAttachment{
					view            = wgpu.TextureView(rawptr(l_3.depth_view)),
					depthLoadOp     = .Clear,
					depthStoreOp    = .Store,
					depthClearValue = 1.0,
				}
				pass_desc := wgpu.RenderPassDescriptor{
					colorAttachmentCount   = 1,
					colorAttachments       = &color_att,
					depthStencilAttachment = &depth_att,
				}
				pass := wgpu.CommandEncoderBeginRenderPass(wgpu_enc, &pass_desc)
				if pass != nil {
					wgpu.RenderPassEncoderSetViewport(pass, 0.0, 28.0, p3.rect[2], vp_h, 0.0, 1.0)
					three_d.three_d_draw(&app.three_d_rend, pass, &uniforms)
					wgpu.RenderPassEncoderEnd(pass)
					wgpu.RenderPassEncoderRelease(pass)
				}
				cmd_3d := rawptr(wgpu.CommandEncoderFinish(wgpu_enc, nil))
				if cmd_3d != nil {
					contract.submit(app.queue, cmd_3d)
					contract.release_command_buffer(cmd_3d)
				}
				wgpu.CommandEncoderRelease(wgpu_enc)
			}
		}
	} else {
		// Ensure 3D layer is hidden if pane is closed
		l_3 := pipeline.composer_pipeline_get_layer(&app.composer_pipe, 102)
		if l_3 != nil do l_3.opacity = 0.0
	}

	// 3. Layer 201: Chrome UI (Modern Tabs, Toolbar, Divider, Cursor)
	w_c := max(u32(1), u32(app.screen_w))
	h_c := max(u32(1), u32(app.screen_h))
	l_c, ok_c := pipeline.composer_pipeline_acquire_layer(&app.composer_pipe, 201, .Chrome, w_c, h_c)
	if ok_c && l_c != nil {
		l_c.dest_rect = composer.rect_make(0, 0, app.screen_w, app.screen_h)
		l_c.scissor_rect = l_c.dest_rect
		l_c.opacity = 1.0

		_clear_layer(app.device, app.queue, l_c.view, {0.0, 0.0, 0.0, 0.0})

		chrome_dl.ui_draw_list_clear(&app.draw_list)

		// Top Tab Bar background & subtle border
		chrome_dl.ui_draw_rect(&app.draw_list, {0, 0, app.screen_w, CHROME_BAR_HEIGHT}, {0.09, 0.10, 0.13, 1.0})
		chrome_dl.ui_draw_rect(&app.draw_list, {0, CHROME_BAR_HEIGHT - 1.0, app.screen_w, 1.0}, {0.16, 0.19, 0.25, 1.0})

		// Vertical divider separating native traffic lights (x=0..72) from tabs
		chrome_dl.ui_draw_rect(&app.draw_list, {74, 8, 1, 22}, {0.18, 0.22, 0.28, 0.8})

		// Render Tabs
		tabs_start_x: f32 = 82.0
		tab_w: f32 = 160.0
		for i in 0..<len(app.tabs_mgr.entries) {
			tab_x := tabs_start_x + f32(i) * (tab_w + 4.0)
			if tab_x + tab_w > app.screen_w - 140.0 do break
			is_active := (i == app.tabs_mgr.model.active_idx)

			bg_col := [4]f32{0.14, 0.17, 0.23, 1.0} if is_active else [4]f32{0.11, 0.13, 0.17, 0.6}
			chrome_dl.ui_draw_rounded_rect(&app.draw_list, {tab_x, 4, tab_w, 30}, bg_col, 5.0)

			if is_active {
				// Top electric blue accent line
				chrome_dl.ui_draw_rect(&app.draw_list, {tab_x + 6, 4, tab_w - 12, 2}, {0.22, 0.55, 0.98, 1.0})
			}

			// Tab close button [x]
			close_x := tab_x + tab_w - 20.0
			chrome_dl.ui_draw_rect(&app.draw_list, {close_x, 14, 8, 2}, {0.55, 0.60, 0.70, 0.8})
		}

		// New Tab Button [+]
		tab_count := f32(len(app.tabs_mgr.entries))
		btn_x := tabs_start_x + tab_count * (tab_w + 4.0) + 4.0
		if btn_x < app.screen_w - 140.0 {
			chrome_dl.ui_draw_rounded_rect(&app.draw_list, {btn_x, 7, 24, 24}, {0.16, 0.20, 0.28, 0.8}, 4.0)
			chrome_dl.ui_draw_rect(&app.draw_list, {btn_x + 7, 18, 10, 2}, {0.70, 0.75, 0.85, 1.0})
			chrome_dl.ui_draw_rect(&app.draw_list, {btn_x + 11, 14, 2, 10}, {0.70, 0.75, 0.85, 1.0})
		}

		// 3D Viewport Toggle Pill Button (Top-Right)
		is_3d_open := (p3 != nil && p3.rect[2] > 50)
		btn_3d_x := app.screen_w - 116.0
		btn_3d_col := [4]f32{0.18, 0.52, 0.92, 0.95} if is_3d_open else [4]f32{0.15, 0.18, 0.24, 0.85}
		chrome_dl.ui_draw_rounded_rect(&app.draw_list, {btn_3d_x, 7, 104, 24}, btn_3d_col, 5.0)
		// Icon indicator dot
		dot_col := [4]f32{0.40, 0.90, 0.60, 1.0} if is_3d_open else [4]f32{0.50, 0.55, 0.65, 1.0}
		chrome_dl.ui_draw_rounded_rect(&app.draw_list, {btn_3d_x + 8, 15, 8, 8}, dot_col, 4.0)

		// Terminal Pane Cursor (Crisp Monospace Grid)
		if p_term != nil && p_term.session != nil {
			cur_c := f32(p_term.session.term.parser.cursor.col)
			cur_r := f32(p_term.session.term.parser.cursor.row)
			cx := p_term.rect[0] + 12.0 + cur_c * CELL_WIDTH
			cy := p_term.rect[1] + 8.0 + cur_r * CELL_HEIGHT

			if cx + CELL_WIDTH <= p_term.rect[0] + p_term.rect[2] && cy + CELL_HEIGHT <= p_term.rect[1] + p_term.rect[3] {
				blink := 0.70 + 0.30 * math.sin(app.time_elapsed * 5.0)
				if p_term.is_focused {
					chrome_dl.ui_draw_rounded_rect(&app.draw_list, {cx, cy, CELL_WIDTH, CELL_HEIGHT}, {0.22, 0.65, 1.0, blink}, 2.0)
				} else {
					chrome_dl.ui_draw_border(&app.draw_list, {cx, cy, CELL_WIDTH, CELL_HEIGHT}, {0.50, 0.60, 0.70, 0.7}, 2.0)
				}
			}
		}

		// Split Divider & 3D Pane Header (Only rendered when 3D is open)
		if is_3d_open {
			// Vertical divider line between panes
			chrome_dl.ui_draw_rect(&app.draw_list, {p3.rect[0] - 1.0, CHROME_BAR_HEIGHT, 1.0, app.screen_h - CHROME_BAR_HEIGHT}, {0.20, 0.24, 0.32, 1.0})

			// 3D Header Bar
			chrome_dl.ui_draw_rect(&app.draw_list, {p3.rect[0], p3.rect[1], p3.rect[2], 28}, {0.09, 0.11, 0.15, 0.95})
			chrome_dl.ui_draw_rect(&app.draw_list, {p3.rect[0], p3.rect[1] + 27, p3.rect[2], 1}, {0.18, 0.22, 0.30, 1.0})

			// Pill Badge "3D VIEWPORT"
			badge_col := [4]f32{0.20, 0.65, 0.45, 1.0} if p3.is_focused else [4]f32{0.18, 0.22, 0.28, 1.0}
			chrome_dl.ui_draw_rounded_rect(&app.draw_list, {p3.rect[0] + 10, p3.rect[1] + 5, 80, 18}, badge_col, 4.0)

			// Close button [x] for 3D pane
			close_3d_x := p3.rect[0] + p3.rect[2] - 22.0
			chrome_dl.ui_draw_rect(&app.draw_list, {close_3d_x, p3.rect[1] + 13, 8, 2}, {0.60, 0.65, 0.75, 1.0})
		}

		chrome_render.chrome_renderer_mark_dirty(&app.chrome_rend, true)
		_ = chrome_render.chrome_renderer_render(&app.chrome_rend, &app.draw_list, l_c.view)
	}

	// 4. Composite Layers (Terminal -> 3D Canvas -> Chrome) into Swapchain View
	order := [3]composer.Layer_Id{101, 102, 201}
	pipeline.composer_pipeline_set_layer_order(&app.composer_pipe, order[:])
	pipeline.composer_pipeline_begin_frame(&app.composer_pipe)

	enc_comp := contract.create_command_encoder(app.device)
	if rawptr(enc_comp) != nil {
		_ = pipeline.composer_pipeline_composite(&app.composer_pipe, enc_comp, view)
		cmd_comp := contract.finish_command_buffer(enc_comp)
		if rawptr(cmd_comp) != nil {
			contract.submit(app.queue, cmd_comp)
			contract.release_command_buffer(cmd_comp)
		}
		contract.release_command_encoder(enc_comp)
	}

	contract.present_surface(app.surface)
	pipeline.composer_pipeline_end_frame(&app.composer_pipe)
}

package chrome

// Chrome UI Pillar GPU Engine.
// Part of core_render: Tier 1 Autonomous Core Primitives.
//
// Features Dual 3-Strategy architecture:
//   Strategy 1: Cached Surface (`chrome/surface/`) — Zero redraw for retained chrome.
//   Strategy 2: Dynamic Primitive Batch (`chrome/batch/`) — Frame scratch buffer batching.
//   Strategy 3: SDF Vector Shader (`chrome/sdf/`) — Crisp rounded corners & vector outlines.
//
// Consumes declarative Ui_Draw_List from `core_chrome` with ZERO reverse coupling.

import contract "../contract"
import "../../chrome/draw_list"
import "surface"
import "batch"
import "sdf"

Chrome_Renderer :: struct {
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	width:         u32,
	height:        u32,
	surface:       surface.Chrome_Surface,       // Strategy 1: Cached Surface
	batch:         batch.Chrome_Batch,           // Strategy 2: Dynamic Primitive Batch
	sdf:           sdf.Chrome_Sdf_Pipeline,      // Strategy 3: SDF Vector Shader
	active_strat:  int,                          // 1: Cached, 2: Batch, 3: SDF
	redraw_count:  u64,
	cached_frames: u64,
	available:     bool,
}

chrome_renderer_init :: proc(
	r: ^Chrome_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	width, height: u32,
	format: contract.Gpu_Format,
) -> bool {
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	r.device = device
	r.queue = queue
	r.format = format
	r.width = max(width, 1)
	r.height = max(height, 1)

	// Strategy 1: Initialize Cached Surface
	if !surface.chrome_surface_init(&r.surface, device, r.width, r.height, format) {
		return false
	}

	// Strategy 2: Initialize Dynamic Primitive Batch
	if !batch.chrome_batch_init(&r.batch, device, queue) {
		surface.chrome_surface_destroy(&r.surface)
		return false
	}

	// Strategy 3: Initialize SDF Vector Pipeline
	if !sdf.chrome_sdf_pipeline_init(&r.sdf, device, queue, format) {
		batch.chrome_batch_destroy(&r.batch)
		surface.chrome_surface_destroy(&r.surface)
		return false
	}

	r.available = true
	r.active_strat = 1
	return true
}

chrome_renderer_destroy :: proc(r: ^Chrome_Renderer) {
	if r == nil || !r.available do return

	sdf.chrome_sdf_pipeline_destroy(&r.sdf)
	batch.chrome_batch_destroy(&r.batch)
	surface.chrome_surface_destroy(&r.surface)

	r.available = false
}

chrome_renderer_resize :: proc(r: ^Chrome_Renderer, width, height: u32) -> bool {
	if r == nil || !r.available do return false
	r.width = max(width, 1)
	r.height = max(height, 1)
	return surface.chrome_surface_resize(&r.surface, r.device, r.width, r.height, r.format)
}

chrome_renderer_mark_dirty :: proc(r: ^Chrome_Renderer, dirty: bool = true) {
	if r != nil {
		surface.chrome_surface_mark_dirty(&r.surface, dirty)
	}
}

chrome_renderer_is_dirty :: proc(r: ^Chrome_Renderer) -> bool {
	if r == nil do return false
	return surface.chrome_surface_is_dirty(&r.surface)
}

// chrome_renderer_render executes UI draw list commands using the 3 strategies.
// When r.surface.is_dirty is false (Strategy 1), re-rasterization is skipped entirely.
// When dirty, commands are rendered into target (or cached surface) via Strategy 2 / Strategy 3.
chrome_renderer_render :: proc(
	r: ^Chrome_Renderer,
	dl: ^draw_list.Ui_Draw_List,
	target: contract.Gpu_TextureView,
) -> bool {
	if r == nil || !r.available || dl == nil do return false

	// Strategy 1: Check if surface is clean
	if !surface.chrome_surface_is_dirty(&r.surface) {
		r.cached_frames += 1
		r.active_strat = 1
		// Retained cache hit: zero redraw overhead
		return true
	}

	target_view := target
	if rawptr(target_view) == nil {
		target_view = r.surface.view
	}
	if rawptr(target_view) == nil do return false

	// Dirty: perform full redraw
	r.redraw_count += 1
	r.active_strat = 3 // SDF Vector shader active for geometric elements

	encoder := contract.create_command_encoder(r.device)
	if rawptr(encoder) == nil do return false
	defer contract.release_command_encoder(encoder)

	clear_col: [4]f64 = {0.0, 0.0, 0.0, 0.0}
	pass := contract.begin_render_pass(encoder, target_view, clear_col, .Load)
	if rawptr(pass) == nil do return false

	screen_sz := [2]f32{f32(r.width), f32(r.height)}
	sdf.chrome_sdf_pipeline_reset(&r.sdf)

	for cmd in dl.commands {
		#partial switch cmd.kind {
		case .Rect:
			params := sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = 0.0,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			sdf.chrome_sdf_draw(&r.sdf, pass, &params)

		case .Rounded_Rect:
			params := sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			sdf.chrome_sdf_draw(&r.sdf, pass, &params)

		case .Border:
			params := sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 1.0,
				color        = {0, 0, 0, 0},
				border_color = cmd.border_color,
			}
			sdf.chrome_sdf_draw(&r.sdf, pass, &params)

		case .Shadow:
			params := sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = 0.0,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			sdf.chrome_sdf_draw(&r.sdf, pass, &params)

		case .Text_Run, .Icon:
			// Non-SDF text/icon
		}
	}

	sdf.chrome_sdf_flush_and_draw(&r.sdf, pass)

	contract.end_render_pass(pass)
	cmd_buf := contract.finish_command_buffer(encoder)
	if cmd_buf != nil {
		contract.submit(r.queue, cmd_buf)
		contract.release_command_buffer(cmd_buf)
	}

	// Surface is now clean
	surface.chrome_surface_mark_dirty(&r.surface, false)
	return true
}

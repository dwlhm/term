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
import atlas "../atlas"
import "../../chrome/draw_list"
import "surface"
import "batch"
import "sdf"

_CHROME_PINNED_UI_RUNES := [12]rune{
	0x2318, // ⌘ command
	0x2325, // ⌥ option
	0x21E7, // ⇧ shift
	0x2303, // ⌃ control
	0x21E5, // ⇥ tab
	0x21B5, // ↵ return
	0x2715, // ✕ close
	0x00B7, // · middle dot
	0x2026, // … horizontal ellipsis
	0x2191, // ↑ up arrow
	0x2193, // ↓ down arrow
	0x25CB, // ○ white circle
}

_chrome_lookup_pinned_slot :: #force_inline proc "contextless" (cp: rune) -> (slot: u32, ok: bool) {
	u := u32(cp)
	if u >= 0x20 && u <= 0x7E {
		return u32(atlas.PINNED_ASCII_BASE + (u - 0x20)), true
	}
	if u >= 0x2500 && u <= 0x257F {
		return u32(atlas.PINNED_BOX_BASE + (u - 0x2500)), true
	}
	if u >= 0x2580 && u <= 0x259F {
		return u32(atlas.PINNED_BLOCK_BASE + (u - 0x2580)), true
	}
	if u >= 0xE0B0 && u <= 0xE0B3 {
		return u32(atlas.PINNED_POWERLINE_BASE + (u - 0xE0B0)), true
	}
	for p_cp, idx in _CHROME_PINNED_UI_RUNES {
		if cp == p_cp {
			return u32(atlas.PINNED_UI_BASE + idx), true
		}
	}
	return 0, false
}

Chrome_Renderer :: struct {
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	width:         u32,
	height:        u32,
	surface:       surface.Chrome_Surface,       // Strategy 1: Cached Surface
	batch:         batch.Chrome_Batch,           // Strategy 2: Dynamic Primitive Batch
	sdf:           sdf.Chrome_Sdf_Pipeline,      // Strategy 3: SDF Vector Shader
	atlas_cell_w:  f32,
	atlas_cell_h:  f32,
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
	r.atlas_cell_w = 19.0
	r.atlas_cell_h = 43.0

	// Strategy 1: Initialize Cached Surface
	if !surface.chrome_surface_init(&r.surface, device, r.width, r.height, format) {
		return false
	}

	// Strategy 2: Initialize Dynamic Primitive Batch
	if !batch.chrome_batch_init(&r.batch, device, queue, batch.CHROME_BATCH_DEFAULT_CAPACITY, context.allocator, format) {
		surface.chrome_surface_destroy(&r.surface)
		return false
	}
	batch.chrome_batch_set_screen_size(&r.batch, f32(r.width), f32(r.height))

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

chrome_renderer_set_atlas :: proc(
	r: ^Chrome_Renderer,
	atlas_view: contract.Gpu_TextureView,
	cell_w: f32 = 19.0,
	cell_h: f32 = 43.0,
) -> bool {
	if r == nil || !r.available do return false
	if cell_w > 0.0 do r.atlas_cell_w = cell_w
	if cell_h > 0.0 do r.atlas_cell_h = cell_h
	return batch.chrome_batch_set_atlas(&r.batch, atlas_view)
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
	batch.chrome_batch_set_screen_size(&r.batch, f32(r.width), f32(r.height))
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

// chrome_renderer_encode encodes UI draw list commands onto a caller-provided CommandEncoder.
chrome_renderer_encode :: proc(
	r: ^Chrome_Renderer,
	encoder: contract.Gpu_CommandEncoder,
	dl: ^draw_list.Ui_Draw_List,
	target: contract.Gpu_TextureView,
	load_op: contract.Gpu_Load_Op = .Clear,
) -> bool {
	if r == nil || !r.available || rawptr(encoder) == nil || dl == nil do return false

	target_view := target
	if rawptr(target_view) == nil {
		target_view = r.surface.view
	}
	if rawptr(target_view) == nil do return false

	r.redraw_count += 1

	clear_col: [4]f64 = {0.0, 0.0, 0.0, 0.0}
	pass := contract.begin_render_pass(encoder, target_view, clear_col, load_op)
	if rawptr(pass) == nil do return false

	screen_sz := [2]f32{f32(r.width), f32(r.height)}
	batch.chrome_batch_set_screen_size(&r.batch, screen_sz[0], screen_sz[1])
	batch.chrome_batch_clear(&r.batch)
	sdf.chrome_sdf_pipeline_reset(&r.sdf)

	// Check if draw list contains any SDF-specific primitives (.Rounded_Rect, .Border, .Shadow).
	// If none exist, flat .Rect commands go directly through Strategy 2 (Chrome_Batch);
	// otherwise .Rect stays in Strategy 3 (SDF) to preserve exact back-to-front painter's order
	// with .Rounded_Rect modals while Strategy 2 batches all foreground .Text_Run / .Icon quads.
	has_sdf_shapes := false
	for cmd in dl.commands {
		if cmd.kind == .Rounded_Rect || cmd.kind == .Border || cmd.kind == .Shadow {
			has_sdf_shapes = true
			break
		}
	}

	cell_w := max(r.atlas_cell_w, 1.0)
	cell_h := max(r.atlas_cell_h, 1.0)
	glyph_aspect := cell_w / cell_h

	for cmd in dl.commands {
		switch cmd.kind {
		case .Rect:
			if !has_sdf_shapes {
				batch.chrome_batch_push_quad(&r.batch, cmd.rect, cmd.color)
			} else {
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
			}

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
			blur_r: f32 = 14.0
			if cmd.border_color[0] > 0.0 {
				blur_r = cmd.border_color[0]
			}
			params := sdf.Sdf_Params{
				screen_size  = screen_sz,
				rect_pos     = {cmd.rect[0], cmd.rect[1]},
				rect_size    = {cmd.rect[2], cmd.rect[3]},
				radius       = cmd.radius,
				border_width = -blur_r,
				color        = cmd.color,
				border_color = cmd.border_color,
			}
			sdf.chrome_sdf_draw(&r.sdf, pass, &params)

		case .Text_Run, .Icon:
			if len(cmd.text) > 0 && cmd.rect[2] > 0.0 && cmd.rect[3] > 0.0 {
				gh := cmd.rect[3]
				gw := max(gh * glyph_aspect, 4.0)
				pen_x := cmd.rect[0]
				max_x := cmd.rect[0] + cmd.rect[2]
				for ch in cmd.text {
					if pen_x + gw > max_x do break
					if ch > ' ' {
						if slot, ok := _chrome_lookup_pinned_slot(ch); ok {
							u0, v0, u1, v1 := atlas.atlas_slot_uv(slot, cell_w, cell_h)
							batch.chrome_batch_push_uv_quad(
								&r.batch,
								{pen_x, cmd.rect[1], gw, gh},
								{u0, v0, u1, v1},
								cmd.color,
							)
						}
					}
					pen_x += gw
				}
			}
		}
	}

	if r.sdf.instance_count > 0 {
		sdf.chrome_sdf_flush_and_draw(&r.sdf, pass)
	}
	if r.batch.active_count > 0 {
		batch.chrome_batch_flush(&r.batch)
		batch.chrome_batch_draw(&r.batch, pass)
	}

	if has_sdf_shapes {
		r.active_strat = 3
	} else {
		r.active_strat = 2
	}

	contract.end_render_pass(pass)
	// Surface is now clean
	surface.chrome_surface_mark_dirty(&r.surface, false)
	return true
}

// chrome_renderer_render executes UI draw list commands using the 3 strategies.
// When r.surface.is_dirty is false (Strategy 1), re-rasterization is skipped entirely.
// When dirty, commands are rendered into target (or cached surface) via Strategy 2 & Strategy 3.
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

	encoder := contract.create_command_encoder(r.device)
	if rawptr(encoder) == nil do return false
	defer contract.release_command_encoder(encoder)

	if !chrome_renderer_encode(r, encoder, dl, target, .Clear) {
		return false
	}

	cmd_buf := contract.finish_command_buffer(encoder)
	if cmd_buf != nil {
		contract.submit(r.queue, cmd_buf)
		contract.release_command_buffer(cmd_buf)
	}
	return true
}

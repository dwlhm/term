package term

// Multi-Layer WGPU Composition Presentation Pass
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import contract "../../core/render/contract"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"

Composer_View :: struct {
	pipe:   pipeline.Composer_Pipeline,
	device: contract.Gpu_Device,
	queue:  contract.Gpu_Queue,
	format: contract.Gpu_Format,
}

composer_view_init :: proc(
	cv: ^Composer_View,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	screen_w, screen_h: f32,
) -> bool {
	if cv == nil do return false
	cv.device = device
	cv.queue = queue
	cv.format = format

	return pipeline.composer_pipeline_init(&cv.pipe, device, queue, format, screen_w, screen_h)
}

composer_view_destroy :: proc(cv: ^Composer_View) {
	if cv == nil do return
	pipeline.composer_pipeline_destroy(&cv.pipe)
}

composer_view_resize :: proc(cv: ^Composer_View, screen_w, screen_h: f32) {
	if cv == nil do return
	pipeline.composer_pipeline_resize(&cv.pipe, screen_w, screen_h)
}

_clear_texture_view :: proc(device: contract.Gpu_Device, queue: contract.Gpu_Queue, view: contract.Gpu_TextureView, col: [4]f64) {
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

composer_view_acquire_layers :: proc(
	cv: ^Composer_View,
	screen_w, screen_h: f32,
) -> (term_layer: ^composer.Composer_Layer, chrome_layer: ^composer.Composer_Layer) {
	if cv == nil do return nil, nil

	w := max(u32(1), u32(screen_w))
	h := max(u32(1), u32(screen_h))

	lt, ok_t := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 101, .Terminal, w, h)
	if ok_t && lt != nil {
		lt.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lt.scissor_rect = lt.dest_rect
		lt.opacity = 1.0
		_clear_texture_view(cv.device, cv.queue, lt.view, {0.05, 0.06, 0.08, 1.0})
		term_layer = lt
	}

	lc, ok_c := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 201, .Chrome, w, h)
	if ok_c && lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.scissor_rect = lc.dest_rect
		lc.opacity = 1.0
		_clear_texture_view(cv.device, cv.queue, lc.view, {0.0, 0.0, 0.0, 0.0})
		chrome_layer = lc
	}

	return term_layer, chrome_layer
}

composer_view_composite_and_present :: proc(
	cv: ^Composer_View,
	surface: rawptr,
	target_view: contract.Gpu_TextureView,
) {
	if cv == nil || surface == nil || rawptr(target_view) == nil do return

	order := [2]composer.Layer_Id{101, 201}
	pipeline.composer_pipeline_set_layer_order(&cv.pipe, order[:])
	pipeline.composer_pipeline_begin_frame(&cv.pipe)

	enc := contract.create_command_encoder(cv.device)
	if rawptr(enc) != nil {
		_ = pipeline.composer_pipeline_composite(&cv.pipe, enc, target_view)
		cmd := contract.finish_command_buffer(enc)
		if rawptr(cmd) != nil {
			contract.submit(cv.queue, cmd)
			contract.release_command_buffer(cmd)
		}
		contract.release_command_encoder(enc)
	}

	contract.present_surface(surface)
	pipeline.composer_pipeline_end_frame(&cv.pipe)
}

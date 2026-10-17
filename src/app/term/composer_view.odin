package term

// Multi-Layer WGPU Composition Presentation Pass
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import contract "../../core/render/contract"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import scheduler "../../core/composer/scheduler"

Composer_View :: struct {
	pipe:     pipeline.Composer_Pipeline,
	sched:    scheduler.Frame_Scheduler,
	device:   contract.Gpu_Device,
	queue:    contract.Gpu_Queue,
	format:   contract.Gpu_Format,
	screen_w: f32,
	screen_h: f32,
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
	cv.screen_w = screen_w
	cv.screen_h = screen_h

	if !pipeline.composer_pipeline_init(&cv.pipe, device, queue, format, screen_w, screen_h) do return false
	scheduler.scheduler_init(&cv.sched)

	w := max(u32(1), u32(screen_w))
	h := max(u32(1), u32(screen_h))

	lt, ok_t := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 101, .Terminal, w, h)
	if ok_t && lt != nil {
		lt.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lt.scissor_rect = lt.dest_rect
		lt.opacity = 1.0
	}

	lc, ok_c := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 201, .Chrome, w, h)
	if ok_c && lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.scissor_rect = lc.dest_rect
		lc.opacity = 1.0
	}

	order := [2]composer.Layer_Id{101, 201}
	pipeline.composer_pipeline_set_layer_order(&cv.pipe, order[:])

	pipeline.composer_pipeline_mark_dirty(&cv.pipe, 101)
	pipeline.composer_pipeline_mark_dirty(&cv.pipe, 201)
	scheduler.scheduler_mark_damage(&cv.sched, 101)
	scheduler.scheduler_mark_damage(&cv.sched, 201)

	return true
}

composer_view_destroy :: proc(cv: ^Composer_View) {
	if cv == nil do return
	pipeline.composer_pipeline_destroy(&cv.pipe)
}

composer_view_resize :: proc(cv: ^Composer_View, screen_w, screen_h: f32) {
	if cv == nil do return
	cv.screen_w = screen_w
	cv.screen_h = screen_h
	pipeline.composer_pipeline_resize(&cv.pipe, screen_w, screen_h)

	w := max(u32(1), u32(screen_w))
	h := max(u32(1), u32(screen_h))

	lt, _ := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 101, .Terminal, w, h)
	if lt != nil {
		lt.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lt.scissor_rect = lt.dest_rect
		lt.opacity = 1.0
	}

	lc, _ := pipeline.composer_pipeline_acquire_layer(&cv.pipe, 201, .Chrome, w, h)
	if lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.scissor_rect = lc.dest_rect
		lc.opacity = 1.0
	}

	pipeline.composer_pipeline_mark_dirty(&cv.pipe, 101)
	pipeline.composer_pipeline_mark_dirty(&cv.pipe, 201)
	scheduler.scheduler_mark_damage(&cv.sched, 101)
	scheduler.scheduler_mark_damage(&cv.sched, 201)
}

composer_view_get_layers :: proc(
	cv: ^Composer_View,
) -> (term_layer: ^composer.Composer_Layer, chrome_layer: ^composer.Composer_Layer) {
	if cv == nil do return nil, nil
	term_layer = pipeline.composer_pipeline_get_layer(&cv.pipe, 101)
	chrome_layer = pipeline.composer_pipeline_get_layer(&cv.pipe, 201)
	return term_layer, chrome_layer
}

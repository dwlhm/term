package term

// Multi-Layer WGPU Composition Presentation Pass
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import contract "../../core/render/contract"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import scheduler "../../core/composer/scheduler"

TERMINAL_LAYER_ID: composer.Layer_Id : 101
CURSOR_LAYER_ID:   composer.Layer_Id : 151
CHROME_LAYER_ID:   composer.Layer_Id : 201

COMPOSER_LAYER_BUCKET :: u32(256)

@(private)
_quantize_layer_cap :: proc(prev_cap, target: u32) -> u32 {
	t := max(u32(1), target)
	rounded := ((t + COMPOSER_LAYER_BUCKET - 1) / COMPOSER_LAYER_BUCKET) * COMPOSER_LAYER_BUCKET
	return max(prev_cap, rounded)
}

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

	w := _quantize_layer_cap(0, u32(screen_w))
	h := _quantize_layer_cap(0, u32(screen_h))

	lt, ok_t := pipeline.composer_pipeline_acquire_layer(&cv.pipe, TERMINAL_LAYER_ID, .Terminal, w, h)
	if ok_t && lt != nil {
		lt.dest_rect = composer.rect_make(0, 0, f32(lt.width), f32(lt.height))
		lt.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lt.opacity = 1.0
	}

	lcur, ok_cur := pipeline.composer_pipeline_acquire_layer(&cv.pipe, CURSOR_LAYER_ID, .Overlay, 16, 16)
	if ok_cur && lcur != nil {
		lcur.dest_rect = composer.rect_make(0, 0, 0, 0)
		lcur.scissor_rect = lcur.dest_rect
		lcur.opacity = 0.0
	}

	lc, ok_c := pipeline.composer_pipeline_acquire_layer(&cv.pipe, CHROME_LAYER_ID, .Chrome, w, h)
	if ok_c && lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, f32(lc.width), f32(lc.height))
		lc.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.opacity = 1.0
	}

	order := [3]composer.Layer_Id{TERMINAL_LAYER_ID, CURSOR_LAYER_ID, CHROME_LAYER_ID}
	pipeline.composer_pipeline_set_layer_order(&cv.pipe, order[:])

	pipeline.composer_pipeline_mark_dirty(&cv.pipe, TERMINAL_LAYER_ID)
	pipeline.composer_pipeline_mark_dirty(&cv.pipe, CURSOR_LAYER_ID)
	pipeline.composer_pipeline_mark_dirty(&cv.pipe, CHROME_LAYER_ID)
	scheduler.scheduler_mark_damage(&cv.sched, TERMINAL_LAYER_ID)
	scheduler.scheduler_mark_damage(&cv.sched, CURSOR_LAYER_ID)
	scheduler.scheduler_mark_damage(&cv.sched, CHROME_LAYER_ID)

	return true
}

composer_view_destroy :: proc(cv: ^Composer_View) {
	if cv == nil do return
	pipeline.composer_pipeline_destroy(&cv.pipe)
}

composer_view_set_clear_color :: proc(cv: ^Composer_View, color: [4]f64) {
	if cv == nil do return
	pipeline.composer_pipeline_set_clear_color(&cv.pipe, color)
}

composer_view_resize :: proc(cv: ^Composer_View, screen_w, screen_h: f32) {
	if cv == nil do return
	cv.screen_w = screen_w
	cv.screen_h = screen_h
	pipeline.composer_pipeline_resize(&cv.pipe, screen_w, screen_h)

	cur_lt := pipeline.composer_pipeline_get_layer(&cv.pipe, TERMINAL_LAYER_ID)
	cur_lc := pipeline.composer_pipeline_get_layer(&cv.pipe, CHROME_LAYER_ID)

	tw := _quantize_layer_cap(cur_lt.width if cur_lt != nil else 0, u32(screen_w))
	th := _quantize_layer_cap(cur_lt.height if cur_lt != nil else 0, u32(screen_h))
	cw := _quantize_layer_cap(cur_lc.width if cur_lc != nil else 0, u32(screen_w))
	ch := _quantize_layer_cap(cur_lc.height if cur_lc != nil else 0, u32(screen_h))

	lt, _ := pipeline.composer_pipeline_acquire_layer(&cv.pipe, TERMINAL_LAYER_ID, .Terminal, tw, th)
	if lt != nil {
		lt.dest_rect = composer.rect_make(0, 0, f32(lt.width), f32(lt.height))
		lt.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lt.opacity = 1.0
	}

	lc, _ := pipeline.composer_pipeline_acquire_layer(&cv.pipe, CHROME_LAYER_ID, .Chrome, cw, ch)
	if lc != nil {
		lc.dest_rect = composer.rect_make(0, 0, f32(lc.width), f32(lc.height))
		lc.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
		lc.opacity = 1.0
	}

	pipeline.composer_pipeline_mark_dirty(&cv.pipe, TERMINAL_LAYER_ID)
	pipeline.composer_pipeline_mark_dirty(&cv.pipe, CHROME_LAYER_ID)
	scheduler.scheduler_mark_damage(&cv.sched, TERMINAL_LAYER_ID)
	scheduler.scheduler_mark_damage(&cv.sched, CHROME_LAYER_ID)
}

composer_view_get_layers :: proc(
	cv: ^Composer_View,
) -> (term_layer: ^composer.Composer_Layer, chrome_layer: ^composer.Composer_Layer) {
	if cv == nil do return nil, nil
	term_layer = pipeline.composer_pipeline_get_layer(&cv.pipe, TERMINAL_LAYER_ID)
	chrome_layer = pipeline.composer_pipeline_get_layer(&cv.pipe, CHROME_LAYER_ID)
	return term_layer, chrome_layer
}

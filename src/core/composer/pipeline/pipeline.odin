package pipeline

// Frame compositor pipeline and orchestration for the OS-Style Layer Compositor Architecture.
// Coordinates backing layers, executes zero-redraw caching, and composites layers back-to-front.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime, contract "../../render/contract",
//    composer "../", layer "../layer", and blit "../blit".
//    No imports of terminal, chrome, ui, platform, or app.
// 2. Zero dynamic heap allocation during steady-state.
// 3. Strict adherence to Odin -strict-style.

import "base:runtime"
import contract "../../render/contract"
import composer "../"
import layer "../layer"
import blit "../blit"

Composer_Frame_Stats :: struct {
	total_layers:       int,
	redrawn_layers:     int, // dirty layers that were re-rendered
	cached_layers:      int, // clean layers that cost 0 rasterization calls
	raster_duration_ns: u64, // time spent rasterizing dirty layers
	blit_duration_ns:   u64, // time spent on compositor blit pass
	total_frame_ns:     u64,
	savings_ratio:      f32, // cached_layers / max(1, total_layers)
}

Composer_Pipeline :: struct {
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	format:        contract.Gpu_Format,
	screen_w:      f32,
	screen_h:      f32,
	clear_color:   [4]f64,
	load_op:       contract.Gpu_Load_Op,
	layer_pool:    layer.Layer_Pool,
	blit_pipeline: blit.Blit_Pipeline,
	layer_order:   [layer.MAX_COMPOSER_LAYERS]composer.Layer_Id,
	layer_count:   int,
	frame_index:   u64,
	stats:         Composer_Frame_Stats,
	available:     bool,
}

// composer_pipeline_init initializes backing layer pool and blit pipeline.
composer_pipeline_init :: proc(
	cp: ^Composer_Pipeline,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	format: contract.Gpu_Format,
	screen_w, screen_h: f32,
) -> bool {
	if cp == nil || rawptr(device) == nil || rawptr(queue) == nil do return false

	cp^ = {}
	cp.device = device
	cp.queue = queue
	cp.format = format
	cp.screen_w = screen_w
	cp.screen_h = screen_h
	cp.clear_color = {0.04, 0.04, 0.06, 1.0}
	cp.load_op = .Clear

	layer.layer_pool_init(&cp.layer_pool, format, .Depth24Plus)

	if !blit.blit_pipeline_init(&cp.blit_pipeline, device, queue, format) {
		return false
	}

	cp.available = true
	return true
}

// composer_pipeline_destroy releases all GPU resources across blit pipeline and layer pool.
composer_pipeline_destroy :: proc(cp: ^Composer_Pipeline) {
	if cp == nil do return

	blit.blit_pipeline_destroy(&cp.blit_pipeline)
	layer.layer_pool_destroy(&cp.layer_pool)

	cp^ = {}
}

// composer_pipeline_resize updates the logical target composition dimensions.
composer_pipeline_resize :: proc(cp: ^Composer_Pipeline, screen_w, screen_h: f32) {
	if cp == nil do return
	cp.screen_w = screen_w
	cp.screen_h = screen_h
}

// composer_pipeline_set_load_op sets the load operation (e.g. .Clear vs .Load) for the composite render pass.
composer_pipeline_set_load_op :: proc(cp: ^Composer_Pipeline, op: contract.Gpu_Load_Op) {
	if cp == nil do return
	cp.load_op = op
}

// composer_pipeline_acquire_layer allocates or reuses a backing layer and ensures its ID is tracked in layer order.
composer_pipeline_acquire_layer :: proc(
	cp: ^Composer_Pipeline,
	id: composer.Layer_Id,
	kind: composer.Layer_Kind,
	width, height: u32,
	need_depth: bool = false,
) -> (^composer.Composer_Layer, bool) {
	if cp == nil || !cp.available || rawptr(cp.device) == nil {
		return nil, false
	}

	layer_ptr, ok := layer.layer_pool_acquire(
		&cp.layer_pool,
		cp.device,
		id,
		kind,
		width,
		height,
		need_depth,
	)
	if !ok || layer_ptr == nil {
		return nil, false
	}

	found := false
	for i in 0..<cp.layer_count {
		if cp.layer_order[i] == id {
			found = true
			break
		}
	}
	if !found && cp.layer_count < layer.MAX_COMPOSER_LAYERS {
		cp.layer_order[cp.layer_count] = id
		cp.layer_count += 1
	}

	return layer_ptr, true
}

// composer_pipeline_release_layer frees backing layer resources and compacts layer order.
composer_pipeline_release_layer :: proc(cp: ^Composer_Pipeline, id: composer.Layer_Id) {
	if cp == nil do return

	layer.layer_pool_release(&cp.layer_pool, id)

	found_idx := -1
	for i in 0..<cp.layer_count {
		if cp.layer_order[i] == id {
			found_idx = i
			break
		}
	}

	if found_idx >= 0 {
		for i in found_idx..<(cp.layer_count - 1) {
			cp.layer_order[i] = cp.layer_order[i + 1]
		}
		cp.layer_order[cp.layer_count - 1] = 0
		cp.layer_count -= 1
	}
}

// composer_pipeline_set_layer_order overrides the back-to-front rendering order.
composer_pipeline_set_layer_order :: proc(cp: ^Composer_Pipeline, order: []composer.Layer_Id) {
	if cp == nil do return

	count := min(len(order), layer.MAX_COMPOSER_LAYERS)
	for i in 0..<count {
		cp.layer_order[i] = order[i]
	}
	for i in count..<layer.MAX_COMPOSER_LAYERS {
		cp.layer_order[i] = 0
	}
	cp.layer_count = count
}

// composer_pipeline_get_layer retrieves an active backing layer by ID.
composer_pipeline_get_layer :: proc(cp: ^Composer_Pipeline, id: composer.Layer_Id) -> ^composer.Composer_Layer {
	if cp == nil do return nil
	return layer.layer_pool_get(&cp.layer_pool, id)
}

// composer_pipeline_mark_dirty flags a layer as needing re-rasterization.
composer_pipeline_mark_dirty :: proc(cp: ^Composer_Pipeline, id: composer.Layer_Id, dirty: bool = true) {
	if cp == nil do return
	layer.layer_pool_mark_dirty(&cp.layer_pool, id, dirty)
}

// composer_pipeline_is_dirty queries whether a layer is currently marked dirty.
composer_pipeline_is_dirty :: proc(cp: ^Composer_Pipeline, id: composer.Layer_Id) -> bool {
	if cp == nil do return false
	return layer.layer_pool_is_dirty(&cp.layer_pool, id)
}

// composer_pipeline_mark_clean resets the dirty flag of a layer after rasterization.
composer_pipeline_mark_clean :: proc(cp: ^Composer_Pipeline, id: composer.Layer_Id) {
	if cp == nil do return
	layer.layer_pool_mark_dirty(&cp.layer_pool, id, false)
}

// composer_pipeline_begin_frame resets stats and computes layer dirty/cached counts and savings ratio.
composer_pipeline_begin_frame :: proc(cp: ^Composer_Pipeline) {
	if cp == nil do return

	cp.stats = {}

	total := 0
	redrawn := 0
	cached := 0

	for i in 0..<cp.layer_count {
		l := layer.layer_pool_get(&cp.layer_pool, cp.layer_order[i])
		if l != nil && l.in_use {
			total += 1
			if l.is_dirty {
				redrawn += 1
			} else {
				cached += 1
			}
		}
	}

	cp.stats.total_layers = total
	cp.stats.redrawn_layers = redrawn
	cp.stats.cached_layers = cached
	cp.stats.savings_ratio = f32(cached) / f32(max(total, 1))
}

// composer_pipeline_should_render returns true if any backing layer was redrawn this frame,
// enabling zero-work frame skipping on idle frames.
// true iff raster work exists this frame; NOT a composite/present gate — transitions move clean layers without raster.
composer_pipeline_should_render :: proc(cp: ^Composer_Pipeline) -> bool {
	return cp != nil && cp.stats.redrawn_layers > 0
}

// composer_pipeline_composite binds and blits active layers back-to-front into target_view render pass.
composer_pipeline_composite :: proc(
	cp: ^Composer_Pipeline,
	enc: contract.Gpu_CommandEncoder,
	target_view: contract.Gpu_TextureView,
) -> bool {
	if cp == nil || !cp.available || rawptr(enc) == nil || rawptr(target_view) == nil {
		return false
	}
	if contract.begin_render_pass == nil || contract.end_render_pass == nil {
		return false
	}

	load_op := cp.load_op if cp.load_op != .Undefined else .Clear
	pass := contract.begin_render_pass(enc, target_view, cp.clear_color, load_op)
	if rawptr(pass) == nil {
		return false
	}

	// Bind quad blit pipeline once for all layer draws
	contract.render_set_pipeline(pass, cp.blit_pipeline.pipeline)

	for i in 0..<cp.layer_count {
		id := cp.layer_order[i]
		l := layer.layer_pool_get(&cp.layer_pool, id)
		if l != nil && l.in_use && rawptr(l.view) != nil {
			slot_idx := l.slot_index
			if slot_idx >= 0 && slot_idx < layer.MAX_COMPOSER_LAYERS {
				blit.blit_layer(&cp.blit_pipeline, pass, slot_idx, l, cp.screen_w, cp.screen_h)
			}
		}
	}

	contract.end_render_pass(pass)
	return true
}

// composer_pipeline_end_frame finalizes frame presentation state.
composer_pipeline_end_frame :: proc(cp: ^Composer_Pipeline) {
	if cp == nil do return
	cp.frame_index += 1
}

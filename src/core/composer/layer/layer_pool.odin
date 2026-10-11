package layer

// Bounded backing surface pool for the OS-Style Layer Compositor Architecture.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime, contract "../../render/contract", and composer "../".
//    No imports of terminal, chrome, ui, platform, or app.
// 2. Zero dynamic heap allocation during steady-state.
// 3. Strict adherence to Odin -strict-style.

import "base:runtime"
import contract "../../render/contract"
import composer "../"

MAX_COMPOSER_LAYERS :: 16

Layer_Pool :: struct {
	layers:       [MAX_COMPOSER_LAYERS]composer.Composer_Layer,
	color_format: contract.Gpu_Format,
	depth_format: contract.Gpu_Format,
	count:        int,
}

// layer_pool_init initializes pool state and pixel formats.
layer_pool_init :: proc(pool: ^Layer_Pool, color_format: contract.Gpu_Format, depth_format: contract.Gpu_Format = .Depth24Plus) {
	if pool == nil do return
	pool.layers = {}
	pool.color_format = color_format
	pool.depth_format = depth_format
	pool.count = 0
}

// layer_pool_destroy releases all GPU texture allocations across pool slots.
layer_pool_destroy :: proc(pool: ^Layer_Pool) {
	if pool == nil do return

	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		_destroy_layer_gpu_resources(layer)
		layer^ = {}
	}
	pool.count = 0
}

// layer_pool_acquire acquires or updates a backing layer texture and depth view.
// If an existing layer with the same id exists, it is reused. If dimensions or depth requirements change,
// old resources are safely destroyed and reallocated with matching size.
// Otherwise, an unused slot is allocated.
layer_pool_acquire :: proc(
	pool: ^Layer_Pool,
	device: contract.Gpu_Device,
	id: composer.Layer_Id,
	kind: composer.Layer_Kind,
	width, height: u32,
	need_depth: bool = false,
) -> (^composer.Composer_Layer, bool) {
	if pool == nil || rawptr(device) == nil do return nil, false

	w := max(width, 1)
	h := max(height, 1)

	// Reuse existing layer if id matches
	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if layer.in_use && layer.id == id {
			if layer.width == w && layer.height == h && layer.has_depth == need_depth && rawptr(layer.texture) != nil {
				layer.kind = kind
				layer.slot_index = i
				return layer, true
			}

			// Dimensions or depth requirement changed: reallocate GPU resources
			_destroy_layer_gpu_resources(layer)
			if !_allocate_layer_gpu_resources(layer, device, w, h, pool.color_format, pool.depth_format, need_depth) {
				layer^ = {}
				pool.count -= 1
				if pool.count < 0 do pool.count = 0
				return nil, false
			}

			layer.kind = kind
			layer.slot_index = i
			layer.dest_rect = composer.rect_make(layer.dest_rect.x, layer.dest_rect.y, f32(w), f32(h))
			layer.scissor_rect = composer.rect_make(layer.scissor_rect.x, layer.scissor_rect.y, f32(w), f32(h))
			layer.is_dirty = true
			layer.version += 1
			return layer, true
		}
	}

	// For new layer, find unused slot
	free_slot: ^composer.Composer_Layer = nil
	slot_idx: int = -1
	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if !layer.in_use {
			free_slot = layer
			slot_idx = i
			break
		}
	}

	if free_slot == nil {
		return nil, false
	}

	_destroy_layer_gpu_resources(free_slot)
	free_slot^ = {}

	if !_allocate_layer_gpu_resources(free_slot, device, w, h, pool.color_format, pool.depth_format, need_depth) {
		return nil, false
	}

	free_slot.id = id
	free_slot.slot_index = slot_idx
	free_slot.kind = kind
	free_slot.dest_rect = composer.rect_make(0, 0, f32(w), f32(h))
	free_slot.scissor_rect = composer.rect_make(0, 0, f32(w), f32(h))
	free_slot.is_dirty = true
	free_slot.opacity = 1.0
	free_slot.corner_radius = 0.0
	free_slot.last_frame = 0
	free_slot.version = 1
	free_slot.in_use = true

	pool.count += 1
	return free_slot, true
}

// layer_pool_release frees resources for a specific layer and marks its slot unused.
layer_pool_release :: proc(pool: ^Layer_Pool, id: composer.Layer_Id) {
	if pool == nil do return

	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if layer.in_use && layer.id == id {
			_destroy_layer_gpu_resources(layer)
			layer^ = {}
			pool.count -= 1
			if pool.count < 0 do pool.count = 0
			return
		}
	}
}

// layer_pool_mark_dirty sets the dirty flag for an active layer.
layer_pool_mark_dirty :: proc(pool: ^Layer_Pool, id: composer.Layer_Id, dirty: bool = true) {
	if pool == nil do return

	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if layer.in_use && layer.id == id {
			layer.is_dirty = dirty
			return
		}
	}
}

// layer_pool_is_dirty queries the dirty state of an active layer.
layer_pool_is_dirty :: proc(pool: ^Layer_Pool, id: composer.Layer_Id) -> bool {
	if pool == nil do return false

	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if layer.in_use && layer.id == id {
			return layer.is_dirty
		}
	}
	return false
}

// layer_pool_get retrieves an active layer pointer by id.
layer_pool_get :: proc(pool: ^Layer_Pool, id: composer.Layer_Id) -> ^composer.Composer_Layer {
	if pool == nil do return nil

	for i in 0..<MAX_COMPOSER_LAYERS {
		layer := &pool.layers[i]
		if layer.in_use && layer.id == id {
			return layer
		}
	}
	return nil
}

// layer_pool_active_count returns the number of currently active layers in the pool.
layer_pool_active_count :: proc(pool: ^Layer_Pool) -> int {
	if pool == nil do return 0
	return pool.count
}

// ============================================================================
// Private Internal Helpers
// ============================================================================

@(private = "file")
_destroy_layer_gpu_resources :: proc(layer: ^composer.Composer_Layer) {
	if layer == nil do return

	if contract.destroy_texture_view != nil && rawptr(layer.depth_view) != nil {
		contract.destroy_texture_view(layer.depth_view)
	}
	layer.depth_view = contract.Gpu_TextureView(nil)

	if contract.destroy_texture != nil && rawptr(layer.depth_texture) != nil {
		contract.destroy_texture(layer.depth_texture)
	}
	layer.depth_texture = contract.Gpu_Texture(nil)

	if contract.destroy_texture_view != nil && rawptr(layer.view) != nil {
		contract.destroy_texture_view(layer.view)
	}
	layer.view = contract.Gpu_TextureView(nil)

	if contract.destroy_texture != nil && rawptr(layer.texture) != nil {
		contract.destroy_texture(layer.texture)
	}
	layer.texture = contract.Gpu_Texture(nil)

	layer.has_depth = false
}

@(private = "file")
_allocate_layer_gpu_resources :: proc(
	layer: ^composer.Composer_Layer,
	device: contract.Gpu_Device,
	width, height: u32,
	color_format, depth_format: contract.Gpu_Format,
	need_depth: bool,
) -> bool {
	if layer == nil || rawptr(device) == nil do return false
	if contract.create_texture == nil || contract.create_texture_view == nil do return false

	color_usage := contract.Gpu_Texture_Usage.Render_Attach |
	               contract.Gpu_Texture_Usage.Texture_Binding |
	               contract.Gpu_Texture_Usage.Copy_Src |
	               contract.Gpu_Texture_Usage.Copy_Dst

	color_tex := contract.create_texture(device, width, height, color_format, color_usage)
	if rawptr(color_tex) == nil do return false

	color_view := contract.create_texture_view(color_tex)
	if rawptr(color_view) == nil {
		if contract.destroy_texture != nil do contract.destroy_texture(color_tex)
		return false
	}

	depth_tex: contract.Gpu_Texture = nil
	depth_view: contract.Gpu_TextureView = nil

	if need_depth {
		depth_usage := contract.Gpu_Texture_Usage.Render_Attach
		depth_tex = contract.create_texture(device, width, height, depth_format, depth_usage)
		if rawptr(depth_tex) == nil {
			if contract.destroy_texture_view != nil do contract.destroy_texture_view(color_view)
			if contract.destroy_texture != nil do contract.destroy_texture(color_tex)
			return false
		}

		depth_view = contract.create_texture_view(depth_tex)
		if rawptr(depth_view) == nil {
			if contract.destroy_texture != nil do contract.destroy_texture(depth_tex)
			if contract.destroy_texture_view != nil do contract.destroy_texture_view(color_view)
			if contract.destroy_texture != nil do contract.destroy_texture(color_tex)
			return false
		}
	}

	layer.texture = color_tex
	layer.view = color_view
	layer.depth_texture = depth_tex
	layer.depth_view = depth_view
	layer.has_depth = need_depth
	layer.width = width
	layer.height = height

	return true
}

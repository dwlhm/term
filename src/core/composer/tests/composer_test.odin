package composer_tests

// OS-Style Layer Compositor automated unit test suite.
// Verifies geometry primitives, pool bounds, dirty tracking, version ABA busting,
// layer order compaction, and frame statistics caching efficiency.

import "core:testing"

import composer "../"
import layer "../layer"
import pipeline "../pipeline"
import contract "../../render/contract"

@(private = "file")
_mock_tex_id: uintptr = 0x1000
@(private = "file")
_mock_view_id: uintptr = 0x2000

@(private = "file")
_mock_create_texture :: proc(
	device: contract.Gpu_Device,
	width, height: u32,
	format: contract.Gpu_Format,
	usage: contract.Gpu_Texture_Usage,
) -> contract.Gpu_Texture {
	_mock_tex_id += 1
	return contract.Gpu_Texture(rawptr(_mock_tex_id))
}

@(private = "file")
_mock_create_texture_view :: proc(texture: contract.Gpu_Texture) -> contract.Gpu_TextureView {
	_mock_view_id += 1
	return contract.Gpu_TextureView(rawptr(_mock_view_id))
}

@(private = "file")
_mock_destroy_texture :: proc(texture: contract.Gpu_Texture) {}

@(private = "file")
_mock_destroy_texture_view :: proc(view: contract.Gpu_TextureView) {}

@(private = "file")
_init_mock_driver :: proc() {
	contract.create_texture       = _mock_create_texture
	contract.create_texture_view  = _mock_create_texture_view
	contract.destroy_texture      = _mock_destroy_texture
	contract.destroy_texture_view = _mock_destroy_texture_view
}

@(private = "file")
_MOCK_DEVICE: contract.Gpu_Device = contract.Gpu_Device(rawptr(uintptr(0x8000)))

@test
test_rect_contains :: proc(t: ^testing.T) {
	r := composer.rect_make(10.0, 20.0, 100.0, 50.0)

	// Inside
	testing.expect(t, composer.rect_contains(r, 10.0, 20.0), "Top-left boundary must be contained")
	testing.expect(t, composer.rect_contains(r, 50.0, 40.0), "Interior point must be contained")
	testing.expect(t, composer.rect_contains(r, 109.9, 69.9), "Point just inside right/bottom must be contained")

	// Half-open boundary: right (x + w = 110) and bottom (y + h = 70) must NOT be contained
	testing.expect(t, !composer.rect_contains(r, 110.0, 40.0), "Right edge x+w must not be contained [half-open)")
	testing.expect(t, !composer.rect_contains(r, 50.0, 70.0), "Bottom edge y+h must not be contained [half-open)")
	testing.expect(t, !composer.rect_contains(r, 110.0, 70.0), "Bottom-right vertex must not be contained [half-open)")

	// Outside
	testing.expect(t, !composer.rect_contains(r, 9.9, 20.0), "Left of rect must not be contained")
	testing.expect(t, !composer.rect_contains(r, 10.0, 19.9), "Above rect must not be contained")
	testing.expect(t, !composer.rect_contains(r, 150.0, 100.0), "Far outside point must not be contained")
}

@test
test_layer_pool_capacity :: proc(t: ^testing.T) {
	_init_mock_driver()
	pool: layer.Layer_Pool
	layer.layer_pool_init(&pool, .BGRA8_Unorm, .Depth24Plus)

	// Acquire up to MAX_COMPOSER_LAYERS (16)
	for i in 1..=16 {
		l, ok := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(i), .Terminal, 100, 100)
		testing.expect(t, ok, "Acquisition of layer within limit must succeed")
		testing.expect(t, l != nil, "Returned layer pointer must not be nil")
	}
	testing.expect_value(t, layer.layer_pool_active_count(&pool), 16)

	// 17th acquisition must fail gracefully
	l_overflow, ok_overflow := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(17), .Terminal, 100, 100)
	testing.expect(t, !ok_overflow, "Acquiring 17th layer must fail")
	testing.expect(t, l_overflow == nil, "Overflow acquisition must return nil")
	testing.expect_value(t, layer.layer_pool_active_count(&pool), 16)

	// Release one slot and re-acquire
	layer.layer_pool_release(&pool, composer.Layer_Id(5))
	testing.expect_value(t, layer.layer_pool_active_count(&pool), 15)

	l_retry, ok_retry := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(17), .Terminal, 100, 100)
	testing.expect(t, ok_retry, "Acquisition into freed slot must succeed")
	testing.expect(t, l_retry != nil, "Re-acquired layer pointer must not be nil")
	testing.expect_value(t, layer.layer_pool_active_count(&pool), 16)

	layer.layer_pool_destroy(&pool)
	testing.expect_value(t, layer.layer_pool_active_count(&pool), 0)
}

@test
test_layer_pool_dirty_tracking :: proc(t: ^testing.T) {
	_init_mock_driver()
	pool: layer.Layer_Pool
	layer.layer_pool_init(&pool, .BGRA8_Unorm, .Depth24Plus)

	l, ok := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(1), .Terminal, 100, 100)
	testing.expect(t, ok && l != nil, "Layer acquire must succeed")

	// New layer starts dirty
	testing.expect(t, layer.layer_pool_is_dirty(&pool, composer.Layer_Id(1)), "New layer must be dirty")

	// Mark clean
	layer.layer_pool_mark_dirty(&pool, composer.Layer_Id(1), false)
	testing.expect(t, !layer.layer_pool_is_dirty(&pool, composer.Layer_Id(1)), "Layer must report clean")

	// Mark dirty again
	layer.layer_pool_mark_dirty(&pool, composer.Layer_Id(1), true)
	testing.expect(t, layer.layer_pool_is_dirty(&pool, composer.Layer_Id(1)), "Layer must report dirty")

	// Non-existent layer
	testing.expect(t, !layer.layer_pool_is_dirty(&pool, composer.Layer_Id(999)), "Unknown layer must not report dirty")

	layer.layer_pool_destroy(&pool)
}

@test
test_layer_pool_reuse_and_version :: proc(t: ^testing.T) {
	_init_mock_driver()
	pool: layer.Layer_Pool
	layer.layer_pool_init(&pool, .BGRA8_Unorm, .Depth24Plus)

	// Brand new slot sets version = 1
	l1, ok1 := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(1), .Terminal, 100, 100)
	testing.expect(t, ok1 && l1 != nil, "Layer acquire must succeed")
	testing.expect_value(t, l1.version, u32(1))

	// Reusing identical geometry keeps version = 1
	l2, ok2 := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(1), .Terminal, 100, 100)
	testing.expect(t, ok2 && l2 == l1, "Same ID and size must reuse identical slot pointer")
	testing.expect_value(t, l2.version, u32(1))

	// Reallocating due to geometry change increments version to 2
	l3, ok3 := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(1), .Terminal, 200, 150)
	testing.expect(t, ok3 && l3 == l1, "Resized layer must reuse slot pointer")
	testing.expect_value(t, l3.version, u32(2))
	testing.expect_value(t, l3.width, u32(200))
	testing.expect_value(t, l3.height, u32(150))

	// Reallocating due to depth requirement increments version to 3
	l4, ok4 := layer.layer_pool_acquire(&pool, _MOCK_DEVICE, composer.Layer_Id(1), .Three_D, 200, 150, true)
	testing.expect(t, ok4 && l4 == l1, "Depth-changed layer must reuse slot pointer")
	testing.expect_value(t, l4.version, u32(3))
	testing.expect(t, l4.has_depth, "Layer must have depth enabled")

	layer.layer_pool_destroy(&pool)
}

@test
test_pipeline_layer_order_compaction :: proc(t: ^testing.T) {
	_init_mock_driver()
	cp: pipeline.Composer_Pipeline
	cp.device = _MOCK_DEVICE
	cp.available = true
	layer.layer_pool_init(&cp.layer_pool, .BGRA8_Unorm, .Depth24Plus)

	// Acquire 3 layers
	_, ok1 := pipeline.composer_pipeline_acquire_layer(&cp, composer.Layer_Id(10), .Terminal, 100, 100)
	_, ok2 := pipeline.composer_pipeline_acquire_layer(&cp, composer.Layer_Id(20), .Terminal, 100, 100)
	_, ok3 := pipeline.composer_pipeline_acquire_layer(&cp, composer.Layer_Id(30), .Terminal, 100, 100)
	testing.expect(t, ok1 && ok2 && ok3, "Acquiring layers must succeed")

	testing.expect_value(t, cp.layer_count, 3)
	testing.expect_value(t, cp.layer_order[0], composer.Layer_Id(10))
	testing.expect_value(t, cp.layer_order[1], composer.Layer_Id(20))
	testing.expect_value(t, cp.layer_order[2], composer.Layer_Id(30))

	// Release middle layer 20: order must compact 30 down into index 1
	pipeline.composer_pipeline_release_layer(&cp, composer.Layer_Id(20))
	testing.expect_value(t, cp.layer_count, 2)
	testing.expect_value(t, cp.layer_order[0], composer.Layer_Id(10))
	testing.expect_value(t, cp.layer_order[1], composer.Layer_Id(30))
	testing.expect_value(t, cp.layer_order[2], composer.Layer_Id(0))
	testing.expect(t, pipeline.composer_pipeline_get_layer(&cp, composer.Layer_Id(20)) == nil, "Released layer must be absent from pool")

	// Release head layer 10: 30 shifts to index 0
	pipeline.composer_pipeline_release_layer(&cp, composer.Layer_Id(10))
	testing.expect_value(t, cp.layer_count, 1)
	testing.expect_value(t, cp.layer_order[0], composer.Layer_Id(30))
	testing.expect_value(t, cp.layer_order[1], composer.Layer_Id(0))

	// Release tail layer 30: count becomes 0
	pipeline.composer_pipeline_release_layer(&cp, composer.Layer_Id(30))
	testing.expect_value(t, cp.layer_count, 0)
	testing.expect_value(t, cp.layer_order[0], composer.Layer_Id(0))

	// Releasing absent layer is safe no-op
	pipeline.composer_pipeline_release_layer(&cp, composer.Layer_Id(999))
	testing.expect_value(t, cp.layer_count, 0)

	layer.layer_pool_destroy(&cp.layer_pool)
}

@test
test_pipeline_stats :: proc(t: ^testing.T) {
	_init_mock_driver()
	cp: pipeline.Composer_Pipeline
	cp.device = _MOCK_DEVICE
	cp.available = true
	layer.layer_pool_init(&cp.layer_pool, .BGRA8_Unorm, .Depth24Plus)

	// Zero layer base case
	pipeline.composer_pipeline_begin_frame(&cp)
	testing.expect_value(t, cp.stats.total_layers, 0)
	testing.expect_value(t, cp.stats.redrawn_layers, 0)
	testing.expect_value(t, cp.stats.cached_layers, 0)
	testing.expect_value(t, cp.stats.savings_ratio, f32(0.0))

	// Acquire 4 layers (Panes 1..4)
	for i in 1..=4 {
		_, ok := pipeline.composer_pipeline_acquire_layer(&cp, composer.Layer_Id(i), .Terminal, 100, 100)
		testing.expect(t, ok, "Acquiring layer must succeed")
	}

	// Case 1: All 4 dirty
	pipeline.composer_pipeline_begin_frame(&cp)
	testing.expect_value(t, cp.stats.total_layers, 4)
	testing.expect_value(t, cp.stats.redrawn_layers, 4)
	testing.expect_value(t, cp.stats.cached_layers, 0)
	testing.expect_value(t, cp.stats.savings_ratio, f32(0.0))

	// Case 2: Only Pane 1 dirty, Panes 2, 3, 4 clean (75% savings)
	pipeline.composer_pipeline_mark_clean(&cp, composer.Layer_Id(2))
	pipeline.composer_pipeline_mark_clean(&cp, composer.Layer_Id(3))
	pipeline.composer_pipeline_mark_clean(&cp, composer.Layer_Id(4))
	pipeline.composer_pipeline_begin_frame(&cp)
	testing.expect_value(t, cp.stats.total_layers, 4)
	testing.expect_value(t, cp.stats.redrawn_layers, 1)
	testing.expect_value(t, cp.stats.cached_layers, 3)
	testing.expect_value(t, cp.stats.savings_ratio, f32(0.75))

	// Case 3: All 4 clean (Idle, 100% savings)
	pipeline.composer_pipeline_mark_clean(&cp, composer.Layer_Id(1))
	pipeline.composer_pipeline_begin_frame(&cp)
	testing.expect_value(t, cp.stats.total_layers, 4)
	testing.expect_value(t, cp.stats.redrawn_layers, 0)
	testing.expect_value(t, cp.stats.cached_layers, 4)
	testing.expect_value(t, cp.stats.savings_ratio, f32(1.0))

	layer.layer_pool_destroy(&cp.layer_pool)
}

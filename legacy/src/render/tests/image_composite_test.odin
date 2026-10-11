package render_tests

import "core:testing"
import graphics "../../graphics"
import instance "../instance"
import render ".."
import interaction "../../interaction"
import gpu "../gpu"
import termgrid "../../terminal"

@(test)
test_image_cache_key_keeps_namespace_and_generation_distinct :: proc(t: ^testing.T) {
	base := render.Image_Texture_Key{graphics_namespace = 7, image_id = 11, generation = 13}
	different_namespace := base
	different_namespace.graphics_namespace += 1
	different_generation := base
	different_generation.generation += 1
	testing.expect(t, base != different_namespace, "cache keys must separate terminal namespaces")
	testing.expect(t, base != different_generation, "cache keys must separate image generations")
}

_image_stage_test_texture := rawptr(uintptr(0x2011))
_image_stage_test_view := rawptr(uintptr(0x2012))
_image_stage_test_bind_group := rawptr(uintptr(0x2013))

_image_stage_test_create_texture :: proc(device: gpu.Gpu_Device, width, height: u32, format: gpu.Gpu_Format, usage: gpu.Gpu_Texture_Usage) -> gpu.Gpu_Texture {
	return gpu.Gpu_Texture(_image_stage_test_texture)
}

_image_stage_test_destroy_texture :: proc(texture: gpu.Gpu_Texture) {}

_image_stage_test_create_texture_view :: proc(texture: gpu.Gpu_Texture) -> gpu.Gpu_TextureView {
	return gpu.Gpu_TextureView(_image_stage_test_view)
}

_image_stage_test_destroy_texture_view :: proc(view: gpu.Gpu_TextureView) {}

_image_stage_test_write_texture :: proc(queue: gpu.Gpu_Queue, texture: gpu.Gpu_Texture, data: []u8, width, height: u32) {}

_image_stage_test_create_bind_group :: proc(device: gpu.Gpu_Device, layout: gpu.Gpu_BindGroupLayout, entries: []gpu.Gpu_Bind_Entry) -> gpu.Gpu_BindGroup {
	return gpu.Gpu_BindGroup(_image_stage_test_bind_group)
}

_image_stage_test_destroy_bind_group :: proc(group: gpu.Gpu_BindGroup) {}

_image_stage_test_create_sampler :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_Sampler {
	return gpu.Gpu_Sampler(rawptr(uintptr(0x2016)))
}

@(test)
test_image_staging_traverses_placements_beyond_128 :: proc(t: ^testing.T) {
	PLACEMENT_TEST_COUNT :: 200
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, PLACEMENT_TEST_COUNT)
	defer termgrid.terminal_destroy(&term)
	term.graphics_namespace = 1
	store := termgrid.terminal_graphics_active(&term)
	store.images[0] = graphics.Image_Slot{
		used = true, id = 1, number = 1, generation = 1,
		frame_count = 1, current_frame = 0,
	}
	frame_data, frame_alloc_err := make([]u8, 4, context.allocator)
	if !testing.expect(t, frame_alloc_err == nil, "image frame fixture allocation must succeed") do return
	frame_data[0] = 255
	frame_data[1] = 255
	frame_data[2] = 255
	frame_data[3] = 255
	store.images[0].frames[0] = graphics.Frame{width = 1, height = 1, data = frame_data, allocator = context.allocator}
	placements, alloc_err := make([]graphics.Placement, PLACEMENT_TEST_COUNT, context.allocator)
	if !testing.expect(t, alloc_err == nil, "placement fixture allocation must succeed") do return
	store.placements = placements
	store.placement_allocator = context.allocator
	store.placement_allocator_set = true
	store.placement_count = PLACEMENT_TEST_COUNT
	for i in 0..<PLACEMENT_TEST_COUNT {
		store.placements[i] = graphics.Placement{
			used = true, image_id = 1, image_number = 1, placement_id = u32(i+1),
			col = i, cols = 1, rows = 1, src_w = 1, src_h = 1,
		}
	}

	backend := gpu.Gpu_Backend_VTable{
		create_texture = _image_stage_test_create_texture,
		destroy_texture = _image_stage_test_destroy_texture,
		create_texture_view = _image_stage_test_create_texture_view,
		destroy_texture_view = _image_stage_test_destroy_texture_view,
		write_texture = _image_stage_test_write_texture,
		create_bind_group = _image_stage_test_create_bind_group,
		destroy_bind_group = _image_stage_test_destroy_bind_group,
		create_sampler = _image_stage_test_create_sampler,
	}
	renderer := render.Renderer{
		backend = &backend,
		image_bind_group_layout = gpu.Gpu_BindGroupLayout(rawptr(uintptr(0x2014))),
		image_staging_allocator = context.allocator,
		cell_width = 1, cell_height = 1,
	}
	renderer.instances.uniform_buffer = gpu.Gpu_Buffer(rawptr(uintptr(0x2015)))
	renderer.instances.sampler = gpu.Gpu_Sampler(rawptr(uintptr(0x2016)))
	defer {
		render._image_texture_cache_destroy(&renderer)
		if renderer.image_instances != nil { delete(renderer.image_instances, renderer.image_staging_allocator) }
		if renderer.image_draws != nil { delete(renderer.image_draws, renderer.image_staging_allocator) }
	}
	pane := render.Pane_Viewport{terminal = &term, w = f32(PLACEMENT_TEST_COUNT), h = 1, cols = PLACEMENT_TEST_COUNT, rows = 1, dim_factor = 1}
	if !testing.expect(t, render._renderer_stage_images_for_pane(&renderer, &pane), "renderer must stage the full placement set") do return
	testing.expect_value(t, renderer.image_count, u32(PLACEMENT_TEST_COUNT))
	testing.expect_value(t, renderer.image_draws[PLACEMENT_TEST_COUNT-1].placement_id, u32(PLACEMENT_TEST_COUNT))
}

@(test)
test_image_staging_grows_for_every_placement :: proc(t: ^testing.T) {
	PLACEMENT_TEST_COUNT :: 200
	placements, alloc_err := make([]graphics.Placement, PLACEMENT_TEST_COUNT, context.allocator)
	if !testing.expect(t, alloc_err == nil, "placement fixture allocation must succeed") do return
	defer delete(placements, context.allocator)
	for i in 0..<PLACEMENT_TEST_COUNT {
		placements[i] = graphics.Placement{used = true, placement_id = u32(i+1), src_x = u32(i), src_w = 1, src_h = 1}
	}

	renderer := render.Renderer{image_staging_allocator = context.allocator}
	defer {
		if renderer.image_instances != nil { delete(renderer.image_instances, renderer.image_staging_allocator) }
		if renderer.image_draws != nil { delete(renderer.image_draws, renderer.image_staging_allocator) }
	}
	if !testing.expect(t, render._renderer_grow_image_staging(&renderer, len(placements)), "image staging must grow to fit the complete placement set") do return
	for i in 0..<len(placements) {
		renderer.image_instances[i] = instance.Instance_Data{u0 = f32(placements[i].src_x)}
		renderer.image_draws[i] = render.Image_Draw{used = true, placement_id = placements[i].placement_id}
	}
	renderer.image_count = u32(len(placements))
	testing.expect_value(t, renderer.image_count, u32(PLACEMENT_TEST_COUNT))
	testing.expect_value(t, renderer.image_draws[PLACEMENT_TEST_COUNT-1].placement_id, u32(PLACEMENT_TEST_COUNT))
	testing.expect_value(t, renderer.image_instances[PLACEMENT_TEST_COUNT-1].u0, f32(PLACEMENT_TEST_COUNT-1))
}

@(test)
test_image_placement_z_partition_and_order :: proc(t: ^testing.T) {
	draws := [3]render.Image_Draw{
		{used = true, z = 2, image_id = 4, placement_id = 8},
		{used = true, z = -1, image_id = 9, placement_id = 3},
		{used = true, z = 2, image_id = 2, placement_id = 7},
	}
	for i in 1..<len(draws) {
		value := draws[i]
		j := i
		for j > 0 && render._image_draw_precedes(value, draws[j-1]) {
			draws[j] = draws[j-1]
			j -= 1
		}
		draws[j] = value
	}
	testing.expect_value(t, draws[0].z, i32(-1))
	testing.expect_value(t, draws[1].image_id, u32(2))
	testing.expect_value(t, draws[2].image_id, u32(4))
}

@(test)
test_image_destination_crop_and_aspect_math :: proc(t: ^testing.T) {
	placement := graphics.Placement{
		used = true, col = 2, row = 3, cell_x = 1, cell_y = 2,
		cols = 4, rows = 0, src_x = 10, src_y = 5, src_w = 100, src_h = 50,
	}
	rect, ok := render._image_placement_rect(&placement, 10, 10, 200, 100)
	testing.expect(t, ok, "valid placement must produce a destination rectangle")
	testing.expect_value(t, rect, [4]f32{21, 32, 40, 20})
	uv, uv_ok := render._image_placement_uv(&placement, 200, 100)
	testing.expect(t, uv_ok, "valid crop must produce normalized coordinates")
	testing.expect_value(t, uv, [4]f32{0.05, 0.05, 0.55, 0.55})
}

@(test)
test_image_focus_rect_is_aspect_correct_and_clamped :: proc(t: ^testing.T) {
	s := interaction.Image_Focus_State{active = true, zoom = interaction.IMAGE_FOCUS_MAX_ZOOM, pan_x = 1000000, pan_y = -1000000}
	interaction.image_focus_clamp_for_view(&s, 800, 600, 400, 200)
	rect, ok := interaction.image_focus_rect(s, 800, 600, 400, 200)
	testing.expect(t, ok, "focused image rect must be produced for valid dimensions")
	testing.expect_value(t, rect[2] / rect[3], f32(2))
	testing.expect(t, rect[0] <= 800 && rect[0] + rect[2] >= 0, "horizontal pan must remain clip-reachable")
	testing.expect(t, rect[1] <= 600 && rect[1] + rect[3] >= 0, "vertical pan must remain clip-reachable")
}

@(test)
test_image_invalid_placement_is_noop :: proc(t: ^testing.T) {
	invalid := graphics.Placement{used = true, src_w = 0, src_h = 10, cols = 1, rows = 1}
	_, rect_ok := render._image_placement_rect(&invalid, 8, 16, 32, 32)
	_, uv_ok := render._image_placement_uv(&invalid, 32, 32)
	testing.expect(t, !rect_ok && !uv_ok, "zero source dimensions must be ignored")

	out_of_bounds := invalid
	out_of_bounds.src_w = 4
	out_of_bounds.src_x = 32
	_, out_ok := render._image_placement_uv(&out_of_bounds, 32, 32)
	testing.expect(t, !out_ok, "out-of-bounds crops must be ignored")
}

@(test)
test_image_clip_intersection_crops_uv :: proc(t: ^testing.T) {
	quad := instance.Instance_Data{x = 0, y = 4, cw = 40, ch = 20, u0 = 0, v0 = 0, u1 = 1, v1 = 1}
	testing.expect(t, render._clip_instance_rect(&quad, {10, 10, 30, 20}, true), "intersecting clip must retain the image")
	testing.expect_value(t, quad.x, f32(10))
	testing.expect_value(t, quad.y, f32(10))
	testing.expect_value(t, quad.cw, f32(20))
	testing.expect_value(t, quad.ch, f32(10))
	testing.expect(t, quad.u0 > 0.2 && quad.v0 > 0.2 && quad.u1 < 0.8 && quad.v1 <= 0.8, "clipping must preserve the corresponding crop")

	outside := instance.Instance_Data{x = 0, y = 0, cw = 4, ch = 4}
	testing.expect(t, !render._clip_instance_rect(&outside, {5, 5, 8, 8}, true), "disjoint clip must be a no-op")
}

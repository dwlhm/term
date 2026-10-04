package render_tests

import "core:testing"
import graphics "../../graphics"
import instance "../instance"
import render ".."
import interaction "../../interaction"

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

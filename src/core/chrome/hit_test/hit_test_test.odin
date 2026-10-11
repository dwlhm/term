package hit_test

// Automated Unit Tests for Spatial Hit-Testing Engine.
// Verifies point-in-rect edge cases, tab header vs close button classification,
// split divider +/-4.0px tolerance, leaf pane resolution, and extreme out-of-bounds coordinates.

import "core:testing"
import "../draw_list"
import "../splits"
import "../tabs"

@test
test_point_in_rect_exact_boundaries :: proc(t: ^testing.T) {
	rect: [4]f32 = {10.0, 20.0, 100.0, 50.0}

	// Inside
	testing.expect(t, point_in_rect({50.0, 45.0}, rect))

	// Exact corners
	testing.expect(t, point_in_rect({10.0, 20.0}, rect))  // top-left
	testing.expect(t, point_in_rect({110.0, 20.0}, rect)) // top-right
	testing.expect(t, point_in_rect({10.0, 70.0}, rect))  // bottom-left
	testing.expect(t, point_in_rect({110.0, 70.0}, rect)) // bottom-right

	// Exact edges
	testing.expect(t, point_in_rect({10.0, 45.0}, rect))  // left edge
	testing.expect(t, point_in_rect({110.0, 45.0}, rect)) // right edge
	testing.expect(t, point_in_rect({50.0, 20.0}, rect))  // top edge
	testing.expect(t, point_in_rect({50.0, 70.0}, rect))  // bottom edge

	// Sub-pixel beyond boundaries
	testing.expect(t, !point_in_rect({9.9999, 45.0}, rect))
	testing.expect(t, !point_in_rect({110.0001, 45.0}, rect))
	testing.expect(t, !point_in_rect({50.0, 19.9999}, rect))
	testing.expect(t, !point_in_rect({50.0, 70.0001}, rect))
}

@test
test_tab_header_vs_close_button_hit :: proc(t: ^testing.T) {
	m: tabs.Chrome_Tabs_Model
	tabs.tabs_model_init(&m, {0.0, 0.0, 800.0, 36.0})
	defer tabs.tabs_model_destroy(&m)

	tabs.tabs_add(&m, 1, "zsh")
	tabs.tabs_add(&m, 2, "nvim")

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	// Layout tabs to populate physical rects
	tabs.tabs_emit_draw_list(&m, &dl)

	// 1. Tab 0 Close button hit
	close_pt0 := [2]f32{
		m.tabs[0].close_rect[0] + m.tabs[0].close_rect[2] * 0.5,
		m.tabs[0].close_rect[1] + m.tabs[0].close_rect[3] * 0.5,
	}
	res0_close := chrome_hit_test(&m, nil, close_pt0)
	testing.expect_value(t, res0_close.kind, Hit_Kind.Tab_Close)
	testing.expect_value(t, res0_close.index, 0)
	testing.expect_value(t, res0_close.rect, m.tabs[0].close_rect)

	// 2. Tab 0 Header hit (away from close rect)
	hdr_pt0 := [2]f32{m.tabs[0].rect[0] + 15.0, m.tabs[0].rect[1] + 15.0}
	res0_hdr := chrome_hit_test(&m, nil, hdr_pt0)
	testing.expect_value(t, res0_hdr.kind, Hit_Kind.Tab_Header)
	testing.expect_value(t, res0_hdr.index, 0)
	testing.expect_value(t, res0_hdr.rect, m.tabs[0].rect)

	// 3. Tab 1 Close button hit
	close_pt1 := [2]f32{
		m.tabs[1].close_rect[0] + m.tabs[1].close_rect[2] * 0.5,
		m.tabs[1].close_rect[1] + m.tabs[1].close_rect[3] * 0.5,
	}
	res1_close := chrome_hit_test(&m, nil, close_pt1)
	testing.expect_value(t, res1_close.kind, Hit_Kind.Tab_Close)
	testing.expect_value(t, res1_close.index, 1)

	// 4. Tab 1 Header hit
	hdr_pt1 := [2]f32{m.tabs[1].rect[0] + 15.0, m.tabs[1].rect[1] + 15.0}
	res1_hdr := chrome_hit_test(&m, nil, hdr_pt1)
	testing.expect_value(t, res1_hdr.kind, Hit_Kind.Tab_Header)
	testing.expect_value(t, res1_hdr.index, 1)

	// 5. Hit empty region of tab bar
	empty_bar_pt := [2]f32{750.0, 18.0}
	res_empty := chrome_hit_test(&m, nil, empty_bar_pt)
	testing.expect_value(t, res_empty.kind, Hit_Kind.None)
}

@test
test_split_divider_tolerance_margin :: proc(t: ^testing.T) {
	// Horizontal split: 800x600, ratio 0.5 -> split line at x = 400.0
	// Tolerance +/-4.0px -> [396.0 .. 404.0]
	root_h := splits.split_node_create_leaf(1)
	defer splits.split_tree_destroy(root_h)
	splits.split_node_split(root_h, .Horizontal, 0.5, 2)
	splits.split_tree_layout(root_h, {0.0, 0.0, 800.0, 600.0})

	// Exactly on the center line
	res := chrome_hit_test(nil, root_h, {400.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	// On negative tolerance edge (-4.0px)
	res = chrome_hit_test(nil, root_h, {396.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	// On positive tolerance edge (+4.0px)
	res = chrome_hit_test(nil, root_h, {404.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	// Just outside negative tolerance edge
	res = chrome_hit_test(nil, root_h, {395.999, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(1))

	// Just outside positive tolerance edge
	res = chrome_hit_test(nil, root_h, {404.001, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(2))

	// Vertical split: 800x600, ratio 0.5 -> split line at y = 300.0
	// Tolerance +/-4.0px -> [296.0 .. 304.0]
	root_v := splits.split_node_create_leaf(10)
	defer splits.split_tree_destroy(root_v)
	splits.split_node_split(root_v, .Vertical, 0.5, 20)
	splits.split_tree_layout(root_v, {0.0, 0.0, 800.0, 600.0})

	res = chrome_hit_test(nil, root_v, {400.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	res = chrome_hit_test(nil, root_v, {400.0, 296.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	res = chrome_hit_test(nil, root_v, {400.0, 304.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)

	res = chrome_hit_test(nil, root_v, {400.0, 295.999})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(10))

	res = chrome_hit_test(nil, root_v, {400.0, 304.001})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(20))
}

@test
test_leaf_pane_hit_testing :: proc(t: ^testing.T) {
	leaf := splits.split_node_create_leaf(42)
	defer splits.split_tree_destroy(leaf)

	splits.split_tree_layout(leaf, {100.0, 100.0, 500.0, 400.0})

	// Inside leaf pane
	res := chrome_hit_test(nil, leaf, {250.0, 250.0})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(42))
	testing.expect_value(t, res.rect, [4]f32{100.0, 100.0, 500.0, 400.0})

	// Outside leaf pane
	res_out := chrome_hit_test(nil, leaf, {50.0, 50.0})
	testing.expect_value(t, res_out.kind, Hit_Kind.None)
}

@test
test_extreme_conditions_and_boundaries :: proc(t: ^testing.T) {
	root := splits.split_node_create_leaf(1)
	defer splits.split_tree_destroy(root)
	splits.split_tree_layout(root, {0.0, 0.0, 1000.0, 800.0})

	// 1. Negative coordinates
	res := chrome_hit_test(nil, root, {-100.0, -50.0})
	testing.expect_value(t, res.kind, Hit_Kind.None)

	// 2. Far beyond screen bounds (> 100,000px)
	res = chrome_hit_test(nil, root, {150000.0, 200000.0})
	testing.expect_value(t, res.kind, Hit_Kind.None)

	// 3. Immediately outside pane rect
	res = chrome_hit_test(nil, root, {1000.001, 400.0})
	testing.expect_value(t, res.kind, Hit_Kind.None)

	res = chrome_hit_test(nil, root, {500.0, 800.001})
	testing.expect_value(t, res.kind, Hit_Kind.None)

	// 4. Sub-pixel just inside boundary (0.0001px inside)
	res = chrome_hit_test(nil, root, {999.9999, 799.9999})
	testing.expect_value(t, res.kind, Hit_Kind.Pane)
	testing.expect_value(t, res.pane_id, u32(1))

	// 5. Nil arguments
	res_nil := chrome_hit_test(nil, nil, {500.0, 400.0})
	testing.expect_value(t, res_nil.kind, Hit_Kind.None)
}

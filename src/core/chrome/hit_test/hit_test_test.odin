package hit_test

// Automated Unit Tests for Spatial Hit-Testing Engine.
// Verifies point-in-rect edge cases, tab header vs close button classification,
// split divider +/-4.0px tolerance, leaf pane resolution, and extreme out-of-bounds coordinates.

import "core:math"
import "core:testing"
import "../draw_list"
import "../splits"
import "../tabs"
import cursor "../../cursor"

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
	testing.expect(t, res.split_node == root_h)

	// On negative tolerance edge (-4.0px)
	res = chrome_hit_test(nil, root_h, {396.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)
	testing.expect(t, res.split_node == root_h)

	// On positive tolerance edge (+4.0px)
	res = chrome_hit_test(nil, root_h, {404.0, 300.0})
	testing.expect_value(t, res.kind, Hit_Kind.Split_Divider)
	testing.expect(t, res.split_node == root_h)

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

@test
test_hit_test_non_finite_points :: proc(t: ^testing.T) {
	root := splits.split_node_create_leaf(1)
	defer splits.split_tree_destroy(root)
	splits.split_node_split(root, .Horizontal, 0.5, 2)
	splits.split_tree_layout(root, {0.0, 0.0, 1000.0, 800.0})

	m: tabs.Chrome_Tabs_Model
	tabs.tabs_model_init(&m, {0.0, 0.0, 1000.0, 32.0})
	defer tabs.tabs_model_destroy(&m)

	tabs.tabs_add(&m, 1, "zsh")
	tabs.tabs_add(&m, 2, "nvim")
	tabs.tabs_add(&m, 3, "make")

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl)
	defer draw_list.ui_draw_list_destroy(&dl)

	// Layout tabs to populate physical rects
	tabs.tabs_emit_draw_list(&m, &dl)

	nan := math.nan_f32()
	pos_inf := math.inf_f32(1)
	neg_inf := math.inf_f32(-1)

	points := [?][2]f32{
		{nan, 400.0},
		{500.0, nan},
		{nan, nan},
		{pos_inf, 400.0},
		{neg_inf, 400.0},
		{500.0, pos_inf},
		{500.0, neg_inf},
		{pos_inf, pos_inf},
	}
	for pt in points {
		res := chrome_hit_test(&m, root, pt)
		testing.expectf(t, res.kind == .None, "point %v: expected .None, got %v", pt, res.kind)
	}

	// Control: the same setup is live, a finite close-button point still hits
	close_pt := [2]f32{
		m.tabs[0].close_rect[0] + m.tabs[0].close_rect[2] * 0.5,
		m.tabs[0].close_rect[1] + m.tabs[0].close_rect[3] * 0.5,
	}
	res_close := chrome_hit_test(&m, root, close_pt)
	testing.expect_value(t, res_close.kind, Hit_Kind.Tab_Close)
	testing.expect_value(t, res_close.index, 0)
}

@test
test_hit_test_non_finite_layout :: proc(t: ^testing.T) {
	root := splits.split_node_create_leaf(1)
	defer splits.split_tree_destroy(root)
	left, right := splits.split_node_split(root, .Horizontal, 0.5, 2)

	// Direct field write bypasses split_node_split clamping
	root.ratio = math.nan_f32()
	splits.split_tree_layout(root, {0.0, 0.0, 1000.0, 800.0})

	res_div := chrome_hit_test(nil, root, {500.0, 400.0})
	testing.expect_value(t, res_div.kind, Hit_Kind.Split_Divider)

	res_left := chrome_hit_test(nil, root, {250.0, 400.0})
	testing.expect_value(t, res_left.kind, Hit_Kind.Pane)
	testing.expect_value(t, res_left.pane_id, left.pane_id)

	res_right := chrome_hit_test(nil, root, {750.0, 400.0})
	testing.expect_value(t, res_right.kind, Hit_Kind.Pane)
	testing.expect_value(t, res_right.pane_id, right.pane_id)
}

@test
test_hit_test_divider_matches_emitted_divider :: proc(t: ^testing.T) {
	test_ratios := [?]f32{0.01, 0.99}
	for r in test_ratios {
		root := splits.split_node_create_leaf(1)
		splits.split_node_split(root, .Horizontal, 0.5, 2)
		root.ratio = r

		bounds: [4]f32 = {0.0, 0.0, 1000.0, 800.0}
		splits.split_tree_layout(root, bounds)

		dl: draw_list.Ui_Draw_List
		draw_list.ui_draw_list_init(&dl)

		splits.split_tree_emit_dividers(root, &dl)
		testing.expect(t, len(dl.commands) > 0)
		divider_rect := dl.commands[0].rect
		center_x := divider_rect[0] + divider_rect[2] * 0.5
		center_y: f32 = 400.0

		hit_center := chrome_hit_test(nil, root, {center_x, center_y})
		testing.expect_value(t, hit_center.kind, Hit_Kind.Split_Divider)

		hit_minus := chrome_hit_test(nil, root, {center_x - 5.0, center_y})
		testing.expect(t, hit_minus.kind != .Split_Divider)

		hit_plus := chrome_hit_test(nil, root, {center_x + 5.0, center_y})
		testing.expect(t, hit_plus.kind != .Split_Divider)

		draw_list.ui_draw_list_destroy(&dl)
		splits.split_tree_destroy(root)
	}
}

@test
test_chrome_hit_cursor_mapping :: proc(t: ^testing.T) {
	// Tab Header -> Pointer
	c, handled := chrome_hit_cursor(Hit_Result{kind = .Tab_Header})
	testing.expect(t, handled)
	testing.expect_value(t, c, cursor.Mouse_Cursor.Pointer)

	// Tab Close -> Pointer
	c, handled = chrome_hit_cursor(Hit_Result{kind = .Tab_Close})
	testing.expect(t, handled)
	testing.expect_value(t, c, cursor.Mouse_Cursor.Pointer)

	// Horizontal Split Divider -> Col_Resize
	node_h := splits.Split_Node{kind = .Horizontal}
	c, handled = chrome_hit_cursor(Hit_Result{kind = .Split_Divider, split_node = &node_h})
	testing.expect(t, handled)
	testing.expect_value(t, c, cursor.Mouse_Cursor.Col_Resize)

	// Vertical Split Divider -> Row_Resize
	node_v := splits.Split_Node{kind = .Vertical}
	c, handled = chrome_hit_cursor(Hit_Result{kind = .Split_Divider, split_node = &node_v})
	testing.expect(t, handled)
	testing.expect_value(t, c, cursor.Mouse_Cursor.Row_Resize)

	// Modal -> Default
	c, handled = chrome_hit_cursor(Hit_Result{kind = .Modal})
	testing.expect(t, handled)
	testing.expect_value(t, c, cursor.Mouse_Cursor.Default)

	// Pane -> Not handled by chrome (handled = false)
	c, handled = chrome_hit_cursor(Hit_Result{kind = .Pane})
	testing.expect(t, !handled)

	// None -> Not handled by chrome (handled = false)
	c, handled = chrome_hit_cursor(Hit_Result{kind = .None})
	testing.expect(t, !handled)
}

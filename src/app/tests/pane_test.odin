package app_test

import "core:testing"
import "core:time"
import app "../"
import platform_tabs "../../platform/tabs"
import ui "../../ui"

@(test)
test_pane_tree_split_and_collapse :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	root_id := app.pane_tree_init(&tree, nil)
	testing.expect(t, root_id != 0, "root pane id must be non-zero")
	testing.expect(t, tree.root != nil, "root node must exist")
	testing.expect(t, tree.root.kind == .Leaf, "initial root node must be leaf")
	testing.expect_value(t, tree.root.id, root_id)
	testing.expect_value(t, tree.focused_pane_id, root_id)
	testing.expect_value(t, tree.node_count, 1)

	content_rect := platform_tabs.Rect_f32{x = 0, y = 0, w = 800, h = 600}
	app.pane_tree_layout(&tree, content_rect, 8, 16, 0, 0)
	testing.expect_value(t, tree.root.rect.w, f32(800))
	testing.expect_value(t, tree.root.rect.h, f32(600))

	// Split root vertically -> creates left (root_id) and right (child_id)
	child_id, ok_v := app.pane_tree_split(&tree, root_id, .Vertical, nil)
	testing.expect(t, ok_v, "vertical split must succeed")
	testing.expect(t, child_id != 0, "child pane id must be non-zero")
	testing.expect(t, tree.root.kind == .Split, "root must now be split node")
	testing.expect_value(t, tree.root.direction, app.Split_Direction.Vertical)
	testing.expect_value(t, tree.node_count, 3)

	// Split child horizontally -> creates top (child_id) and bottom (child2_id)
	child2_id, ok_h := app.pane_tree_split(&tree, child_id, .Horizontal, nil)
	testing.expect(t, ok_h, "horizontal split must succeed")
	testing.expect(t, child2_id != 0, "second child pane id must be non-zero")
	testing.expect_value(t, tree.node_count, 5)

	// Layout and check leaf bounds
	app.pane_tree_layout(&tree, content_rect, 8, 16, 0, 0)

	leaf1 := app.pane_tree_find_pane(&tree, root_id)
	leaf2 := app.pane_tree_find_pane(&tree, child_id)
	leaf3 := app.pane_tree_find_pane(&tree, child2_id)

	testing.expect(t, leaf1 != nil, "leaf1 must be present")
	testing.expect(t, leaf2 != nil, "leaf2 must be present")
	testing.expect(t, leaf3 != nil, "leaf3 must be present")

	// Left pane: spans full height, roughly half width
	testing.expect_value(t, leaf1.rect.x, f32(0))
	testing.expect_value(t, leaf1.rect.y, f32(0))
	testing.expect(t, leaf1.rect.w >= 395 && leaf1.rect.w <= 405, "leaf1 width near half")
	testing.expect_value(t, leaf1.rect.h, f32(600))

	// Top-right pane: begins after divider, top half
	testing.expect(t, leaf2.rect.x >= leaf1.rect.w, "leaf2 must be right of leaf1")
	testing.expect_value(t, leaf2.rect.y, f32(0))
	testing.expect(t, leaf2.rect.w >= 395 && leaf2.rect.w <= 405, "leaf2 width near half")
	testing.expect(t, leaf2.rect.h >= 295 && leaf2.rect.h <= 305, "leaf2 height near half")

	// Bottom-right pane: begins after horizontal divider, bottom half
	testing.expect_value(t, leaf3.rect.x, leaf2.rect.x)
	testing.expect(t, leaf3.rect.y >= leaf2.rect.h, "leaf3 must be below leaf2")
	testing.expect(t, leaf3.rect.w >= 395 && leaf3.rect.w <= 405, "leaf3 width near half")
	testing.expect(t, leaf3.rect.h >= 295 && leaf3.rect.h <= 305, "leaf3 height near half")

	// Close bottom-right child (child2_id) -> collapses back to sibling (leaf2)
	closed_last := app.pane_tree_close(&tree, child2_id)
	testing.expect(t, !closed_last, "closing child2 must not close last pane")
	testing.expect_value(t, tree.node_count, 3)
	testing.expect(t, app.pane_tree_find_pane(&tree, child2_id) == nil, "child2 must no longer exist")

	// Layout and verify leaf2 collapsed back to occupying the full right half
	app.pane_tree_layout(&tree, content_rect, 8, 16, 0, 0)
	leaf2_after := app.pane_tree_find_pane(&tree, child_id)
	testing.expect(t, leaf2_after != nil, "leaf2 must exist after collapse")
	testing.expect_value(t, leaf2_after.rect.y, f32(0))
	testing.expect_value(t, leaf2_after.rect.h, f32(600))

	// Close leaf2 -> collapses root to leaf1
	closed_last_2 := app.pane_tree_close(&tree, child_id)
	testing.expect(t, !closed_last_2, "closing leaf2 must not close last pane")
	testing.expect_value(t, tree.node_count, 1)
	testing.expect(t, tree.root.kind == .Leaf, "root must collapse back to leaf")
	testing.expect_value(t, tree.root.id, root_id)

	// Close root_id -> closes last pane
	closed_last_root := app.pane_tree_close(&tree, root_id)
	testing.expect(t, closed_last_root, "closing root must close last pane")
	testing.expect(t, tree.root == nil, "root must be nil after closing last pane")
	testing.expect_value(t, tree.node_count, 0)

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_tree_min_dimension_clamping :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	root_id := app.pane_tree_init(&tree, nil)

	// MIN_COLS = 10 (80px), MIN_ROWS = 2 (32px)
	// Two panes vertically require at least 2 * 80 + 1 = 161px width
	too_narrow_rect := platform_tabs.Rect_f32{x = 0, y = 0, w = 120, h = 400}
	app.pane_tree_layout(&tree, too_narrow_rect, 8, 16, 0, 0)

	_, ok_v := app.pane_tree_split(&tree, root_id, .Vertical, nil)
	testing.expect(t, !ok_v, "vertical split must be rejected when rect width is too small")

	// Two panes horizontally require at least 2 * 32 + 1 = 65px height
	too_short_rect := platform_tabs.Rect_f32{x = 0, y = 0, w = 400, h = 50}
	app.pane_tree_layout(&tree, too_short_rect, 8, 16, 0, 0)

	_, ok_h := app.pane_tree_split(&tree, root_id, .Horizontal, nil)
	testing.expect(t, !ok_h, "horizontal split must be rejected when rect height is too small")

	// Adequate rect permits split
	adequate_rect := platform_tabs.Rect_f32{x = 0, y = 0, w = 400, h = 300}
	app.pane_tree_layout(&tree, adequate_rect, 8, 16, 0, 0)

	p2, ok_good := app.pane_tree_split(&tree, root_id, .Vertical, nil)
	testing.expect(t, ok_good, "vertical split must succeed when dimensions are adequate")
	testing.expect(t, p2 != 0, "new pane id must be non-zero")

	// Verify pane_tree_layout row/col minimum clamping
	tiny_rect := platform_tabs.Rect_f32{x = 0, y = 0, w = 20, h = 10}
	app.pane_tree_layout(&tree, tiny_rect, 8, 16, 0, 0)
	leaf := app.pane_tree_find_pane(&tree, root_id)
	testing.expect(t, leaf != nil, "leaf must exist")
	testing.expect(t, leaf.cols >= app.MIN_COLS, "cols must be clamped to MIN_COLS")
	testing.expect(t, leaf.rows >= app.MIN_ROWS, "rows must be clamped to MIN_ROWS")

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_tree_spatial_navigation :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)

	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)

	p2, _ := app.pane_tree_split(&tree, p1, .Vertical, nil)
	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)

	// Focus p1 (left) and navigate right
	tree.focused_pane_id = p1
	nav_right := app.pane_tree_navigate_spatially(&tree, .Vertical, true)
	testing.expect(t, nav_right, "navigating right must succeed")
	testing.expect_value(t, tree.focused_pane_id, p2)

	// Navigate left back to p1
	nav_left := app.pane_tree_navigate_spatially(&tree, .Vertical, false)
	testing.expect(t, nav_left, "navigating left must succeed")
	testing.expect_value(t, tree.focused_pane_id, p1)

	// Cannot navigate left further
	nav_left_fail := app.pane_tree_navigate_spatially(&tree, .Vertical, false)
	testing.expect(t, !nav_left_fail, "navigating left from leftmost pane must fail")

	// Split p2 horizontally into p2 (top-right) and p3 (bottom-right)
	p3, _ := app.pane_tree_split(&tree, p2, .Horizontal, nil)
	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)

	// From p2 (top-right), navigate down to p3
	tree.focused_pane_id = p2
	nav_down := app.pane_tree_navigate_spatially(&tree, .Horizontal, true)
	testing.expect(t, nav_down, "navigating down from top-right pane must succeed")
	testing.expect_value(t, tree.focused_pane_id, p3)

	// From p3 (bottom-right), navigate up to p2
	nav_up := app.pane_tree_navigate_spatially(&tree, .Horizontal, false)
	testing.expect(t, nav_up, "navigating up from bottom-right pane must succeed")
	testing.expect_value(t, tree.focused_pane_id, p2)

	// From p3 (bottom-right), navigate left across the vertical split to p1
	tree.focused_pane_id = p3
	nav_left_from_p3 := app.pane_tree_navigate_spatially(&tree, .Vertical, false)
	testing.expect(t, nav_left_from_p3, "navigating left from bottom-right to left pane must succeed")
	testing.expect_value(t, tree.focused_pane_id, p1)

	// Test pane_tree_cycle_focus across leaves in Z-order
	tree.focused_pane_id = p1
	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p2)

	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p3)

	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p1)

	app.pane_tree_cycle_focus(&tree, false)
	testing.expect_value(t, tree.focused_pane_id, p3)

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_tree_resize_and_equalize :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)

	p2, _ := app.pane_tree_split(&tree, p1, .Vertical, nil)
	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	testing.expect_value(t, tree.root.ratio, f32(0.5))

	// Resize active pane (p1) wider by +0.1
	tree.focused_pane_id = p1
	ok_res := app.pane_tree_resize_active(&tree, .Vertical, 0.1)
	testing.expect(t, ok_res, "resizing active pane must succeed")
	testing.expect_value(t, tree.root.ratio, f32(0.6))

	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	leaf1 := app.pane_tree_find_pane(&tree, p1)
	leaf2 := app.pane_tree_find_pane(&tree, p2)
	testing.expect(t, leaf1.rect.w > leaf2.rect.w, "leaf1 must be wider than leaf2 after ratio adjustment")

	// Equalize resets ratio back to 0.5
	ok_eq := app.pane_tree_equalize(&tree)
	testing.expect(t, ok_eq, "equalize must succeed")
	testing.expect_value(t, tree.root.ratio, f32(0.5))

	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	testing.expect_value(t, leaf1.rect.w, leaf2.rect.w)

	// Ratio clamping: upper clamp to 0.9
	_ = app.pane_tree_resize_active(&tree, .Vertical, 0.8)
	testing.expect_value(t, tree.root.ratio, f32(0.9))

	// Ratio clamping: lower clamp to 0.1
	_ = app.pane_tree_resize_active(&tree, .Vertical, -1.5)
	testing.expect_value(t, tree.root.ratio, f32(0.1))

	// Reset to 0.5 for hit test and zoom verification
	app.pane_tree_equalize(&tree)
	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)

	// Hit test divider: divider center is at x = 500.5
	hit_leaf, hit_divider := app.pane_tree_hit_test(&tree, 500.5, 300.0)
	testing.expect(t, hit_leaf == nil, "leaf must be nil on divider hit")
	testing.expect(t, hit_divider == tree.root, "divider must match root split node")

	// Hit test leaf: left pane
	hit_leaf_p1, hit_div_p1 := app.pane_tree_hit_test(&tree, 100.0, 300.0)
	testing.expect(t, hit_leaf_p1 == leaf1, "leaf must match leaf1")
	testing.expect(t, hit_div_p1 == nil, "divider must be nil on leaf hit")

	// Zoom toggle: zoom p1
	app.pane_tree_toggle_zoom(&tree, p1)
	testing.expect_value(t, tree.zoomed_pane_id, p1)
	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	testing.expect_value(t, leaf1.rect.w, f32(1001))
	testing.expect_value(t, leaf1.rect.h, f32(600))

	// Zoom toggle off
	app.pane_tree_toggle_zoom(&tree, p1)
	testing.expect_value(t, tree.zoomed_pane_id, app.Pane_Id(0))
	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	testing.expect_value(t, leaf1.rect.w, f32(500))

	app.pane_tree_destroy(&tree)
}

@(test)
test_tab_pane_tree_integration :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	idx, ok := app.session_spawn(&sm, "/bin/echo", {"init"}, 24, 80, nil, {})
	testing.expect(t, ok, "spawn tab must succeed")
	testing.expect_value(t, idx, 0)

	tab := &sm.tabs[idx]
	testing.expect(t, tab.tree.root != nil, "tab.tree.root must be non-nil")
	testing.expect(t, tab.tree.root.kind == .Leaf, "tab.tree.root must be leaf")
	testing.expect(t, tab.tree.root.backend == &tab.backend, "tab.tree.root.backend must point to tab.backend")

	leaves: [app.MAX_PANE_NODES]^app.Pane_Node
	count := app.tab_leaf_panes(tab, leaves[:])
	testing.expect_value(t, count, 1)
	testing.expect(t, leaves[0] == tab.tree.root, "first leaf must be root")

	active_node := app.tab_active_pane(tab)
	testing.expect(t, active_node == tab.tree.root, "active pane must be root")

	active_b := app.tab_active_backend(tab)
	testing.expect(t, active_b == &tab.backend, "active backend must be tab.backend")

	// Create a dummy second backend and split the tab's tree
	b2 := new(app.Backend)
	b2_ok := app.backend_init(b2, 24, 40, "/bin/echo", {"pane2"}, nil, {})
	testing.expect(t, b2_ok, "backend2 init must succeed")

	p2_id, split_ok := app.pane_tree_split(&tab.tree, tab.tree.root.id, .Vertical, b2)
	testing.expect(t, split_ok, "split pane must succeed")
	testing.expect(t, p2_id != 0, "p2_id must be non-zero")

	count2 := app.tab_leaf_panes(tab, leaves[:])
	testing.expect_value(t, count2, 2)

	active_node2 := app.tab_active_pane(tab)
	testing.expect(t, active_node2 != nil, "active pane after split must exist")
	testing.expect_value(t, active_node2.id, p2_id)

	active_b2 := app.tab_active_backend(tab)
	testing.expect(t, active_b2 == b2, "active backend must now be b2")
}

@test
test_pane_tree_multi_viewport_layout_and_resizing :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	idx, ok := app.session_spawn(&sm, "/bin/echo", {"init"}, 24, 80, nil, {})
	testing.expect(t, ok, "spawn tab must succeed")
	tab := &sm.tabs[idx]
	app.backend_stop_thread(&tab.backend)

	b2 := new(app.Backend)
	b2_ok := app.backend_init(b2, 24, 80, "/bin/echo", {"pane2"}, nil, {})
	testing.expect(t, b2_ok, "backend2 init must succeed")

	p2_id, split_ok := app.pane_tree_split(&tab.tree, tab.tree.root.id, .Vertical, b2)
	testing.expect(t, split_ok, "vertical split must succeed")
	testing.expect(t, p2_id != 0, "p2_id must be non-zero")

	content_rect := platform_tabs.Rect_f32{x = 0, y = 28, w = 800, h = 572}
	cell_w: f32 = 8.0
	cell_h: f32 = 16.0
	pad: f32 = 4.0

	app.pane_tree_layout(&tab.tree, content_rect, cell_w, cell_h, pad, pad)

	leaf1 := app.pane_tree_find_pane(&tab.tree, tab.tree.root.first.id)
	leaf2 := app.pane_tree_find_pane(&tab.tree, p2_id)
	testing.expect(t, leaf1 != nil, "leaf1 must exist")
	testing.expect(t, leaf2 != nil, "leaf2 must exist")

	testing.expect(t, leaf1.cols >= 45 && leaf1.cols <= 50, "leaf1 cols should be ~48")
	testing.expect(t, leaf1.rows >= 30 && leaf1.rows <= 40, "leaf1 rows should be ~35")
	testing.expect(t, leaf2.cols >= 45 && leaf2.cols <= 50, "leaf2 cols should be ~48")
	testing.expect(t, leaf2.rows >= 30 && leaf2.rows <= 40, "leaf2 rows should be ~35")

	// Geometry is pure; the app dispatch boundary owns all resize side effects.
	testing.expect_value(t, leaf1.backend.terminal.grid.row_count, 24)
	testing.expect_value(t, leaf1.backend.terminal.grid.col_count, 80)
	testing.expect_value(t, leaf2.backend.terminal.grid.row_count, 24)
	testing.expect_value(t, leaf2.backend.terminal.grid.col_count, 80)
}

@(test)
test_pane_shortcut_actions_and_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.ui_shortcut_label(.Split_Vertical), "\u2318\\")
	testing.expect_value(t, ui.ui_shortcut_label(.Split_Horizontal), "\u2325\u2318\\")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Resize_Left), "\u2325\u21E7\u2318\u2190")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Resize_Right), "\u2325\u21E7\u2318\u2192")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Resize_Up), "\u2325\u21E7\u2318\u2191")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Resize_Down), "\u2325\u21E7\u2318\u2193")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Equalize), "\u2325\u2318=")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Zoom), "\u21E7\u2318\u21B5")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Prev), "\u2318[")
	testing.expect_value(t, ui.ui_shortcut_label(.Pane_Next), "\u2318]")
}

@(test)
test_pane_divider_drag_and_equalize_lifecycle :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)
	p2, _ := app.pane_tree_split(&tree, p1, .Vertical, nil)
	_ = p2

	app.pane_tree_layout(&tree, {0, 0, 1001, 600}, 8, 16, 0, 0)
	testing.expect_value(t, tree.root.ratio, f32(0.5))

	// Hit test divider at x=500.5
	_, hit_divider := app.pane_tree_hit_test(&tree, 500.5, 300.0)
	testing.expect(t, hit_divider != nil, "divider must be hit at split line")

	// Begin drag
	app.pane_tree_divider_drag_begin(&tree, hit_divider, 500.0)
	testing.expect(t, tree.divider_dragging, "divider dragging must be active")
	testing.expect(t, tree.divider_hover == hit_divider, "dragged divider must be hover target")

	// Drag right: increase ratio
	updated := app.pane_tree_divider_drag_update(&tree, 600.0)
	testing.expect(t, updated, "drag update right must update ratio")
	testing.expect(t, tree.root.ratio > 0.5, "ratio must increase when dragged right")

	// End drag
	app.pane_tree_divider_drag_end(&tree)
	testing.expect(t, !tree.divider_dragging, "divider dragging must be inactive after end")

	// Double-click equalize returns ratio to 0.5
	eq_ok := app.pane_tree_equalize(&tree)
	testing.expect(t, eq_ok, "equalize must succeed")
	testing.expect_value(t, tree.root.ratio, f32(0.5))

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_2x2_spatial_navigation :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)

	// Vertical split: left (p1), right (p2)
	p2, _ := app.pane_tree_split(&tree, p1, .Vertical, nil)

	// Horizontal split on left: top-left (p1), bottom-left (p3)
	p3, _ := app.pane_tree_split(&tree, p1, .Horizontal, nil)

	// Horizontal split on right: top-right (p2), bottom-right (p4)
	p4, _ := app.pane_tree_split(&tree, p2, .Horizontal, nil)

	app.pane_tree_layout(&tree, {0, 0, 800, 600}, 8, 16, 0, 0)
	testing.expect_value(t, tree.node_count, 7)

	// Test navigation from p1 (top-left)
	tree.focused_pane_id = p1
	testing.expect(t, app.pane_tree_navigate_spatially(&tree, .Vertical, true), "p1 -> right")
	testing.expect_value(t, tree.focused_pane_id, p2)

	tree.focused_pane_id = p1
	testing.expect(t, app.pane_tree_navigate_spatially(&tree, .Horizontal, true), "p1 -> down")
	testing.expect_value(t, tree.focused_pane_id, p3)

	// Test navigation from p4 (bottom-right)
	tree.focused_pane_id = p4
	testing.expect(t, app.pane_tree_navigate_spatially(&tree, .Vertical, false), "p4 -> left")
	testing.expect_value(t, tree.focused_pane_id, p3)

	tree.focused_pane_id = p4
	testing.expect(t, app.pane_tree_navigate_spatially(&tree, .Horizontal, false), "p4 -> up")
	testing.expect_value(t, tree.focused_pane_id, p2)

	// Test cycle focus across all 4 leaves in order
	tree.focused_pane_id = p1
	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p3)
	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p2)
	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p4)
	app.pane_tree_cycle_focus(&tree, true)
	testing.expect_value(t, tree.focused_pane_id, p1)

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_close_collapses_and_focuses_sibling :: proc(t: ^testing.T) {
	tree: app.Pane_Tree
	p1 := app.pane_tree_init(&tree, nil)
	p2, _ := app.pane_tree_split(&tree, p1, .Vertical, nil)

	testing.expect_value(t, tree.focused_pane_id, p2)
	testing.expect_value(t, tree.node_count, 3)

	// Close p2 (focused) -> focus collapses to p1 (sibling)
	closed_last := app.pane_tree_close(&tree, p2)
	testing.expect(t, !closed_last, "closing p2 should not close last pane")
	testing.expect_value(t, tree.focused_pane_id, p1)
	testing.expect_value(t, tree.node_count, 1)
	testing.expect(t, tree.root.kind == .Leaf, "root should collapse to leaf")
	testing.expect_value(t, tree.root.id, p1)

	app.pane_tree_destroy(&tree)
}

@(test)
test_pane_exit_invalidates_dispatched_and_restores_dimensions :: proc(t: ^testing.T) {
	sm: app.Session_Manager
	app.session_manager_init(&sm, 4)
	defer app.session_manager_destroy(&sm)

	idx, ok := app.session_spawn(&sm, "/bin/sleep", {"10"}, 24, 80, nil, {})
	testing.expect(t, ok, "spawn tab must succeed")
	tab := &sm.tabs[idx]
	app.backend_stop_thread(&tab.backend)

	b2 := new(app.Backend)
	b2_ok := app.backend_init(b2, 24, 80, "/bin/echo", {"exit_fast"}, nil, {})
	testing.expect(t, b2_ok, "backend2 init must succeed")
	app.backend_stop_thread(b2)

	p2_id, split_ok := app.pane_tree_split(&tab.tree, tab.tree.root.id, .Vertical, b2)
	testing.expect(t, split_ok, "vertical split must succeed")

	content_rect := platform_tabs.Rect_f32{x = 0, y = 28, w = 800, h = 572}
	cell_w: f32 = 8.0
	cell_h: f32 = 16.0
	pad: f32 = 4.0

	app.pane_tree_layout(&tab.tree, content_rect, cell_w, cell_h, pad, pad)

	leaf1 := app.pane_tree_find_pane(&tab.tree, tab.tree.root.first.id)
	testing.expect(t, leaf1 != nil, "leaf1 must exist")
	leaf1.dispatched_rows = leaf1.rows
	leaf1.dispatched_cols = leaf1.cols
	half_cols := leaf1.cols

	// Poll until child exits and session_poll_all cleans it up
	for _ in 0..<100 {
		_ = app.session_poll_all(&sm, 65536)
		if tab.tree.node_count == 1 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}

	testing.expect_value(t, tab.tree.node_count, 1)
	testing.expect(t, tab.tree.root.kind == .Leaf, "tree root should now be leaf")
	testing.expect_value(t, tab.tree.root.dispatched_rows, 0)
	testing.expect_value(t, tab.tree.root.dispatched_cols, 0)

	// Next layout should recalculate full width
	app.pane_tree_layout(&tab.tree, content_rect, cell_w, cell_h, pad, pad)
	testing.expect(t, tab.tree.root.cols > half_cols, "remaining pane should now have full columns")
	testing.expect(t, tab.tree.root.cols >= 95 && tab.tree.root.cols <= 100, "remaining pane cols should be ~99")
}


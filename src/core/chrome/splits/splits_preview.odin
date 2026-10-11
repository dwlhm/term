package splits

// Pure Declarative UI Geometry Engine - Splits Preview Fixtures.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.

import "../draw_list"

// preview_splits_normal generates 2-split 50:50 and 4-split 2x2 grid layout and emits dividers into dl.
preview_splits_normal :: proc(dl: ^draw_list.Ui_Draw_List, bounds: [4]f32) {
	if dl == nil do return

	// 1. 2-split 50:50 layout
	root2 := split_node_create_leaf(1)
	split_node_split(root2, .Horizontal, 0.5, 2)
	split_tree_layout(root2, bounds)
	split_tree_emit_dividers(root2, dl)
	split_tree_destroy(root2)

	// 2. 4-split 2x2 grid layout
	root4 := split_node_create_leaf(10)
	top, btm := split_node_split(root4, .Vertical, 0.5, 20)
	if top != nil do split_node_split(top, .Horizontal, 0.5, 11)
	if btm != nil do split_node_split(btm, .Horizontal, 0.5, 21)
	split_tree_layout(root4, bounds)
	split_tree_emit_dividers(root4, dl)
	split_tree_destroy(root4)
}

// preview_splits_extreme generates a deep depth-16 binary tree with extreme ratio (0.0001) and emits dividers into dl.
preview_splits_extreme :: proc(dl: ^draw_list.Ui_Draw_List, bounds: [4]f32) {
	if dl == nil do return

	root := split_node_create_leaf(1)
	curr := root

	// Build deep depth-16 binary tree spine with extreme ratio partitions
	for i in 1..<16 {
		kind: Split_Kind = .Horizontal if (i % 2 == 1) else .Vertical
		_, right := split_node_split(curr, kind, 0.0001, u32(i + 1))
		if right == nil do break
		curr = right
	}

	split_tree_layout(root, bounds)
	split_tree_emit_dividers(root, dl)
	split_tree_destroy(root)
}

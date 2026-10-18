package splits

// Automated Unit Tests for Binary Split Tree Declarative Geometry Engine.
// Verifies leaf creation, splitting, ratio clamping [0.1 .. 0.9],
// spatial layout calculations, deep depth-16 tree destruction, and zero memory leaks.

import "core:math"
import "core:mem"
import "core:testing"
import "../draw_list"

@test
test_splits_leaf_creation_and_splitting :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	root := split_node_create_leaf(10, alloc)
	testing.expect_value(t, root.kind, Split_Kind.Leaf)
	testing.expect_value(t, root.pane_id, u32(10))
	testing.expect_value(t, root.ratio, f32(0.5))
	testing.expect(t, root.left == nil)
	testing.expect(t, root.right == nil)

	// Split horizontal into two panes
	left, right := split_node_split(root, .Horizontal, 0.60, 20, alloc)
	testing.expect(t, left != nil)
	testing.expect(t, right != nil)
	testing.expect_value(t, root.kind, Split_Kind.Horizontal)
	testing.expect_value(t, root.ratio, f32(0.60))
	testing.expect_value(t, root.pane_id, u32(0))
	testing.expect_value(t, left.pane_id, u32(10))
	testing.expect_value(t, right.pane_id, u32(20))

	// Split left child vertically
	sub_left, sub_right := split_node_split(left, .Vertical, 0.40, 30, alloc)
	testing.expect(t, sub_left != nil)
	testing.expect(t, sub_right != nil)
	testing.expect_value(t, left.kind, Split_Kind.Vertical)
	testing.expect_value(t, left.ratio, f32(0.40))
	testing.expect_value(t, sub_left.pane_id, u32(10))
	testing.expect_value(t, sub_right.pane_id, u32(30))

	split_tree_destroy(root, alloc)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@test
test_splits_ratio_clamping :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	// Underflow: ratio < 0.1 clamps to 0.1
	n1 := split_node_create_leaf(1, alloc)
	split_node_split(n1, .Horizontal, 0.0001, 2, alloc)
	testing.expect_value(t, n1.ratio, f32(0.1))
	split_tree_destroy(n1, alloc)

	// Negative ratio clamps to 0.1
	n2 := split_node_create_leaf(1, alloc)
	split_node_split(n2, .Horizontal, -1.0, 2, alloc)
	testing.expect_value(t, n2.ratio, f32(0.1))
	split_tree_destroy(n2, alloc)

	// Overflow: ratio > 0.9 clamps to 0.9
	n3 := split_node_create_leaf(1, alloc)
	split_node_split(n3, .Vertical, 0.99, 2, alloc)
	testing.expect_value(t, n3.ratio, f32(0.9))
	split_tree_destroy(n3, alloc)

	// Large ratio clamps to 0.9
	n4 := split_node_create_leaf(1, alloc)
	split_node_split(n4, .Vertical, 5.0, 2, alloc)
	testing.expect_value(t, n4.ratio, f32(0.9))
	split_tree_destroy(n4, alloc)

	// Normal valid ratio preserved
	n5 := split_node_create_leaf(1, alloc)
	split_node_split(n5, .Horizontal, 0.70, 2, alloc)
	testing.expect_value(t, n5.ratio, f32(0.70))
	split_tree_destroy(n5, alloc)

	// Non-finite ratios map to 0.5
	n_nan := split_node_create_leaf(1, alloc)
	split_node_split(n_nan, .Horizontal, math.nan_f32(), 2, alloc)
	testing.expect_value(t, n_nan.ratio, f32(0.5))
	split_tree_destroy(n_nan, alloc)

	n_pinf := split_node_create_leaf(1, alloc)
	split_node_split(n_pinf, .Horizontal, math.inf_f32(1), 2, alloc)
	testing.expect_value(t, n_pinf.ratio, f32(0.5))
	split_tree_destroy(n_pinf, alloc)

	n_ninf := split_node_create_leaf(1, alloc)
	split_node_split(n_ninf, .Horizontal, math.inf_f32(-1), 2, alloc)
	testing.expect_value(t, n_ninf.ratio, f32(0.5))
	split_tree_destroy(n_ninf, alloc)

	testing.expect_value(t, track.current_memory_allocated, 0)
}

@test
test_splits_effective_ratio :: proc(t: ^testing.T) {
	node := split_node_create_leaf(1)
	defer split_tree_destroy(node)

	// Direct-write 0.01 -> clamps to 0.05
	node.ratio = 0.01
	testing.expect_value(t, split_effective_ratio(node), f32(0.05))

	// Direct-write 0.99 -> clamps to 0.95
	node.ratio = 0.99
	testing.expect_value(t, split_effective_ratio(node), f32(0.95))

	// Direct-write NaN -> 0.5
	node.ratio = math.nan_f32()
	testing.expect_value(t, split_effective_ratio(node), f32(0.5))

	// Direct-write 0.3 -> preserves 0.3
	node.ratio = 0.3
	testing.expect_value(t, split_effective_ratio(node), f32(0.3))

	// Nil node returns 0.5
	testing.expect_value(t, split_effective_ratio(nil), f32(0.5))
}

@test
test_splits_layout_calculation :: proc(t: ^testing.T) {
	// Root split 50:50 horizontal on 1000x800 viewport
	root := split_node_create_leaf(1)
	defer split_tree_destroy(root)

	left, right := split_node_split(root, .Horizontal, 0.5, 2)
	split_node_split(right, .Vertical, 0.25, 3)

	bounds: [4]f32 = {100.0, 200.0, 1000.0, 800.0}
	split_tree_layout(root, bounds)

	// Root bounds
	testing.expect_value(t, root.rect, bounds)

	// Left pane: x=100, y=200, w=500, h=800
	testing.expect_value(t, left.rect[0], f32(100.0))
	testing.expect_value(t, left.rect[1], f32(200.0))
	testing.expect_value(t, left.rect[2], f32(500.0))
	testing.expect_value(t, left.rect[3], f32(800.0))

	// Right internal node: x=600, y=200, w=500, h=800
	testing.expect_value(t, right.rect[0], f32(600.0))
	testing.expect_value(t, right.rect[1], f32(200.0))
	testing.expect_value(t, right.rect[2], f32(500.0))
	testing.expect_value(t, right.rect[3], f32(800.0))

	// Right top child: x=600, y=200, w=500, h=200 (800 * 0.25)
	testing.expect_value(t, right.left.rect[0], f32(600.0))
	testing.expect_value(t, right.left.rect[1], f32(200.0))
	testing.expect_value(t, right.left.rect[2], f32(500.0))
	testing.expect_value(t, right.left.rect[3], f32(200.0))

	// Right bottom child: x=600, y=400, w=500, h=600 (800 - 200)
	testing.expect_value(t, right.right.rect[0], f32(600.0))
	testing.expect_value(t, right.right.rect[1], f32(400.0))
	testing.expect_value(t, right.right.rect[2], f32(500.0))
	testing.expect_value(t, right.right.rect[3], f32(600.0))
}

@test
test_splits_deep_tree_depth_16_zero_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	root := split_node_create_leaf(1, alloc)
	curr := root

	// Construct depth 16 tree spine
	for i in 1..<16 {
		kind: Split_Kind = .Horizontal if (i % 2 == 1) else .Vertical
		_, right := split_node_split(curr, kind, 0.5, u32(i + 1), alloc)
		if right == nil do break
		curr = right
	}

	split_tree_layout(root, {0.0, 0.0, 1920.0, 1080.0})

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl, alloc)
	defer draw_list.ui_draw_list_destroy(&dl)

	split_tree_emit_dividers(root, &dl)
	testing.expect(t, len(dl.commands) >= 15)

	draw_list.ui_draw_list_destroy(&dl)
	split_tree_destroy(root, alloc)

	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@test
test_splits_zero_size_and_boundary_conditions :: proc(t: ^testing.T) {
	// Zero viewport size
	root := split_node_create_leaf(1)
	defer split_tree_destroy(root)

	split_node_split(root, .Horizontal, 0.5, 2)
	split_tree_layout(root, {0, 0, 0, 0})

	testing.expect_value(t, root.left.rect, [4]f32{0, 0, 0, 0})
	testing.expect_value(t, root.right.rect, [4]f32{0, 0, 0, 0})

	// Nil safety guards
	split_tree_layout(nil, {0, 0, 100, 100})
	split_tree_emit_dividers(nil, nil)
	split_tree_destroy(nil)
	l, r := split_node_split(nil, .Horizontal, 0.5, 1)
	testing.expect(t, l == nil)
	testing.expect(t, r == nil)
}

@test
test_splits_preview_fixtures :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	dl: draw_list.Ui_Draw_List
	draw_list.ui_draw_list_init(&dl, alloc)
	defer draw_list.ui_draw_list_destroy(&dl)

	preview_splits_normal(&dl, {0, 0, 800, 600})
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_clear(&dl)

	preview_splits_extreme(&dl, {0, 0, 800, 600})
	testing.expect(t, len(dl.commands) > 0)

	draw_list.ui_draw_list_destroy(&dl)
	testing.expect_value(t, track.current_memory_allocated, 0)
}

@test
test_splits_find_and_remove :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	root := split_node_create_leaf(1, alloc)

	// Single leaf find
	testing.expect(t, split_tree_find_leaf(root, 1) == root)
	testing.expect(t, split_tree_find_leaf(root, 99) == nil)

	// Split 1 into (1, 2)
	l1, r2 := split_node_split(root, .Horizontal, 0.5, 2, alloc)
	testing.expect(t, l1 != nil && r2 != nil)

	// Split 2 into (2, 3)
	l2, r3 := split_node_split(r2, .Vertical, 0.5, 3, alloc)
	testing.expect(t, l2 != nil && r3 != nil)

	// Find in 3-pane tree
	testing.expect(t, split_tree_find_leaf(root, 1) == l1)
	testing.expect(t, split_tree_find_leaf(root, 2) == l2)
	testing.expect(t, split_tree_find_leaf(root, 3) == r3)
	testing.expect(t, split_tree_find_leaf(root, 4) == nil)

	// Remove pane 2 (child of right subtree)
	ok := split_tree_remove_pane(&root, 2, alloc)
	testing.expect(t, ok, "Removing pane 2 should succeed")
	testing.expect(t, root.kind == .Horizontal, "Root should still be Horizontal")
	testing.expect(t, root.left == l1, "Left should still be pane 1")
	testing.expect(t, root.right.kind == .Leaf && root.right.pane_id == 3, "Right should now be promoted leaf pane 3")

	// Remove pane 1 (left child of root)
	ok = split_tree_remove_pane(&root, 1, alloc)
	testing.expect(t, ok, "Removing pane 1 should succeed")
	testing.expect(t, root.kind == .Leaf, "Root should now collapse to Leaf")
	testing.expect_value(t, root.pane_id, u32(3))

	// Remove final pane 3
	ok = split_tree_remove_pane(&root, 3, alloc)
	testing.expect(t, ok, "Removing pane 3 should succeed")
	testing.expect(t, root == nil, "Root should now be nil")

	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_splits_three_pane_remove_leaf_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	// User flow: Pane 1 is split right -> (Pane 1, Pane 2)
	root := split_node_create_leaf(1, alloc)
	split_node_split(root, .Horizontal, 0.5, 2, alloc)

	// User focuses pane 2 and splits right again -> (Pane 2, Pane 3)
	leaf2 := split_tree_find_leaf(root, 2)
	testing.expect(t, leaf2 != nil)
	split_node_split(leaf2, .Horizontal, 0.5, 3, alloc)

	// Tree structure:
	//         Root (H)
	//        /        \
	//     Leaf(1)   Inner (H)
	//               /       \
	//            Leaf(2)   Leaf(3)
	testing.expect(t, split_tree_find_leaf(root, 1) != nil)
	testing.expect(t, split_tree_find_leaf(root, 2) != nil)
	testing.expect(t, split_tree_find_leaf(root, 3) != nil)

	// User types 'exit' in Pane 3 (reap dead session -> remove pane 3)
	ok := split_tree_remove_pane(&root, 3, alloc)
	testing.expect(t, ok, "Removing pane 3 should succeed")
	testing.expect(t, root != nil, "Root should remain non-nil")
	testing.expect(t, root.kind == .Horizontal, "Root should still be Horizontal")
	testing.expect(t, split_tree_find_leaf(root, 1) != nil, "Pane 1 must remain")
	testing.expect(t, split_tree_find_leaf(root, 2) != nil, "Pane 2 must remain")
	testing.expect(t, split_tree_find_leaf(root, 3) == nil, "Pane 3 must be gone")

	// User types 'exit' in Pane 2 -> root collapses to single Leaf(1)
	ok = split_tree_remove_pane(&root, 2, alloc)
	testing.expect(t, ok, "Removing pane 2 should succeed")
	testing.expect(t, root != nil && root.kind == .Leaf, "Root should collapse to Leaf")
	testing.expect_value(t, root.pane_id, u32(1))

	// User types 'exit' in Pane 1 -> root becomes nil
	ok = split_tree_remove_pane(&root, 1, alloc)
	testing.expect(t, ok, "Removing final pane 1 should succeed")
	testing.expect(t, root == nil, "Root should be nil after all panes removed")

	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}



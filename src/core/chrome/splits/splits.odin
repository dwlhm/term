package splits

// Pure Declarative UI Geometry Engine - Binary Split Tree Topology.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Represents arbitrary recursive multi-pane terminal partitioning.

import "base:runtime"
import "../draw_list"

// Split_Kind classifies binary partition orientation.
Split_Kind :: enum {
	Leaf,
	Horizontal,
	Vertical,
}

// Split_Node is a recursive binary tree node representing window division.
Split_Node :: struct {
	kind:    Split_Kind,
	ratio:   f32,
	pane_id: u32,
	left:    ^Split_Node,
	right:   ^Split_Node,
	rect:    [4]f32,
}

// split_node_create_leaf creates a single leaf pane node.
split_node_create_leaf :: proc(pane_id: u32, allocator := context.allocator) -> ^Split_Node {
	node := new(Split_Node, allocator)
	node.kind = .Leaf
	node.pane_id = pane_id
	node.ratio = 0.5
	return node
}

// split_node_split converts a leaf into an internal node with two children.
split_node_split :: proc(node: ^Split_Node, kind: Split_Kind, ratio: f32, new_pane_id: u32, allocator := context.allocator) -> (left: ^Split_Node, right: ^Split_Node) {
	if node == nil || node.kind != .Leaf do return nil, nil

	left = new(Split_Node, allocator)
	left.kind = .Leaf
	left.pane_id = node.pane_id
	left.ratio = 0.5

	right = new(Split_Node, allocator)
	right.kind = .Leaf
	right.pane_id = new_pane_id
	right.ratio = 0.5

	node.kind = kind
	node.ratio = clamp(ratio, 0.05, 0.95)
	node.pane_id = 0
	node.left = left
	node.right = right

	return left, right
}

// split_tree_destroy recursively frees all child nodes.
split_tree_destroy :: proc(node: ^Split_Node, allocator := context.allocator) {
	if node == nil do return
	if node.left != nil {
		split_tree_destroy(node.left, allocator)
		node.left = nil
	}
	if node.right != nil {
		split_tree_destroy(node.right, allocator)
		node.right = nil
	}
	free(node, allocator)
}

// split_tree_layout calculates physical screen rectangles for every node in the tree.
split_tree_layout :: proc(node: ^Split_Node, target_rect: [4]f32) {
	if node == nil do return
	node.rect = target_rect

	if node.kind == .Leaf do return

	x := target_rect[0]
	y := target_rect[1]
	w := target_rect[2]
	h := target_rect[3]
	ratio := clamp(node.ratio, 0.05, 0.95)

	if node.kind == .Horizontal {
		split_w := w * ratio
		if node.left != nil {
			split_tree_layout(node.left, {x, y, split_w, h})
		}
		if node.right != nil {
			split_tree_layout(node.right, {x + split_w, y, w - split_w, h})
		}
	} else if node.kind == .Vertical {
		split_h := h * ratio
		if node.left != nil {
			split_tree_layout(node.left, {x, y, w, split_h})
		}
		if node.right != nil {
			split_tree_layout(node.right, {x, y + split_h, w, h - split_h})
		}
	}
}

// split_tree_emit_dividers recursively emits partition lines into dl.
split_tree_emit_dividers :: proc(
	node: ^Split_Node,
	dl: ^draw_list.Ui_Draw_List,
	divider_thickness: f32 = 1.0,
	color: [4]f32 = {0.25, 0.26, 0.28, 1.0},
) {
	if node == nil || dl == nil || node.kind == .Leaf do return

	x := node.rect[0]
	y := node.rect[1]
	w := node.rect[2]
	h := node.rect[3]
	ratio := clamp(node.ratio, 0.05, 0.95)

	if node.kind == .Horizontal {
		split_x := x + w * ratio - divider_thickness * 0.5
		divider_rect: [4]f32 = {split_x, y, divider_thickness, h}
		draw_list.ui_draw_rect(dl, divider_rect, color)
	} else if node.kind == .Vertical {
		split_y := y + h * ratio - divider_thickness * 0.5
		divider_rect: [4]f32 = {x, split_y, w, divider_thickness}
		draw_list.ui_draw_rect(dl, divider_rect, color)
	}

	if node.left != nil {
		split_tree_emit_dividers(node.left, dl, divider_thickness, color)
	}
	if node.right != nil {
		split_tree_emit_dividers(node.right, dl, divider_thickness, color)
	}
}

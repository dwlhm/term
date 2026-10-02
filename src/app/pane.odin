package main

import "core:math"
import platform_tabs "../platform/tabs"

// Pane_Id is a unique identifier for leaf panes.
Pane_Id :: u32

// Split_Direction indicates the orientation of a divider line:
// Vertical divides width (left and right children).
// Horizontal divides height (top and bottom children).
Split_Direction :: enum u8 {
	Vertical,
	Horizontal,
}

// Pane_Node_Kind distinguishes split branch nodes from terminal leaf nodes.
Pane_Node_Kind :: enum u8 {
	Split,
	Leaf,
}

// Layout and sizing constants.
MAX_PANE_NODES :: 32
MIN_COLS :: 10
MIN_ROWS :: 2
DIVIDER_SIZE :: 1.0
DIVIDER_HIT_SIZE :: 6.0
MIN_RATIO :: 0.1
MAX_RATIO :: 0.9
DEFAULT_RATIO :: 0.5

// Pane_Node represents either an interactive Leaf pane or an internal Split divider.
Pane_Node :: struct {
	kind:      Pane_Node_Kind,
	parent:    ^Pane_Node,
	rect:      platform_tabs.Rect_f32,
	direction: Split_Direction, // for Split node
	ratio:     f32,             // default 0.5, clamped to [0.1, 0.9]
	first:     ^Pane_Node,      // for Split node (left or top)
	second:    ^Pane_Node,      // for Split node (right or bottom)
	id:        Pane_Id,         // for Leaf node
	backend:   ^Backend,
	has_bell:  bool,
	rows:            int,
	cols:            int,
	dispatched_rows: int,
	dispatched_cols: int,
}

// Pane_Tree coordinates the binary split hierarchy, layout computation,
// focus state, and divider dragging with steady-state zero allocation.
Pane_Tree :: struct {
	root:             ^Pane_Node,
	focused_pane_id:  Pane_Id,
	zoomed_pane_id:   Pane_Id,
	next_pane_id:     Pane_Id,
	divider_hover:    ^Pane_Node,
	divider_dragging: bool,
	drag_start_ratio: f32,
	drag_start_pos:   f32,
	nodes:            [MAX_PANE_NODES]Pane_Node,
	node_count:       int,
	node_in_use:      [MAX_PANE_NODES]bool,
}

// _pane_tree_alloc_node acquires an unused node slot from the fixed pool.
_pane_tree_alloc_node :: proc(tree: ^Pane_Tree) -> ^Pane_Node {
	for i in 0..<MAX_PANE_NODES {
		if !tree.node_in_use[i] {
			tree.node_in_use[i] = true
			tree.node_count += 1
			node := &tree.nodes[i]
			node^ = {}
			return node
		}
	}
	return nil
}

// _pane_tree_free_node releases a node slot back to the fixed pool.
_pane_tree_free_node :: proc(tree: ^Pane_Tree, node: ^Pane_Node) {
	if tree == nil || node == nil do return
	base_ptr := uintptr(&tree.nodes[0])
	node_ptr := uintptr(node)
	elem_size := size_of(Pane_Node)
	if node_ptr < base_ptr do return
	offset := node_ptr - base_ptr
	if offset % uintptr(elem_size) != 0 do return
	idx := int(offset / uintptr(elem_size))
	if idx >= 0 && idx < MAX_PANE_NODES {
		if tree.node_in_use[idx] {
			tree.node_in_use[idx] = false
			tree.node_count -= 1
		}
		node^ = {}
	}
}

// pane_tree_init resets the tree and provisions the root leaf pane.
pane_tree_init :: proc(tree: ^Pane_Tree, root_backend: ^Backend) -> Pane_Id {
	if tree == nil do return 0
	tree.root = nil
	tree.focused_pane_id = 0
	tree.zoomed_pane_id = 0
	tree.next_pane_id = 1
	tree.divider_hover = nil
	tree.divider_dragging = false
	tree.drag_start_ratio = DEFAULT_RATIO
	tree.drag_start_pos = 0
	tree.node_count = 0
	tree.nodes = {}
	tree.node_in_use = {}

	root := _pane_tree_alloc_node(tree)
	if root == nil do return 0

	root_id := tree.next_pane_id
	tree.next_pane_id += 1

	root.kind = .Leaf
	root.id = root_id
	root.backend = root_backend
	root.ratio = DEFAULT_RATIO
	root.parent = nil
	root.first = nil
	root.second = nil
	root.has_bell = false
	root.rect = platform_tabs.Rect_f32{}

	tree.root = root
	tree.focused_pane_id = root_id
	return root_id
}

// pane_tree_destroy zeroes out the tree and pool.
pane_tree_destroy :: proc(tree: ^Pane_Tree) {
	if tree == nil do return
	tree.root = nil
	tree.focused_pane_id = 0
	tree.zoomed_pane_id = 0
	tree.next_pane_id = 1
	tree.divider_hover = nil
	tree.divider_dragging = false
	tree.drag_start_ratio = DEFAULT_RATIO
	tree.drag_start_pos = 0
	tree.node_count = 0
	tree.nodes = {}
	tree.node_in_use = {}
}

// _pane_node_find recursively locates a leaf node by Pane_Id.
_pane_node_find :: proc(node: ^Pane_Node, id: Pane_Id) -> ^Pane_Node {
	if node == nil do return nil
	if node.kind == .Leaf {
		if node.id == id do return node
		return nil
	}
	if found := _pane_node_find(node.first, id); found != nil {
		return found
	}
	return _pane_node_find(node.second, id)
}

// pane_tree_find_pane returns the leaf node matching the specified id, or nil.
pane_tree_find_pane :: proc(tree: ^Pane_Tree, id: Pane_Id) -> ^Pane_Node {
	if tree == nil || tree.root == nil || id == 0 do return nil
	return _pane_node_find(tree.root, id)
}

// pane_tree_split splits target_id into two panes along dir.
// Rejects split if minimum dimensions cannot be satisfied or if node pool is full.
pane_tree_split :: proc(
	tree: ^Pane_Tree,
	target_id: Pane_Id,
	dir: Split_Direction,
	new_backend: ^Backend,
) -> (Pane_Id, bool) {
	if tree == nil || tree.root == nil || target_id == 0 do return 0, false

	target := pane_tree_find_pane(tree, target_id)
	if target == nil || target.kind != .Leaf do return 0, false

	if tree.node_count + 2 > len(tree.nodes) do return 0, false

	min_w := f32(MIN_COLS * APP_CELL_W)
	min_h := f32(MIN_ROWS * APP_CELL_H)

	// Verify pixel dimensions if layout has been computed
	if target.rect.w > 0 || target.rect.h > 0 {
		switch dir {
		case .Vertical:
			if target.rect.w < (min_w * 2.0 + DIVIDER_SIZE) || target.rect.h < min_h {
				return 0, false
			}
		case .Horizontal:
			if target.rect.h < (min_h * 2.0 + DIVIDER_SIZE) || target.rect.w < min_w {
				return 0, false
			}
		}
	}

	// Verify logical row and column minimums if assigned
	if target.cols > 0 && dir == .Vertical && target.cols < MIN_COLS * 2 {
		return 0, false
	}
	if target.rows > 0 && dir == .Horizontal && target.rows < MIN_ROWS * 2 {
		return 0, false
	}

	first_child := _pane_tree_alloc_node(tree)
	second_child := _pane_tree_alloc_node(tree)
	if first_child == nil || second_child == nil {
		if first_child != nil do _pane_tree_free_node(tree, first_child)
		if second_child != nil do _pane_tree_free_node(tree, second_child)
		return 0, false
	}

	// Copy existing target leaf data to first child
	first_child.kind = .Leaf
	first_child.parent = target
	first_child.id = target.id
	first_child.backend = target.backend
	first_child.has_bell = target.has_bell
	first_child.rect = target.rect
	first_child.rows = target.rows
	first_child.cols = target.cols
	first_child.dispatched_rows = target.dispatched_rows
	first_child.dispatched_cols = target.dispatched_cols
	first_child.ratio = DEFAULT_RATIO

	// Initialize new pane leaf
	new_id := tree.next_pane_id
	tree.next_pane_id += 1

	second_child.kind = .Leaf
	second_child.parent = target
	second_child.id = new_id
	second_child.backend = new_backend
	second_child.has_bell = false
	second_child.ratio = DEFAULT_RATIO

	// Target becomes Split node in-place
	target.kind = .Split
	target.direction = dir
	target.ratio = DEFAULT_RATIO
	target.first = first_child
	target.second = second_child
	target.id = 0
	target.backend = nil
	target.has_bell = false

	tree.focused_pane_id = new_id
	return new_id, true
}

// _pane_find_first_leaf locates the first leaf in depth-first order under node.
_pane_find_first_leaf :: proc(node: ^Pane_Node) -> ^Pane_Node {
	if node == nil do return nil
	if node.kind == .Leaf do return node
	if first := _pane_find_first_leaf(node.first); first != nil do return first
	return _pane_find_first_leaf(node.second)
}

// pane_tree_close removes target_id from tree and collapses parent split to sibling.
// Returns closed_last = true if the closed pane was the final pane in the tree.
pane_tree_close :: proc(tree: ^Pane_Tree, target_id: Pane_Id) -> (closed_last: bool) {
	if tree == nil || tree.root == nil || target_id == 0 do return false

	target := pane_tree_find_pane(tree, target_id)
	if target == nil || target.kind != .Leaf do return false

	if target == tree.root {
		_pane_tree_free_node(tree, target)
		tree.root = nil
		tree.focused_pane_id = 0
		tree.zoomed_pane_id = 0
		tree.divider_hover = nil
		tree.divider_dragging = false
		return true
	}

	parent := target.parent
	if parent == nil || parent.kind != .Split do return false

	sibling: ^Pane_Node = (parent.first == target) ? parent.second : parent.first
	if sibling == nil do return false

	grandparent := parent.parent
	if grandparent == nil {
		tree.root = sibling
		sibling.parent = nil
	} else {
		sibling.parent = grandparent
		if grandparent.first == parent {
			grandparent.first = sibling
		} else {
			grandparent.second = sibling
		}
	}

	if tree.divider_hover == parent {
		tree.divider_hover = nil
		tree.divider_dragging = false
	}

	if tree.focused_pane_id == target_id {
		if first_leaf := _pane_find_first_leaf(sibling); first_leaf != nil {
			tree.focused_pane_id = first_leaf.id
		} else {
			tree.focused_pane_id = 0
		}
	}

	if tree.zoomed_pane_id == target_id {
		tree.zoomed_pane_id = 0
	}

	_pane_tree_free_node(tree, target)
	_pane_tree_free_node(tree, parent)

	return false
}

// _pane_clear_rects_except zeroes out rects of all nodes except keep.
_pane_clear_rects_except :: proc(node: ^Pane_Node, keep: ^Pane_Node) {
	if node == nil do return
	if node != keep {
		node.rect = platform_tabs.Rect_f32{}
	}
	if node.kind == .Split {
		_pane_clear_rects_except(node.first, keep)
		_pane_clear_rects_except(node.second, keep)
	}
}

// _pane_update_leaf_dimensions computes rows and cols enforcing MIN_COLS and MIN_ROWS.
_pane_update_leaf_dimensions :: proc(leaf: ^Pane_Node, cell_w, cell_h, pad_x, pad_y: f32) {
	if leaf == nil || leaf.rect.w <= 0 || leaf.rect.h <= 0 do return
	avail_w := leaf.rect.w - 2.0 * pad_x
	avail_h := leaf.rect.h - 2.0 * pad_y
	if avail_w < 0 do avail_w = 0
	if avail_h < 0 do avail_h = 0

	cols := int(avail_w / cell_w)
	rows := int(avail_h / cell_h)
	if cols < MIN_COLS do cols = MIN_COLS
	if rows < MIN_ROWS do rows = MIN_ROWS

	leaf.cols = cols
	leaf.rows = rows

}

// _pane_layout_node recursively positions children and computes cell dimensions.
_pane_layout_node :: proc(node: ^Pane_Node, cell_w, cell_h, pad_x, pad_y: f32) {
	if node == nil do return

	if node.kind == .Leaf {
		_pane_update_leaf_dimensions(node, cell_w, cell_h, pad_x, pad_y)
		return
	}

	ratio := math.clamp(node.ratio, MIN_RATIO, MAX_RATIO)
	switch node.direction {
	case .Vertical:
		avail_w := node.rect.w - DIVIDER_SIZE
		if avail_w < 0 do avail_w = 0
		first_w := math.floor(avail_w * ratio)
		second_w := max(f32(0), avail_w - first_w)

		if node.first != nil {
			node.first.rect = platform_tabs.Rect_f32{
				x = node.rect.x,
				y = node.rect.y,
				w = first_w,
				h = node.rect.h,
			}
			_pane_layout_node(node.first, cell_w, cell_h, pad_x, pad_y)
		}
		if node.second != nil {
			node.second.rect = platform_tabs.Rect_f32{
				x = node.rect.x + first_w + DIVIDER_SIZE,
				y = node.rect.y,
				w = second_w,
				h = node.rect.h,
			}
			_pane_layout_node(node.second, cell_w, cell_h, pad_x, pad_y)
		}

	case .Horizontal:
		avail_h := node.rect.h - DIVIDER_SIZE
		if avail_h < 0 do avail_h = 0
		first_h := math.floor(avail_h * ratio)
		second_h := max(f32(0), avail_h - first_h)

		if node.first != nil {
			node.first.rect = platform_tabs.Rect_f32{
				x = node.rect.x,
				y = node.rect.y,
				w = node.rect.w,
				h = first_h,
			}
			_pane_layout_node(node.first, cell_w, cell_h, pad_x, pad_y)
		}
		if node.second != nil {
			node.second.rect = platform_tabs.Rect_f32{
				x = node.rect.x,
				y = node.rect.y + first_h + DIVIDER_SIZE,
				w = node.rect.w,
				h = second_h,
			}
			_pane_layout_node(node.second, cell_w, cell_h, pad_x, pad_y)
		}
	}
}

// pane_tree_layout recursively calculates leaf node rects, rows, and cols.
pane_tree_layout :: proc(
	tree: ^Pane_Tree,
	content_rect: platform_tabs.Rect_f32,
	cell_w, cell_h, pad_x, pad_y: f32,
) {
	if tree == nil || tree.root == nil do return

	cw := cell_w > 0 ? cell_w : f32(APP_CELL_W)
	ch := cell_h > 0 ? cell_h : f32(APP_CELL_H)

	if tree.zoomed_pane_id != 0 {
		zoomed := pane_tree_find_pane(tree, tree.zoomed_pane_id)
		if zoomed != nil {
			zoomed.rect = content_rect
			_pane_update_leaf_dimensions(zoomed, cw, ch, pad_x, pad_y)
			_pane_clear_rects_except(tree.root, zoomed)
			return
		}
	}

	tree.root.rect = content_rect
	_pane_layout_node(tree.root, cw, ch, pad_x, pad_y)
}

// _pane_hit_test_divider checks 6px invisible hit area around dividers recursively.
_pane_hit_test_divider :: proc(node: ^Pane_Node, px, py: f32) -> ^Pane_Node {
	if node == nil || node.kind == .Leaf do return nil

	hit_rect: platform_tabs.Rect_f32
	switch node.direction {
	case .Vertical:
		if node.first != nil {
			div_x := node.first.rect.x + node.first.rect.w + DIVIDER_SIZE * 0.5
			hit_rect = platform_tabs.Rect_f32{
				x = div_x - DIVIDER_HIT_SIZE * 0.5,
				y = node.rect.y,
				w = DIVIDER_HIT_SIZE,
				h = node.rect.h,
			}
		}
	case .Horizontal:
		if node.first != nil {
			div_y := node.first.rect.y + node.first.rect.h + DIVIDER_SIZE * 0.5
			hit_rect = platform_tabs.Rect_f32{
				x = node.rect.x,
				y = div_y - DIVIDER_HIT_SIZE * 0.5,
				w = node.rect.w,
				h = DIVIDER_HIT_SIZE,
			}
		}
	}

	if platform_tabs.point_in_rect(px, py, hit_rect) {
		return node
	}

	if d := _pane_hit_test_divider(node.first, px, py); d != nil do return d
	return _pane_hit_test_divider(node.second, px, py)
}

// _pane_hit_test_leaf checks which leaf contains the specified coordinate.
_pane_hit_test_leaf :: proc(node: ^Pane_Node, px, py: f32) -> ^Pane_Node {
	if node == nil do return nil
	if node.kind == .Leaf {
		if platform_tabs.point_in_rect(px, py, node.rect) {
			return node
		}
		return nil
	}
	if l := _pane_hit_test_leaf(node.first, px, py); l != nil do return l
	return _pane_hit_test_leaf(node.second, px, py)
}

// pane_tree_hit_test performs hit detection prioritizing 6px divider zones before leaves.
pane_tree_hit_test :: proc(tree: ^Pane_Tree, px, py: f32) -> (leaf: ^Pane_Node, divider: ^Pane_Node) {
	if tree == nil || tree.root == nil do return nil, nil

	if tree.zoomed_pane_id != 0 {
		zoomed := pane_tree_find_pane(tree, tree.zoomed_pane_id)
		if zoomed != nil && platform_tabs.point_in_rect(px, py, zoomed.rect) {
			return zoomed, nil
		}
		return nil, nil
	}

	divider = _pane_hit_test_divider(tree.root, px, py)
	if divider != nil do return nil, divider

	leaf = _pane_hit_test_leaf(tree.root, px, py)
	return leaf, nil
}

// pane_tree_resize_active finds the closest ancestor Split matching dir and adjusts ratio.
pane_tree_resize_active :: proc(tree: ^Pane_Tree, dir: Split_Direction, delta_ratio: f32) -> bool {
	if tree == nil || tree.root == nil || tree.focused_pane_id == 0 do return false
	focused := pane_tree_find_pane(tree, tree.focused_pane_id)
	if focused == nil do return false

	curr := focused.parent
	target_split: ^Pane_Node = nil
	for curr != nil {
		if curr.kind == .Split && curr.direction == dir {
			target_split = curr
			break
		}
		curr = curr.parent
	}
	if target_split == nil do return false

	new_ratio := math.clamp(target_split.ratio + delta_ratio, MIN_RATIO, MAX_RATIO)

	min_w := f32(MIN_COLS * APP_CELL_W)
	min_h := f32(MIN_ROWS * APP_CELL_H)
	if target_split.direction == .Vertical && target_split.rect.w > 0 {
		avail_w := target_split.rect.w - DIVIDER_SIZE
		if avail_w > 0 {
			min_r := min_w / avail_w
			max_r := 1.0 - (min_w / avail_w)
			if min_r < max_r {
				new_ratio = math.clamp(new_ratio, min_r, max_r)
			}
		}
	} else if target_split.direction == .Horizontal && target_split.rect.h > 0 {
		avail_h := target_split.rect.h - DIVIDER_SIZE
		if avail_h > 0 {
			min_r := min_h / avail_h
			max_r := 1.0 - (min_h / avail_h)
			if min_r < max_r {
				new_ratio = math.clamp(new_ratio, min_r, max_r)
			}
		}
	}

	if new_ratio == target_split.ratio do return false
	target_split.ratio = new_ratio
	return true
}

// _pane_node_equalize sets all Split nodes' ratio to 0.5.
_pane_node_equalize :: proc(node: ^Pane_Node) -> bool {
	if node == nil || node.kind == .Leaf do return false
	changed := false
	if node.ratio != DEFAULT_RATIO {
		node.ratio = DEFAULT_RATIO
		changed = true
	}
	c1 := _pane_node_equalize(node.first)
	c2 := _pane_node_equalize(node.second)
	return changed || c1 || c2
}

// pane_tree_equalize sets all Split nodes' ratio to 0.5.
pane_tree_equalize :: proc(tree: ^Pane_Tree) -> bool {
	if tree == nil || tree.root == nil do return false
	return _pane_node_equalize(tree.root)
}

// _pane_find_best_leaf finds the leaf in subtree geometrically closest to src_rect.
_pane_find_best_leaf :: proc(node: ^Pane_Node, src_rect: platform_tabs.Rect_f32) -> ^Pane_Node {
	if node == nil do return nil
	if node.kind == .Leaf do return node

	first_leaf := _pane_find_best_leaf(node.first, src_rect)
	second_leaf := _pane_find_best_leaf(node.second, src_rect)
	if first_leaf == nil do return second_leaf
	if second_leaf == nil do return first_leaf

	src_cx := src_rect.x + src_rect.w * 0.5
	src_cy := src_rect.y + src_rect.h * 0.5

	f_cx := first_leaf.rect.x + first_leaf.rect.w * 0.5
	f_cy := first_leaf.rect.y + first_leaf.rect.h * 0.5
	s_cx := second_leaf.rect.x + second_leaf.rect.w * 0.5
	s_cy := second_leaf.rect.y + second_leaf.rect.h * 0.5

	dist_f := (f_cx - src_cx) * (f_cx - src_cx) + (f_cy - src_cy) * (f_cy - src_cy)
	dist_s := (s_cx - src_cx) * (s_cx - src_cx) + (s_cy - src_cy) * (s_cy - src_cy)

	if dist_f <= dist_s do return first_leaf
	return second_leaf
}

// pane_tree_navigate_spatially switches focused_pane_id across splits in dir.
pane_tree_navigate_spatially :: proc(tree: ^Pane_Tree, dir: Split_Direction, forward: bool) -> bool {
	if tree == nil || tree.root == nil || tree.focused_pane_id == 0 do return false
	curr_leaf := pane_tree_find_pane(tree, tree.focused_pane_id)
	if curr_leaf == nil do return false

	curr := curr_leaf
	target_subtree: ^Pane_Node = nil

	for curr.parent != nil {
		p := curr.parent
		if p.kind == .Split && p.direction == dir {
			if forward && p.first == curr {
				target_subtree = p.second
				break
			} else if !forward && p.second == curr {
				target_subtree = p.first
				break
			}
		}
		curr = p
	}

	if target_subtree == nil do return false

	best_leaf := _pane_find_best_leaf(target_subtree, curr_leaf.rect)
	if best_leaf == nil do return false

	tree.focused_pane_id = best_leaf.id
	return true
}

// _pane_collect_leaves gathers all leaves in depth-first traversal order.
_pane_collect_leaves :: proc(node: ^Pane_Node, out: ^[MAX_PANE_NODES]^Pane_Node, count: ^int) {
	if node == nil do return
	if node.kind == .Leaf {
		if count^ < MAX_PANE_NODES {
			out[count^] = node
			count^ += 1
		}
		return
	}
	_pane_collect_leaves(node.first, out, count)
	_pane_collect_leaves(node.second, out, count)
}

// pane_tree_cycle_focus cycles focused_pane_id across leaves in Z-order.
pane_tree_cycle_focus :: proc(tree: ^Pane_Tree, forward: bool) -> bool {
	if tree == nil || tree.root == nil do return false
	leaves: [MAX_PANE_NODES]^Pane_Node
	count := 0
	_pane_collect_leaves(tree.root, &leaves, &count)
	if count == 0 do return false
	if count == 1 {
		tree.focused_pane_id = leaves[0].id
		return true
	}

	curr_idx := 0
	for i in 0..<count {
		if leaves[i].id == tree.focused_pane_id {
			curr_idx = i
			break
		}
	}

	next_idx := 0
	if forward {
		next_idx = (curr_idx + 1) % count
	} else {
		next_idx = (curr_idx - 1 + count) % count
	}

	tree.focused_pane_id = leaves[next_idx].id
	return true
}

// pane_tree_toggle_zoom toggles fullscreen zoom for pane_id.
pane_tree_toggle_zoom :: proc(tree: ^Pane_Tree, pane_id: Pane_Id) {
	if tree == nil do return
	if tree.zoomed_pane_id == pane_id || pane_id == 0 {
		tree.zoomed_pane_id = 0
	} else {
		if pane_tree_find_pane(tree, pane_id) != nil {
			tree.zoomed_pane_id = pane_id
		}
	}
}

// pane_tree_divider_drag_begin initiates interactive divider dragging.
pane_tree_divider_drag_begin :: proc(tree: ^Pane_Tree, divider: ^Pane_Node, pos: f32) {
	if tree == nil || divider == nil || divider.kind != .Split do return
	tree.divider_dragging = true
	tree.divider_hover = divider
	tree.drag_start_ratio = divider.ratio
	tree.drag_start_pos = pos
}

// pane_tree_divider_drag_update updates the dragged divider ratio respecting constraints.
pane_tree_divider_drag_update :: proc(tree: ^Pane_Tree, current_pos: f32) -> bool {
	if tree == nil || !tree.divider_dragging || tree.divider_hover == nil do return false
	divider := tree.divider_hover
	if divider.kind != .Split do return false

	delta_pos := current_pos - tree.drag_start_pos
	total_span: f32 = 0
	switch divider.direction {
	case .Vertical:
		total_span = divider.rect.w - DIVIDER_SIZE
	case .Horizontal:
		total_span = divider.rect.h - DIVIDER_SIZE
	}
	if total_span <= 0 do return false

	delta_ratio := delta_pos / total_span
	new_ratio := math.clamp(tree.drag_start_ratio + delta_ratio, MIN_RATIO, MAX_RATIO)

	min_w := f32(MIN_COLS * APP_CELL_W)
	min_h := f32(MIN_ROWS * APP_CELL_H)
	if divider.direction == .Vertical && divider.rect.w > 0 {
		min_r := min_w / total_span
		max_r := 1.0 - (min_w / total_span)
		if min_r < max_r {
			new_ratio = math.clamp(new_ratio, min_r, max_r)
		}
	} else if divider.direction == .Horizontal && divider.rect.h > 0 {
		min_r := min_h / total_span
		max_r := 1.0 - (min_h / total_span)
		if min_r < max_r {
			new_ratio = math.clamp(new_ratio, min_r, max_r)
		}
	}

	if new_ratio == divider.ratio do return false
	divider.ratio = new_ratio
	return true
}

// pane_tree_divider_drag_end terminates interactive divider dragging.
pane_tree_divider_drag_end :: proc(tree: ^Pane_Tree) {
	if tree == nil do return
	tree.divider_dragging = false
}

package hit_test

// Pure Declarative UI Geometry Engine - Spatial Hit-Testing Engine.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Classifies pointer interactions across tabs, close buttons, split dividers, and panes.

import "../tabs"
import "../splits"
import cursor "../../cursor"

// Hit_Kind classifies the UI target under the cursor.
Hit_Kind :: enum {
	None,
	Tab_Header,
	Tab_Close,
	Split_Divider,
	Pane,
	Modal,
}

// Hit_Result records the hit test outcome.
Hit_Result :: struct {
	kind:       Hit_Kind,
	index:      int,
	pane_id:    u32,
	rect:       [4]f32,
	split_node: ^splits.Split_Node,
}

// point_in_rect checks if a 2D point lies within [x, y, w, h].
point_in_rect :: proc(pt: [2]f32, rect: [4]f32) -> bool {
	return pt.x >= rect[0] && pt.x <= (rect[0] + rect[2]) &&
	       pt.y >= rect[1] && pt.y <= (rect[1] + rect[3])
}

// _hit_test_splits recursively checks for divider hits or leaf pane hits.
_hit_test_splits :: proc(node: ^splits.Split_Node, pt: [2]f32, divider_tolerance: f32 = 4.0) -> Hit_Result {
	if node == nil do return {kind = .None}

	if !point_in_rect(pt, node.rect) do return {kind = .None}

	if node.kind == .Leaf {
		return Hit_Result{
			kind       = .Pane,
			pane_id    = node.pane_id,
			rect       = node.rect,
			split_node = node,
		}
	}

	// 1. Check if children have internal divider hits first
	if node.left != nil && point_in_rect(pt, node.left.rect) {
		res := _hit_test_splits(node.left, pt, divider_tolerance)
		if res.kind == .Split_Divider do return res
	}
	if node.right != nil && point_in_rect(pt, node.right.rect) {
		res := _hit_test_splits(node.right, pt, divider_tolerance)
		if res.kind == .Split_Divider do return res
	}

	// 2. Check if cursor is on this node's split boundary
	ratio := splits.split_effective_ratio(node)
	if node.kind == .Horizontal {
		min_x := node.rect[0] + node.rect[2] * ratio
		max_x := min_x
		if node.left != nil && node.right != nil {
			min_x = node.left.rect[0] + node.left.rect[2]
			max_x = node.right.rect[0]
		}
		if pt.x >= (min_x - divider_tolerance) && pt.x <= (max_x + divider_tolerance) {
			div_w := max(max_x - min_x, 1.0)
			return Hit_Result{
				kind       = .Split_Divider,
				rect       = {min_x - divider_tolerance, node.rect[1], div_w + divider_tolerance * 2.0, node.rect[3]},
				split_node = node,
			}
		}
	} else if node.kind == .Vertical {
		min_y := node.rect[1] + node.rect[3] * ratio
		max_y := min_y
		if node.left != nil && node.right != nil {
			min_y = node.left.rect[1] + node.left.rect[3]
			max_y = node.right.rect[1]
		}
		if pt.y >= (min_y - divider_tolerance) && pt.y <= (max_y + divider_tolerance) {
			div_h := max(max_y - min_y, 1.0)
			return Hit_Result{
				kind       = .Split_Divider,
				rect       = {node.rect[0], min_y - divider_tolerance, node.rect[2], div_h + divider_tolerance * 2.0},
				split_node = node,
			}
		}
	}

	// 3. Fall through to child panes
	if node.left != nil && point_in_rect(pt, node.left.rect) {
		res := _hit_test_splits(node.left, pt, divider_tolerance)
		if res.kind != .None do return res
	}
	if node.right != nil && point_in_rect(pt, node.right.rect) {
		res := _hit_test_splits(node.right, pt, divider_tolerance)
		if res.kind != .None do return res
	}

	return {kind = .None}
}

// chrome_hit_test determines what element is hovered or clicked by point pt.
chrome_hit_test :: proc(t: ^tabs.Chrome_Tabs_Model, s: ^splits.Split_Node, pt: [2]f32) -> Hit_Result {
	// 1. Check tabs
	if t != nil && point_in_rect(pt, t.bar_rect) {
		for i in 0..<len(t.tabs) {
			tab := &t.tabs[i]
			if point_in_rect(pt, tab.close_rect) {
				return Hit_Result{
					kind  = .Tab_Close,
					index = i,
					rect  = tab.close_rect,
				}
			}
			if point_in_rect(pt, tab.rect) {
				return Hit_Result{
					kind  = .Tab_Header,
					index = i,
					rect  = tab.rect,
				}
			}
		}
	}

	// 2. Check split panes and dividers
	if s != nil {
		res := _hit_test_splits(s, pt)
		if res.kind != .None do return res
	}

	return {kind = .None}
}

// chrome_hit_cursor maps a Hit_Result into an autonomous platform-neutral Mouse_Cursor shape.
chrome_hit_cursor :: proc(hit: Hit_Result) -> (cursor_shape: cursor.Mouse_Cursor, handled: bool) {
	switch hit.kind {
	case .Tab_Header, .Tab_Close:
		return .Pointer, true
	case .Split_Divider:
		if hit.split_node != nil && hit.split_node.kind == .Vertical {
			return .Row_Resize, true
		}
		return .Col_Resize, true
	case .Modal:
		return .Default, true
	case .Pane, .None:
		return .Default, false
	}
	return .Default, false
}

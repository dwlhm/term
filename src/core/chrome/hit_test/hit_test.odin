package hit_test

// Pure Declarative UI Geometry Engine - Spatial Hit-Testing Engine.
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO GPU Dependencies.
// Classifies pointer interactions across tabs, close buttons, split dividers, and panes.

import "../tabs"
import "../splits"

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
	kind:    Hit_Kind,
	index:   int,
	pane_id: u32,
	rect:    [4]f32,
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
			kind    = .Pane,
			pane_id = node.pane_id,
			rect    = node.rect,
		}
	}

	// Check if cursor is on split boundary
	if node.kind == .Horizontal {
		split_x := node.rect[0] + node.rect[2] * node.ratio
		if pt.x >= (split_x - divider_tolerance) && pt.x <= (split_x + divider_tolerance) {
			return Hit_Result{
				kind = .Split_Divider,
				rect = {split_x - divider_tolerance, node.rect[1], divider_tolerance * 2.0, node.rect[3]},
			}
		}
	} else if node.kind == .Vertical {
		split_y := node.rect[1] + node.rect[3] * node.ratio
		if pt.y >= (split_y - divider_tolerance) && pt.y <= (split_y + divider_tolerance) {
			return Hit_Result{
				kind = .Split_Divider,
				rect = {node.rect[0], split_y - divider_tolerance, node.rect[2], divider_tolerance * 2.0},
			}
		}
	}

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

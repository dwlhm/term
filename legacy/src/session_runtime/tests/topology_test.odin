package session_runtime_test

import "core:testing"
import "core:math"
import rt "../"

_new :: proc(t: ^testing.T) -> rt.Workspace_Topology {
	w: rt.Workspace_Topology
	testing.expect_value(t, rt.topology_create_leaf(&w, 1, 1, 1), rt.Topology_Result.Applied)
	return w
}

@(test)
test_topology_capacity_and_transactional_rejections :: proc(t: ^testing.T) {
	w := _new(t)
	for i in 2..=16 {
		testing.expect_value(t, rt.topology_split(&w, 1, rt.Pane_ID(i), 1, .Vertical), rt.Topology_Result.Applied)
		testing.expect(t, rt.topology_validate(&w))
	}
	testing.expect_value(t, w.node_count, u8(31))
	before := w
	testing.expect_value(t, rt.topology_split(&w, 1, 17, 1, .Horizontal), rt.Topology_Result.Pool_Full)
	testing.expect(t, w == before)
	testing.expect_value(t, rt.topology_split(&w, 1, 2, 1, .Vertical), rt.Topology_Result.Duplicate_Pane)
	testing.expect_value(t, rt.topology_split(&w, 90, 19, 1, .Vertical), rt.Topology_Result.Missing_Pane)
	testing.expect_value(t, rt.topology_split(&w, 1, 0, 1, .Vertical), rt.Topology_Result.Invalid_Identity)
	testing.expect_value(t, rt.topology_split(&w, 1, 19, 0, .Vertical), rt.Topology_Result.Invalid_Identity)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, math.nan_f32()), rt.Topology_Result.Invalid_Ratio)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, math.inf_f32(1)), rt.Topology_Result.Invalid_Ratio)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, 0.09), rt.Topology_Result.Invalid_Ratio)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, 0.91), rt.Topology_Result.Invalid_Ratio)
	testing.expect(t, w == before)
	testing.expect_value(t, rt.topology_remove(&w, 16), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_split(&w, 1, 17, 2, .Horizontal), rt.Topology_Result.Applied)
	testing.expect(t, rt.topology_validate(&w))
}

@(test)
test_topology_nested_collapse_focus_zoom_and_empty :: proc(t: ^testing.T) {
	w := _new(t)
	testing.expect_value(t, rt.topology_split(&w, 1, 2, 2, .Vertical), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_split(&w, 2, 3, 3, .Horizontal), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_split(&w, 1, 4, 4, .Horizontal), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_zoom(&w, 3), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_focus(&w, 2), rt.Topology_Result.Applied)
	testing.expect_value(t, w.zoomed, rt.Pane_ID(2))
	testing.expect_value(t, rt.topology_remove(&w, 2), rt.Topology_Result.Applied)
	testing.expect_value(t, w.focused, rt.Pane_ID(3))
	testing.expect_value(t, w.zoomed, rt.Pane_ID(0))
	testing.expect(t, rt.topology_validate(&w))
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, rt.TOPOLOGY_MIN_RATIO), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, rt.TOPOLOGY_MAX_RATIO), rt.Topology_Result.Applied)
	testing.expect_value(t, rt.topology_remove(&w, 3), rt.Topology_Result.Applied)
	testing.expect_value(t, w.focused, rt.Pane_ID(1))
	testing.expect_value(t, rt.topology_remove(&w, 1), rt.Topology_Result.Applied)
	testing.expect_value(t, w.focused, rt.Pane_ID(4))
	revision := w.revision
	testing.expect_value(t, rt.topology_remove(&w, 4), rt.Topology_Result.Applied)
	testing.expect_value(t, w.revision, revision+1)
	testing.expect_value(t, w.workspace, rt.Workspace_ID(1))
	testing.expect_value(t, w.node_count, u8(0))
	testing.expect(t, rt.topology_validate(&w))
	testing.expect_value(t, rt.topology_create_leaf(&w, 1, 5, 5), rt.Topology_Result.Applied)
	testing.expect(t, rt.topology_validate(&w))
}

@(test)
test_topology_rejects_corrupt_descriptors_and_revision_wrap :: proc(t: ^testing.T) {
	good := _new(t)
	testing.expect_value(t, rt.topology_split(&good, 1, 2, 2, .Vertical), rt.Topology_Result.Applied)
	for variant in 0..<16 {
		w := good
		root := &w.nodes[int(w.root)-1]
		first := &w.nodes[int(root.first)-1]
		second := &w.nodes[int(root.second)-1]
		switch variant {
		case 0: w.workspace = 0
		case 1: w.root = 33
		case 2: root.parent = root.first
		case 3: root.first = w.root
		case 4: second.pane = first.pane
		case 5: first.incarnation = 0
		case 6: first.parent = 0
		case 7: w.nodes[31] = rt.Topology_Node{used = true, kind = .Leaf, pane = 3, incarnation = 3}; w.node_count += 1
		case 8: w.focused = 99
		case 9: w.zoomed = 99
		case 10: root.second = root.first
		case 11: root.ratio = math.nan_f32()
		case 12: root.orientation = rt.Orientation(2)
		case 13: w.node_count -= 1
		case 14: first.pane = 0
		case 15: root.used = false
		}
		testing.expect(t, !rt.topology_validate(&w))
		before := w
		testing.expect_value(t, rt.topology_remove(&w, 1), rt.Topology_Result.Invalid_Descriptor)
		// NaN is unequal to itself; compare the exact descriptor bytes instead.
		a := (cast(^[size_of(rt.Workspace_Topology)]u8)&before)^
		b := (cast(^[size_of(rt.Workspace_Topology)]u8)&w)^
		testing.expect(t, a == b)
	}
	w := good
	w.revision = rt.TOPOLOGY_REVISION_MAX
	before := w
	testing.expect_value(t, rt.topology_remove(&w, 1), rt.Topology_Result.Revision_Exhausted)
	testing.expect_value(t, rt.topology_focus(&w, 2), rt.Topology_Result.Revision_Exhausted)
	testing.expect_value(t, rt.topology_zoom(&w, 2), rt.Topology_Result.Revision_Exhausted)
	testing.expect_value(t, rt.topology_set_ratio(&w, w.root, 0.4), rt.Topology_Result.Revision_Exhausted)
	testing.expect_value(t, rt.topology_split(&w, 1, 3, 3, .Horizontal), rt.Topology_Result.Revision_Exhausted)
	testing.expect(t, w == before)
}

@(test)
test_topology_applied_revision_and_missing_targets :: proc(t: ^testing.T) {
	w := _new(t)
	testing.expect_value(t, w.revision, rt.Revision(1))
	before := w
	testing.expect_value(t, rt.topology_create_leaf(&w, 1, 2, 2), rt.Topology_Result.Not_Empty)
	testing.expect_value(t, rt.topology_focus(&w, 2), rt.Topology_Result.Missing_Pane)
	testing.expect_value(t, rt.topology_zoom(&w, 2), rt.Topology_Result.Missing_Pane)
	testing.expect_value(t, rt.topology_remove(&w, 2), rt.Topology_Result.Missing_Pane)
	testing.expect_value(t, rt.topology_split(&w, 1, 2, 2, rt.Orientation(2)), rt.Topology_Result.Invalid_Orientation)
	testing.expect(t, w == before)
	testing.expect_value(t, rt.topology_focus(&w, 1), rt.Topology_Result.Applied)
	testing.expect_value(t, w.revision, rt.Revision(2))
	testing.expect_value(t, rt.topology_zoom(&w, 0), rt.Topology_Result.Applied)
	testing.expect_value(t, w.revision, rt.Revision(3))
}

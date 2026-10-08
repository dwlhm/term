package session_runtime

import "core:math"

_topology_index_valid :: proc(i: Node_Index) -> bool {
	return i > 0 && int(i) <= TOPOLOGY_NODE_CAPACITY
}
_topology_ratio_valid :: proc(r: f32) -> bool {
	return !math.is_nan(r) && !math.is_inf(r) && r >= TOPOLOGY_MIN_RATIO && r <= TOPOLOGY_MAX_RATIO
}
_topology_orientation_valid :: proc(o: Orientation) -> bool {
	return o == .Vertical || o == .Horizontal
}

topology_find_pane :: proc(t: ^Workspace_Topology, pane: Pane_ID) -> Node_Index {
	if t == nil || pane == 0 do return 0
	for n, i in t.nodes {
		if n.used && n.kind == .Leaf && n.pane == pane do return Node_Index(i+1)
	}
	return 0
}

// Validate untrusted descriptors before traversing links or publishing a mutation.
topology_validate :: proc(t: ^Workspace_Topology) -> bool {
	if t == nil || t.workspace == 0 do return false
	used := 0
	for n, i in t.nodes {
		if !n.used do continue
		used += 1
		if n.kind == .Leaf {
			if n.pane == 0 || n.incarnation == 0 || n.first != 0 || n.second != 0 do return false
			for j in 0..<i {
				p := t.nodes[j]
				if p.used && p.kind == .Leaf && p.pane == n.pane do return false
			}
		} else if n.kind == .Split {
			if n.pane != 0 || n.incarnation != 0 || !_topology_ratio_valid(n.ratio) || !_topology_orientation_valid(n.orientation) do return false
			if !_topology_index_valid(n.first) || !_topology_index_valid(n.second) || n.first == n.second do return false
		} else {
			return false
		}
	}
	if used != int(t.node_count) do return false
	if used == 0 do return t.root == 0 && t.focused == 0 && t.zoomed == 0
	if !_topology_index_valid(t.root) || t.focused == 0 do return false
	if topology_find_pane(t, t.focused) == 0 || (t.zoomed != 0 && topology_find_pane(t, t.zoomed) == 0) do return false
	stack: [TOPOLOGY_NODE_CAPACITY]Node_Index
	parents: [TOPOLOGY_NODE_CAPACITY]Node_Index
	visited: [TOPOLOGY_NODE_CAPACITY]bool
	stack[0] = t.root
	pending, reached := 1, 0
	for pending > 0 {
		pending -= 1
		idx, expected_parent := stack[pending], parents[pending]
		if !_topology_index_valid(idx) do return false
		i := int(idx)-1
		n := t.nodes[i]
		if !n.used || visited[i] || n.parent != expected_parent do return false
		visited[i] = true
		reached += 1
		if n.kind == .Split {
			if pending+2 > len(stack) do return false
			stack[pending], parents[pending] = n.second, idx
			stack[pending+1], parents[pending+1] = n.first, idx
			pending += 2
		}
	}
	return reached == used
}

_topology_alloc :: proc(t: ^Workspace_Topology) -> Node_Index {
	for &n, i in t.nodes {
		if !n.used {
			n = Topology_Node{used = true}
			t.node_count += 1
			return Node_Index(i+1)
		}
	}
	return 0
}
_topology_free :: proc(t: ^Workspace_Topology, idx: Node_Index) {
	t.nodes[int(idx)-1] = {}
	t.node_count -= 1
}
_topology_commit :: proc(t: ^Workspace_Topology, next: Workspace_Topology) -> Topology_Result {
	candidate := next
	if !topology_validate(&candidate) do return .Invalid_Descriptor
	if t.revision == TOPOLOGY_REVISION_MAX do return .Revision_Exhausted
	candidate.revision = t.revision+1
	t^ = candidate
	return .Applied
}

topology_create_leaf :: proc(t: ^Workspace_Topology, workspace: Workspace_ID, pane: Pane_ID, incarnation: Pane_Incarnation) -> Topology_Result {
	if t == nil || workspace == 0 || pane == 0 || incarnation == 0 do return .Invalid_Identity
	if t.workspace == 0 {
		if t^ != (Workspace_Topology{}) do return .Invalid_Descriptor
	} else if !topology_validate(t) || t.workspace != workspace {
		return .Invalid_Descriptor
	}
	if t.node_count != 0 do return .Not_Empty
	next := t^
	next.workspace = workspace
	idx := _topology_alloc(&next)
	next.nodes[int(idx)-1] = Topology_Node{used = true, kind = .Leaf, pane = pane, incarnation = incarnation}
	next.root, next.focused = idx, pane
	return _topology_commit(t, next)
}

topology_split :: proc(t: ^Workspace_Topology, target, pane: Pane_ID, incarnation: Pane_Incarnation, orientation: Orientation) -> Topology_Result {
	if !topology_validate(t) do return .Invalid_Descriptor
	if pane == 0 || incarnation == 0 do return .Invalid_Identity
	if !_topology_orientation_valid(orientation) do return .Invalid_Orientation
	idx := topology_find_pane(t, target)
	if idx == 0 do return .Missing_Pane
	if topology_find_pane(t, pane) != 0 do return .Duplicate_Pane
	if int(t.node_count)+2 > TOPOLOGY_NODE_CAPACITY do return .Pool_Full
	next := t^
	first, second := _topology_alloc(&next), _topology_alloc(&next)
	original := next.nodes[int(idx)-1]
	parent := original.parent
	original.parent = idx
	next.nodes[int(first)-1] = original
	next.nodes[int(second)-1] = Topology_Node{used = true, kind = .Leaf, parent = idx, pane = pane, incarnation = incarnation}
	next.nodes[int(idx)-1] = Topology_Node{used = true, kind = .Split, parent = parent, first = first, second = second, orientation = orientation, ratio = TOPOLOGY_DEFAULT_RATIO}
	next.focused, next.zoomed = pane, 0
	return _topology_commit(t, next)
}

_topology_first_leaf :: proc(t: ^Workspace_Topology, idx: Node_Index) -> Pane_ID {
	current := idx
	for current != 0 {
		n := t.nodes[int(current)-1]
		if n.kind == .Leaf do return n.pane
		current = n.first
	}
	return 0
}

topology_remove :: proc(t: ^Workspace_Topology, pane: Pane_ID) -> Topology_Result {
	if !topology_validate(t) do return .Invalid_Descriptor
	idx := topology_find_pane(t, pane)
	if idx == 0 do return .Missing_Pane
	next := t^
	parent := next.nodes[int(idx)-1].parent
	if parent == 0 {
		_topology_free(&next, idx)
		next.root, next.focused, next.zoomed = 0, 0, 0
	} else {
		p := next.nodes[int(parent)-1]
		sibling := p.second if p.first == idx else p.first
		if p.parent == 0 {
			next.root = sibling
		} else {
			g := &next.nodes[int(p.parent)-1]
			if g.first == parent do g.first = sibling
			else do g.second = sibling
		}
		next.nodes[int(sibling)-1].parent = p.parent
		if next.focused == pane do next.focused = _topology_first_leaf(&next, sibling)
		if next.zoomed == pane do next.zoomed = 0
		_topology_free(&next, idx)
		_topology_free(&next, parent)
	}
	return _topology_commit(t, next)
}

topology_focus :: proc(t: ^Workspace_Topology, pane: Pane_ID) -> Topology_Result {
	if !topology_validate(t) do return .Invalid_Descriptor
	if topology_find_pane(t, pane) == 0 do return .Missing_Pane
	next := t^
	next.focused = pane
	if next.zoomed != 0 do next.zoomed = pane
	return _topology_commit(t, next)
}

topology_zoom :: proc(t: ^Workspace_Topology, pane: Pane_ID) -> Topology_Result {
	if !topology_validate(t) do return .Invalid_Descriptor
	if pane != 0 && topology_find_pane(t, pane) == 0 do return .Missing_Pane
	next := t^
	next.zoomed = pane
	return _topology_commit(t, next)
}

topology_set_ratio :: proc(t: ^Workspace_Topology, split: Node_Index, ratio: f32) -> Topology_Result {
	if !topology_validate(t) do return .Invalid_Descriptor
	if !_topology_ratio_valid(ratio) do return .Invalid_Ratio
	if !_topology_index_valid(split) || !t.nodes[int(split)-1].used || t.nodes[int(split)-1].kind != .Split do return .Invalid_Descriptor
	next := t^
	next.nodes[int(split)-1].ratio = ratio
	return _topology_commit(t, next)
}

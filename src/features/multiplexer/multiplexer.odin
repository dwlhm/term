package feature_multiplexer

// feature_multiplexer: Multi-pane focus routing, swap, layout operations, and pane lifecycle.
// Part of Tier 2 Feature Composition Layer.
//
// Zero horizontal coupling with other features.
// Supports both Terminal PTY panes and 3D Canvas panes as first-class citizens.

import "base:runtime"
import pty "../../platform/pty"
import chrome_splits "../../core/chrome/splits"
import session "../session"
import three_d "../../core/render/three_d"

Pane_Kind :: enum {
	Terminal,
	Three_D,
}

Pane_Entry :: struct {
	id:          u32,
	kind:        Pane_Kind,
	session:     ^session.Terminal_Session, // Nil if Three_D
	interactor:  three_d.Three_D_Interactor, // For 3D camera/orbit
	rect:        [4]f32,
	is_focused:  bool,
	is_zoomed:   bool,
	saved_rect:  [4]f32,
}

Multiplexer :: struct {
	panes:           [dynamic]Pane_Entry,
	focused_pane_id: u32,
	next_pane_id:    u32,
	zoomed_pane_id:  u32, // 0 if no pane zoomed
	allocator:       runtime.Allocator,
}

multiplexer_init :: proc(m: ^Multiplexer, allocator := context.allocator) {
	if m == nil do return
	m.allocator = allocator
	m.next_pane_id = 1
	m.focused_pane_id = 0
	m.zoomed_pane_id = 0
	m.panes = make([dynamic]Pane_Entry, allocator)
}

multiplexer_destroy :: proc(m: ^Multiplexer) {
	if m == nil do return
	for &p in m.panes {
		if p.session != nil {
			session.session_destroy(p.session)
			p.session = nil
		}
	}
	delete(m.panes)
	m.panes = nil
	m.focused_pane_id = 0
	m.zoomed_pane_id = 0
}

multiplexer_create_terminal_pane :: proc(m: ^Multiplexer, config: session.Session_Config) -> (pane_id: u32, err: pty.Pty_Error) {
	if m == nil do return 0, .Closed

	sess, s_err := session.session_create(config, m.allocator)
	if s_err != .None {
		return 0, s_err
	}

	pane_id = m.next_pane_id
	m.next_pane_id += 1

	p: Pane_Entry
	p.id = pane_id
	p.kind = .Terminal
	p.session = sess
	p.is_focused = (len(m.panes) == 0)
	p.is_zoomed = false

	append(&m.panes, p)
	if p.is_focused {
		m.focused_pane_id = pane_id
	}

	return pane_id, .None
}

multiplexer_create_3d_pane :: proc(m: ^Multiplexer) -> u32 {
	if m == nil do return 0

	pane_id := m.next_pane_id
	m.next_pane_id += 1

	p: Pane_Entry
	p.id = pane_id
	p.kind = .Three_D
	p.session = nil
	three_d.interactor_init(&p.interactor)
	p.is_focused = (len(m.panes) == 0)
	p.is_zoomed = false

	append(&m.panes, p)
	if p.is_focused {
		m.focused_pane_id = pane_id
	}

	return pane_id
}

multiplexer_close_pane :: proc(m: ^Multiplexer, pane_id: u32) -> bool {
	if m == nil do return false

	idx := -1
	for i in 0..<len(m.panes) {
		if m.panes[i].id == pane_id {
			idx = i
			break
		}
	}
	if idx < 0 do return false

	if m.panes[idx].session != nil {
		session.session_destroy(m.panes[idx].session)
		m.panes[idx].session = nil
	}

	ordered_remove(&m.panes, idx)

	if m.zoomed_pane_id == pane_id {
		m.zoomed_pane_id = 0
	}

	// Update focus if closed pane was focused
	if m.focused_pane_id == pane_id {
		if len(m.panes) > 0 {
			new_idx := min(idx, len(m.panes) - 1)
			m.focused_pane_id = m.panes[new_idx].id
			m.panes[new_idx].is_focused = true
		} else {
			m.focused_pane_id = 0
		}
	}

	return true
}

multiplexer_get_pane :: proc(m: ^Multiplexer, pane_id: u32) -> ^Pane_Entry {
	if m == nil do return nil
	for i in 0..<len(m.panes) {
		if m.panes[i].id == pane_id {
			return &m.panes[i]
		}
	}
	return nil
}

multiplexer_get_focused_pane :: proc(m: ^Multiplexer) -> ^Pane_Entry {
	if m == nil || m.focused_pane_id == 0 do return nil
	return multiplexer_get_pane(m, m.focused_pane_id)
}

multiplexer_focus_pane :: proc(m: ^Multiplexer, pane_id: u32) -> bool {
	if m == nil do return false
	found := false
	for i in 0..<len(m.panes) {
		if m.panes[i].id == pane_id {
			m.panes[i].is_focused = true
			found = true
		} else {
			m.panes[i].is_focused = false
		}
	}
	if found {
		m.focused_pane_id = pane_id
	}
	return found
}

multiplexer_cycle_focus :: proc(m: ^Multiplexer, forward: bool = true) -> u32 {
	if m == nil || len(m.panes) == 0 do return 0
	if len(m.panes) == 1 {
		multiplexer_focus_pane(m, m.panes[0].id)
		return m.panes[0].id
	}

	cur_idx := 0
	for i in 0..<len(m.panes) {
		if m.panes[i].id == m.focused_pane_id {
			cur_idx = i
			break
		}
	}

	next_idx: int
	if forward {
		next_idx = (cur_idx + 1) % len(m.panes)
	} else {
		next_idx = (cur_idx - 1 + len(m.panes)) % len(m.panes)
	}

	target_id := m.panes[next_idx].id
	multiplexer_focus_pane(m, target_id)
	return target_id
}

multiplexer_toggle_zoom :: proc(m: ^Multiplexer, pane_id: u32) -> bool {
	if m == nil do return false
	p := multiplexer_get_pane(m, pane_id)
	if p == nil do return false

	if m.zoomed_pane_id == pane_id {
		// Restore unzoomed
		m.zoomed_pane_id = 0
		p.is_zoomed = false
		return false
	} else {
		// Unzoom any currently zoomed pane
		if m.zoomed_pane_id != 0 {
			old_p := multiplexer_get_pane(m, m.zoomed_pane_id)
			if old_p != nil do old_p.is_zoomed = false
		}
		m.zoomed_pane_id = pane_id
		p.is_zoomed = true
		multiplexer_focus_pane(m, pane_id)
		return true
	}
}

multiplexer_drain_all :: proc(m: ^Multiplexer) -> int {
	if m == nil do return 0
	total_drained := 0
	for &p in m.panes {
		if p.session != nil {
			total_drained += session.session_drain(p.session)
		}
	}
	return total_drained
}

multiplexer_sync_split_rects :: proc(m: ^Multiplexer, root: ^chrome_splits.Split_Node) {
	if m == nil || root == nil do return

	_walk_splits(m, root)
}

_walk_splits :: proc(m: ^Multiplexer, node: ^chrome_splits.Split_Node) {
	if node == nil do return
	if node.kind == .Leaf {
		p := multiplexer_get_pane(m, node.pane_id)
		if p != nil {
			p.rect = node.rect
		}
		return
	}
	_walk_splits(m, node.left)
	_walk_splits(m, node.right)
}

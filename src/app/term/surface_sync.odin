package term

// Multi-Surface (OSC 8400) Native Split_Node & Pane_Entry Synchronizer.
// Part of Tier 3 Application Shell (src/app/term/*).

import chrome_splits "../../core/chrome/splits"
import core_terminal "../../core/terminal"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"

@(private = "file")
_find_parent_split :: proc(node: ^chrome_splits.Split_Node, pane_id: u32) -> ^chrome_splits.Split_Node {
	if node == nil || node.kind == .Leaf do return nil
	if (node.left != nil && node.left.kind == .Leaf && node.left.pane_id == pane_id) ||
	   (node.right != nil && node.right.kind == .Leaf && node.right.pane_id == pane_id) {
		return node
	}
	if l := _find_parent_split(node.left, pane_id); l != nil do return l
	return _find_parent_split(node.right, pane_id)
}

@(private = "file")
_sync_split_ratio :: proc(app: ^Term_App, parent: ^chrome_splits.Split_Node, s: ^core_terminal.Terminal_Surface) -> bool {
	if parent == nil || s == nil do return false
	inv := s.split_dir == .Right || s.split_dir == .Down
	if app.mouse.is_dragging_divider && app.mouse.drag_split_node == parent {
		raw_r := (1.0 - parent.ratio) if inv else parent.ratio
		pct := clamp(int(raw_r * 100.0 + 0.5), 10, 90)
		if s.split_ratio != pct {
			s.split_ratio = pct
			return true
		}
		return false
	}
	want := (1.0 - f32(s.split_ratio) / 100.0) if inv else (f32(s.split_ratio) / 100.0)
	want = clamp(want, 0.1, 0.9)
	if abs(parent.ratio - want) > 0.015 {
		parent.ratio = want
		return true
	}
	return false
}

@(private = "file")
_insert_surface_split_leaf :: proc(
	app: ^Term_App,
	split_tree: ^chrome_splits.Split_Node,
	sess: ^sess_feat.Terminal_Session,
	root_pid: u32,
	s: ^core_terminal.Terminal_Surface,
) -> bool {
	target_pid := root_pid
	if s.parent_id != 0 {
		if pp := mux_feat.multiplexer_find_surface_pane(&app.mux, sess, s.parent_id); pp != nil && !pp.is_floating {
			target_pid = pp.id
		}
	}
	leaf := chrome_splits.split_tree_find_leaf(split_tree, target_pid)
	if leaf == nil do return false
	new_pid := mux_feat.multiplexer_add_terminal_pane(&app.mux, sess, s.id)
	inv := s.split_dir == .Right || s.split_dir == .Down
	kind: chrome_splits.Split_Kind = .Horizontal if (s.split_dir == .Right || s.split_dir == .Left) else .Vertical
	ratio := clamp((1.0 - f32(s.split_ratio) / 100.0) if inv else (f32(s.split_ratio) / 100.0), 0.1, 0.9)
	chrome_splits.split_node_split(leaf, kind, ratio, new_pid, app.tabs_mgr.allocator)
	if !inv && leaf.left != nil && leaf.right != nil {
		leaf.left.pane_id, leaf.right.pane_id = leaf.right.pane_id, leaf.left.pane_id
	}
	return true
}

surface_prune_stale_panes :: proc(app: ^Term_App, active_tab: ^tabs_feat.Tab_Entry) -> (changed: bool) {
	stale_ids: [32]u32
	stale_n := 0
	for &p in app.mux.panes {
		if p.surface_id == 0 do continue
		valid := false
		if p.session != nil {
			if s := core_terminal.terminal_surface_find(&p.session.term, p.surface_id); s != nil && s.visible {
				valid = (s.kind == .Popup) == p.is_floating
			}
		}
		if !valid && stale_n < len(stale_ids) {
			stale_ids[stale_n] = p.id
			stale_n += 1
		}
	}
	for i in 0 ..< stale_n {
		pid := stale_ids[i]
		terminal_view_release_pane(&app.term_view, pid)
		if active_tab != nil {
			_ = chrome_splits.split_tree_remove_pane(&active_tab.split_tree, pid, app.tabs_mgr.allocator)
		}
		mux_feat.multiplexer_close_pane(&app.mux, pid)
		changed = true
	}
	return changed
}

// surface_sync_split_tree reconciles OSC 8400 .Split and .Popup surfaces with
// native Split_Node leaves and Pane_Entry items in the active tab.
surface_sync_split_tree :: proc(app: ^Term_App) -> (changed: bool) {
	if app == nil do return false
	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if active_tab == nil || active_tab.split_tree == nil do return false
	if surface_prune_stale_panes(app, active_tab) do changed = true

	pane_count := len(app.mux.panes)
	for p_idx in 0 ..< pane_count {
		if p_idx >= len(app.mux.panes) do break
		p := app.mux.panes[p_idx]
		if p.kind != .Terminal || p.session == nil || p.surface_id != 0 do continue
		if chrome_splits.split_tree_find_leaf(active_tab.split_tree, p.id) == nil do continue
		t := &p.session.term
		for s_idx in 0 ..< len(t.surfaces) {
			s := &t.surfaces[s_idx]
			if !s.visible do continue
			sp := mux_feat.multiplexer_find_surface_pane(&app.mux, p.session, s.id)
			if s.kind == .Split {
				if sp == nil {
					if _insert_surface_split_leaf(app, active_tab.split_tree, p.session, p.id, s) do changed = true
				} else if parent := _find_parent_split(active_tab.split_tree, sp.id); parent != nil {
					if _sync_split_ratio(app, parent, s) do changed = true
				}
			} else if s.kind == .Popup {
				if sp == nil {
					new_pid := mux_feat.multiplexer_add_terminal_pane(&app.mux, p.session, s.id)
					if np := mux_feat.multiplexer_get_pane(&app.mux, new_pid); np != nil {
						np.is_floating = true
						np.z = s.z
					}
					changed = true
				} else {
					sp.is_floating = true
					sp.z = s.z
				}
			}
		}
		if t.focus_requested {
			t.focus_requested = false
			want_sid: u16 = 0
			if fs := core_terminal.terminal_surface_find(t, t.focused_surface_id); fs != nil && fs.visible {
				want_sid = fs.id
			}
			if wp := mux_feat.multiplexer_find_surface_pane(&app.mux, p.session, want_sid); wp != nil {
				mux_feat.multiplexer_focus_pane(&app.mux, wp.id)
				active_tab.active_pane_id = wp.id
				changed = true
			}
		}
	}
	return changed
}

// surface_sync_floating_rects updates the pixel `rect` for all floating (.Popup)
// Pane_Entry items belonging to the active tab.
surface_sync_floating_rects :: proc(app: ^Term_App, content_area: [4]f32) {
	if app == nil do return
	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	for &pane in app.mux.panes {
		if !pane.is_floating do continue
		pane.rect = {}
		if pane.session == nil || active_tab == nil || active_tab.split_tree == nil do continue
		root_pane := mux_feat.multiplexer_find_surface_pane(&app.mux, pane.session, 0)
		if root_pane == nil || chrome_splits.split_tree_find_leaf(active_tab.split_tree, root_pane.id) == nil do continue
		s := core_terminal.terminal_surface_find(&pane.session.term, pane.surface_id)
		if s == nil || !s.visible || s.kind != .Popup do continue
		pane.z = s.z
		pane.rect = surface_popup_body_rect(content_area, root_pane.rect, &pane.session.term, s, app.layout.metrics)
	}
}

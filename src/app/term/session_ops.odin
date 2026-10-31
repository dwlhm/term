package term

// Background Sessions & Pane Detach/Attach
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: Non-blocking PTY drain for background jobs and seamless
// lifecycle transition between tabs and background session registry.

import chrome_render "../../core/render/chrome"
import chrome_splits "../../core/chrome/splits"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"
import damage "../../core/terminal/damage"

// app_detach_focused_pane detaches the currently focused terminal pane into background sessions.
// If it is part of a split, the split collapses. If it is the sole remaining pane,
// a fresh replacement shell is spawned so the window stays open with a clean prompt.
app_detach_focused_pane :: proc(app: ^Term_App) -> bool {
	if app == nil do return false
	pane_id := app.mux.focused_pane_id
	if pane_id == 0 do return false

	p := mux_feat.multiplexer_get_pane(&app.mux, pane_id)
	if p == nil || p.session == nil do return false

	found_tab_idx := -1
	for i in 0..<len(app.tabs_mgr.entries) {
		tab := &app.tabs_mgr.entries[i]
		leaf := chrome_splits.split_tree_find_leaf(tab.split_tree, pane_id)
		if tab.active_pane_id == pane_id || leaf != nil {
			found_tab_idx = i
			break
		}
	}
	if found_tab_idx < 0 do return false
	tab := &app.tabs_mgr.entries[found_tab_idx]

	sess_feat.session_registry_detach(&app.session_reg, p.id, p.session)
	p.session = nil

	terminal_view_release_pane(&app.term_view, pane_id)

	has_other_panes := false
	if tab.split_tree != nil {
		_ = chrome_splits.split_tree_remove_pane(&tab.split_tree, pane_id, app.tabs_mgr.allocator)
		has_other_panes = (tab.split_tree != nil)
	}

	mux_feat.multiplexer_close_pane(&app.mux, pane_id)
	_detach_handle_remaining(app, found_tab_idx, has_other_panes)

	app_sync_layout_and_winsize(app)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

_detach_handle_remaining :: proc(app: ^Term_App, tab_idx: int, has_other_panes: bool) {
	tab := &app.tabs_mgr.entries[tab_idx]
	if has_other_panes {
		first_leaf := chrome_splits.split_tree_first_leaf(tab.split_tree)
		if first_leaf != nil {
			tab.active_pane_id = first_leaf.pane_id
			mux_feat.multiplexer_focus_pane(&app.mux, tab.active_pane_id)
		}
	} else if len(app.tabs_mgr.entries) > 1 {
		app_close_tab(app, tab_idx)
	} else {
		_ = app_spawn_default_tab(app)
	}
}

// app_attach_background_session restores a specific detached background session into a new tab.
app_attach_background_session :: proc(app: ^Term_App, bg_id: u32) -> bool {
	if app == nil do return false
	sess, found := sess_feat.session_registry_pop(&app.session_reg, bg_id)
	if !found do return false

	pane_id := app.mux.next_pane_id
	app.mux.next_pane_id += 1
	append(&app.mux.panes, mux_feat.Pane_Entry{
		id         = pane_id,
		kind       = .Terminal,
		session    = sess,
		is_focused = true,
	})
	app_bind_session_extensions(app, pane_id)

	title := sess_feat.session_get_title(sess)
	if len(title) == 0 do title = "Restored"

	_, new_tab_idx := tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, title, pane_id)
	if new_tab_idx >= 0 {
		app_select_tab(app, new_tab_idx)
	}
	damage.damage_mark_all(&sess.term.damage)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}



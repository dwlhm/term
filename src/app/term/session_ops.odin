package term

// Background Sessions, Safety Confirmation Dialog & Pane Detach/Attach
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: Non-blocking PTY drain for background jobs and seamless
// lifecycle transition between tabs and background session registry.

import "core:time"
import chrome_modals "../../core/chrome/modals"
import chrome_render "../../core/render/chrome"
import chrome_splits "../../core/chrome/splits"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"
import damage "../../core/terminal/damage"

_has_active_jobs :: proc(app: ^Term_App) -> bool {
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			if sess_feat.session_is_running_job(pane.session) do return true
		}
	}
	return false
}

_populate_safety_dialog_items :: proc(app: ^Term_App) {
	chrome_modals.session_dialog_reset(&app.session_dlg)
	for i in 0..<len(app.tabs_mgr.entries) {
		tab := &app.tabs_mgr.entries[i]
		for &pane in app.mux.panes {
			if pane.kind != .Terminal || pane.session == nil do continue
			leaf := chrome_splits.split_tree_find_leaf(tab.split_tree, pane.id)
			if tab.active_pane_id == pane.id || leaf != nil {
				is_job := sess_feat.session_is_running_job(pane.session)
				snap := sess_feat.session_snapshot_make(pane.session, i, pane.id, context.temp_allocator)
				append(&app.session_dlg.items, chrome_modals.Dialog_Session_Item{
					session_id    = pane.id,
					tab_index     = i,
					pane_id       = pane.id,
					title         = snap.title,
					process_name  = snap.process_name,
					pid           = snap.pid,
					is_active_job = is_job,
					status_msg    = snap.status_msg,
					choice        = .Background if is_job else .Kill,
				})
			}
		}
	}
}

// app_check_and_show_safety_dialog checks if any session is actively running a job.
// Returns true and opens the confirmation modal if active jobs exist; false otherwise.
app_check_and_show_safety_dialog :: proc(app: ^Term_App) -> bool {
	if app == nil || !_has_active_jobs(app) do return false
	_populate_safety_dialog_items(app)
	app.session_dlg.visible = true
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

// app_apply_safety_dialog executes the user's choices: background sessions are
// detached into session_reg, killed sessions are closed, and the window closes.
app_apply_safety_dialog :: proc(app: ^Term_App) {
	if app == nil do return
	for item in app.session_dlg.items {
		if item.choice == .Background {
			if p := mux_feat.multiplexer_get_pane(&app.mux, item.pane_id); p != nil && p.session != nil {
				sess_feat.session_registry_detach(&app.session_reg, item.pane_id, u32(item.tab_index), item.title, p.session)
				p.session = nil
			}
		}
	}
	app.session_dlg.visible = false
	app.running = false
}

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

	title := string(tab.title_buf[:tab.title_len]) if tab.title_len > 0 else "Shell"
	sess_feat.session_registry_detach(&app.session_reg, p.id, u32(found_tab_idx), title, p.session)
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
	app_sync_menu_bar(app)
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
		content_area := layout_compute_content_area(&app.layout)
		term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
		term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
		new_p, ok := app_spawn_terminal_pane(app, term_rows, term_cols)
		if ok {
			tab.split_tree = chrome_splits.split_node_create_leaf(new_p, app.tabs_mgr.allocator)
			tab.active_pane_id = new_p
			tabs_feat.tabs_manager_set_title(&app.tabs_mgr, 0, "Shell")
			mux_feat.multiplexer_focus_pane(&app.mux, new_p)
		}
	}
}

// Backward-compatible alias
app_detach_current_tab :: app_detach_focused_pane

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
	app_sync_menu_bar(app)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

// app_attach_latest_background_session pops and restores the most recently detached session.
app_attach_latest_background_session :: proc(app: ^Term_App) -> bool {
	if app == nil || sess_feat.session_registry_count(&app.session_reg) == 0 do return false
	last_idx := len(app.session_reg.entries) - 1
	bg_id := app.session_reg.entries[last_idx].id
	return app_attach_background_session(app, bg_id)
}

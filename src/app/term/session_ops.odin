package term

// Background Sessions, Safety Confirmation Dialog & Menu Bar Coordinator
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: Non-blocking PTY drain for background jobs and seamless
// navigation handoff between Menu Bar and window panes.

import "core:fmt"
import "core:time"
import chrome_modals "../../core/chrome/modals"
import chrome_render "../../core/render/chrome"
import chrome_splits "../../core/chrome/splits"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import tabs_feat "../../features/tabs"
import plat_win "../../platform/window"

// app_check_and_show_safety_dialog checks if any session is actively running a job.
// Returns true and opens the confirmation modal if active jobs exist; false otherwise.
app_check_and_show_safety_dialog :: proc(app: ^Term_App) -> bool {
	if app == nil do return false

	has_active_job := false
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			if sess_feat.session_is_running_job(pane.session) {
				has_active_job = true
				break
			}
		}
	}

	if !has_active_job do return false

	// Populate dialog items: active jobs default to .Background; idle shells default to .Kill
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

	if has_other_panes {
		first_leaf := chrome_splits.split_tree_first_leaf(tab.split_tree)
		if first_leaf != nil {
			tab.active_pane_id = first_leaf.pane_id
			mux_feat.multiplexer_focus_pane(&app.mux, tab.active_pane_id)
		}
	} else {
		if len(app.tabs_mgr.entries) > 1 {
			app_close_tab(app, found_tab_idx)
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

	app_sync_layout_and_winsize(app)
	app_sync_menu_bar(app, time.now())
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

// Backward-compatible alias
app_detach_current_tab :: app_detach_focused_pane

// app_attach_latest_background_session pops and restores the most recently detached session.
app_attach_latest_background_session :: proc(app: ^Term_App) -> bool {
	if app == nil || sess_feat.session_registry_count(&app.session_reg) == 0 do return false
	last_idx := len(app.session_reg.entries) - 1
	bg_id := app.session_reg.entries[last_idx].id
	if sess, found := sess_feat.session_registry_pop(&app.session_reg, bg_id); found {
		content_area := layout_compute_content_area(&app.layout)
		term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
		term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
		pane_id := app.mux.next_pane_id
		app.mux.next_pane_id += 1
		append(&app.mux.panes, mux_feat.Pane_Entry{
			id         = pane_id,
			kind       = .Terminal,
			session    = sess,
			is_focused = true,
		})
		tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Restored", pane_id)
		mux_feat.multiplexer_focus_pane(&app.mux, pane_id)
		app_sync_layout_and_winsize(app)
		return true
	}
	return false
}

// app_sync_menu_bar updates the native macOS Menu Bar with live background session status.
app_sync_menu_bar :: proc(app: ^Term_App, now: time.Time) {
	if app == nil || app.menu_bar == nil do return
	if time.duration_seconds(time.diff(app.last_mb_sync, now)) < 1.0 do return
	app.last_mb_sync = now

	items := make([dynamic]plat_win.Platform_Menu_Bar_Item, 0, 16, context.temp_allocator)
	active_jobs := 0

	// 1. Visible active jobs
	for &pane in app.mux.panes {
		if pane.kind != .Terminal || pane.session == nil do continue
		if sess_feat.session_is_running_job(pane.session) {
			active_jobs += 1
			snap := sess_feat.session_snapshot_make(pane.session, 0, pane.id, context.temp_allocator)
			title := fmt.tprintf("[●] %s (PID %d) - %s", snap.process_name, snap.pid, snap.status_msg) if len(snap.status_msg) > 0 else fmt.tprintf("[●] %s (PID %d)", snap.process_name, snap.pid)
			append(&items, plat_win.Platform_Menu_Bar_Item{
				title      = title,
				tag        = 1000 + int(pane.id),
				is_enabled = true,
			})
		}
	}

	// 2. Detached background sessions
	for &bg in app.session_reg.entries {
		if bg.session == nil do continue
		active_jobs += 1
		snap := sess_feat.session_snapshot_make(bg.session, 0, bg.id, context.temp_allocator)
		title := fmt.tprintf("[BG] %s (PID %d) - %s", snap.process_name, snap.pid, snap.status_msg) if len(snap.status_msg) > 0 else fmt.tprintf("[BG] %s (PID %d)", snap.process_name, snap.pid)
		append(&items, plat_win.Platform_Menu_Bar_Item{
			title      = title,
			tag        = 2000 + int(bg.id),
			is_enabled = true,
		})
	}

	header := fmt.tprintf("Term (%d background tasks)", active_jobs) if active_jobs > 0 else "Term (Idle)"

	append(&items, plat_win.Platform_Menu_Bar_Item{is_separator = true})
	append(&items, plat_win.Platform_Menu_Bar_Item{
		title      = "Show Window",
		tag        = 1,
		is_enabled = true,
	})
	append(&items, plat_win.Platform_Menu_Bar_Item{
		title      = "Quit Term",
		tag        = 2,
		is_enabled = true,
	})

	plat_win.platform_menu_bar_update(app.menu_bar, header, items[:])
}

// app_handle_menu_bar_action navigates directly from Menu Bar clicks to the target session.
app_handle_menu_bar_action :: proc(app: ^Term_App, tag: int) {
	if app == nil || tag <= 0 do return
	switch tag {
	case 1:
		plat_win.platform_bring_window_to_front(app.window.handle)
	case 2:
		app.running = false
	case:
		plat_win.platform_bring_window_to_front(app.window.handle)
		if tag >= 2000 {
			bg_id := u32(tag - 2000)
			if sess, found := sess_feat.session_registry_pop(&app.session_reg, bg_id); found {
				content_area := layout_compute_content_area(&app.layout)
				term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
				term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
				pane_id := app.mux.next_pane_id
				app.mux.next_pane_id += 1
				append(&app.mux.panes, mux_feat.Pane_Entry{
					id         = pane_id,
					kind       = .Terminal,
					session    = sess,
					is_focused = true,
				})
				tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Restored", pane_id)
				mux_feat.multiplexer_focus_pane(&app.mux, pane_id)
			}
		} else if tag >= 1000 {
			pane_id := u32(tag - 1000)
			for i in 0..<len(app.tabs_mgr.entries) {
				tab := &app.tabs_mgr.entries[i]
				leaf := chrome_splits.split_tree_find_leaf(tab.split_tree, pane_id)
				if tab.active_pane_id == pane_id || leaf != nil {
					app_select_tab(app, i)
					mux_feat.multiplexer_focus_pane(&app.mux, pane_id)
					break
				}
			}
		}
	}
}

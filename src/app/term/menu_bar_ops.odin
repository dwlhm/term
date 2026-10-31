package term

// Native macOS Menu Bar Coordinator
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Non-blocking PTY drain for background jobs and seamless
// navigation handoff between Menu Bar and window panes.

import "core:fmt"
import "core:time"
import chrome_splits "../../core/chrome/splits"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import plat_win "../../platform/window"

// app_sync_menu_bar updates the native macOS Menu Bar on session/PTY state transitions,
// skipping Objective-C NSMenu reconstruction when the state hash is unchanged.
app_sync_menu_bar :: proc(app: ^Term_App) {
	if app == nil || app.menu_bar == nil do return

	items := make([dynamic]plat_win.Platform_Menu_Bar_Item, 0, 16, context.temp_allocator)
	active_jobs := _append_menu_bar_sessions(app, &items)

	header := fmt.tprintf("Term (%d background tasks)", active_jobs) if active_jobs > 0 else "Term (Idle)"

	append(&items, plat_win.Platform_Menu_Bar_Item{is_separator = true})
	append(&items, plat_win.Platform_Menu_Bar_Item{title = "Show Window", tag = 1, is_enabled = true})
	append(&items, plat_win.Platform_Menu_Bar_Item{title = "Quit Term", tag = 2, is_enabled = true})

	h := _fnv1a_bytes(14695981039346656037, transmute([]byte)header)
	for it in items {
		h = _fnv1a_bytes(h, transmute([]byte)it.title)
		tag_u := u64(it.tag)
		h = _fnv1a_bytes(h, ([^]byte)(&tag_u)[:size_of(u64)])
	}
	if app.has_mb_hash && app.last_mb_hash == h do return
	app.last_mb_hash = h
	app.has_mb_hash = true

	plat_win.platform_menu_bar_update(app.menu_bar, header, items[:])
}

_append_menu_bar_sessions :: proc(app: ^Term_App, items: ^[dynamic]plat_win.Platform_Menu_Bar_Item) -> int {
	active_jobs := 0
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && sess_feat.session_is_running_job(pane.session) {
			active_jobs += 1
			snap := sess_feat.session_snapshot_make(pane.session, 0, pane.id, context.temp_allocator)
			title := fmt.tprintf("[●] %s (PID %d) - %s", snap.process_name, snap.pid, snap.status_msg) if len(snap.status_msg) > 0 else fmt.tprintf("[●] %s (PID %d)", snap.process_name, snap.pid)
			append(items, plat_win.Platform_Menu_Bar_Item{title = title, tag = 1000 + int(pane.id), is_enabled = true})
		}
	}
	for &bg in app.session_reg.entries {
		if bg.session == nil do continue
		active_jobs += 1
		snap := sess_feat.session_snapshot_make(bg.session, 0, bg.id, context.temp_allocator)
		title := fmt.tprintf("[BG] %s (PID %d) - %s", snap.process_name, snap.pid, snap.status_msg) if len(snap.status_msg) > 0 else fmt.tprintf("[BG] %s (PID %d)", snap.process_name, snap.pid)
		append(items, plat_win.Platform_Menu_Bar_Item{title = title, tag = 2000 + int(bg.id), is_enabled = true})
	}
	return active_jobs
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
			app_attach_background_session(app, bg_id)
		} else if tag >= 1000 {
			_focus_menu_bar_pane(app, u32(tag - 1000))
		}
	}
}

_focus_menu_bar_pane :: proc(app: ^Term_App, pane_id: u32) {
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

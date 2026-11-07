package term

// The viewer's side of sessions: programs run in the session core; panes show
// them through the session client. Detach = stop showing (the program keeps
// running in the background), attach = show a background session again.

import "core:fmt"
import chrome_render "../../core/render/chrome"
import chrome_splits "../../core/chrome/splits"
import damage "../../core/terminal/damage"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import client_feat "../../features/session_client"
import tabs_feat "../../features/tabs"
import plat_ipc "../../platform/ipc"

APP_ATTACH_HISTORY :: 2000

// app_sessions_poll applies what the core reported; true when the UI changed.
app_sessions_poll :: proc(app: ^Term_App) -> (dirty: bool) {
	ev: client_feat.Client_Event
	for client_feat.client_poll(&app.client, &ev) {
		switch ev.kind {
		case .None, .Attached, .Ok:
		case .Failed, .Closed:
			dirty = true // the program is gone: reaping closes its pane
		case .Row:
			dirty |= _apply_row(app, ev.row)
		case .Removed:
			dirty |= sess_feat.session_registry_remove(&app.session_reg, ev.id)
		case .Sessions:
			for _ in 0..<ev.count {
				row := plat_ipc.dec_row(&ev.sessions)
				if !ev.sessions.ok do break
				dirty |= _apply_row(app, row)
			}
			app_quit_rows_arrived(app)
		case .Core_Lost:
			if !client_feat.client_reconnect(&app.client) {
				fmt.eprintln("term: lost the session core and could not reach a new one")
				app_request_quit(app)
			}
			dirty = true
		}
	}
	if dirty {
		app.layout.tab_bar_reveal_timer = 2.0
		chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	}
	return
}

// _apply_row keeps a shown session's process facts current and mirrors the
// others (background sessions) into the registry.
@(private = "file")
_apply_row :: proc(app: ^Term_App, row: plat_ipc.Session_Row) -> bool {
	shown := app_shown_session(app, row.id)
	controlled := false // an automation took or left it: its banner changes
	if shown != nil {
		sess_feat.session_set_info(shown, i32(row.pid), 0, row.state != .Exited, int(row.exit_code), row.process, row.cwd)
		app_quit_note_row(app, row)
		controlled = sess_feat.session_set_controller(shown, row.controller, row.controller_pass)
	}
	return sess_feat.session_registry_apply_row(&app.session_reg, row, shown != nil) || controlled
}

// app_shown_session is the pane session of this viewer showing core session id.
app_shown_session :: proc(app: ^Term_App, id: u32) -> ^sess_feat.Terminal_Session {
	for &p in app.mux.panes {
		if p.session != nil && client_feat.client_session_id(&app.client, p.session) == id do return p.session
	}
	return nil
}

// app_detach_focused_pane sends the focused pane's session to the background.
// The last pane of the last tab is replaced by a fresh shell (detach never quits).
app_detach_focused_pane :: proc(app: ^Term_App) -> bool {
	if app == nil do return false
	pane_id := app.mux.focused_pane_id
	p := mux_feat.multiplexer_get_pane(&app.mux, pane_id)
	if p == nil || p.session == nil do return false
	tab_idx := app_tab_of_pane(app, pane_id)
	if tab_idx < 0 do return false
	sess_feat.session_provider_release(&app.mux.provider, p.session, false)
	p.session = nil
	terminal_view_release_pane(&app.term_view, pane_id)
	tab := &app.tabs_mgr.entries[tab_idx]
	if tab.split_tree != nil do _ = chrome_splits.split_tree_remove_pane(&tab.split_tree, pane_id, app.tabs_mgr.allocator)
	mux_feat.multiplexer_close_pane(&app.mux, pane_id)
	switch {
	case tab.split_tree != nil:
		if leaf := chrome_splits.split_tree_first_leaf(tab.split_tree); leaf != nil {
			tab.active_pane_id = leaf.pane_id
			mux_feat.multiplexer_focus_pane(&app.mux, tab.active_pane_id)
		}
	case len(app.tabs_mgr.entries) > 1:
		app_close_tab(app, tab_idx)
	case:
		_ = app_spawn_default_tab(app)
	}
	app_sync_layout_and_winsize(app)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 do damage.damage_mark_all(&pane.session.term.damage)
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

// app_tab_of_pane: the index of the tab holding pane_id (-1: none).
app_tab_of_pane :: proc(app: ^Term_App, pane_id: u32) -> int {
	for &tab, i in app.tabs_mgr.entries {
		if tab.active_pane_id == pane_id || chrome_splits.split_tree_find_leaf(tab.split_tree, pane_id) != nil do return i
	}
	return -1
}

// app_attach_background_session shows background session id in a new tab.
app_attach_background_session :: proc(app: ^Term_App, id: u32) -> bool {
	if app == nil do return false
	entry := sess_feat.session_registry_find(&app.session_reg, id)
	if entry == nil || entry.state == .Exited do return false
	title := sess_feat.registry_text(&entry.title)
	content := layout_compute_content_area(&app.layout)
	cols := max(20, int((content[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
	rows := max(10, int((content[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
	size := plat_ipc.Size_Msg{
		cols = u16(cols), rows = u16(rows),
		xpixel = u16(f32(cols) * app.layout.metrics.cell_w), ypixel = u16(f32(rows) * app.layout.metrics.cell_h),
	}
	sess := client_feat.client_attach(&app.client, {id = id, size = size, history = APP_ATTACH_HISTORY})
	if sess == nil do return false
	sess_feat.session_set_clipboard_sink(sess, _app_osc_52_sink, rawptr(&app.clipboard))
	pane_id := mux_feat.multiplexer_add_terminal_pane(&app.mux, sess)
	_, new_tab_idx := tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, title if len(title) > 0 else "Restored", pane_id)
	_ = sess_feat.session_registry_remove(&app.session_reg, id)
	if new_tab_idx >= 0 do app_select_tab(app, new_tab_idx)
	damage.damage_mark_all(&sess.term.damage)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

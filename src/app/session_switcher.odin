package main

import "core:fmt"
import "core:strings"
import platform_dialogs "../platform/dialogs"
import platform_tabs "../platform/tabs"
import session_core "../session_core"
import termgrid "../terminal"

_app_session_message :: proc(a: ^App, message: string) {
	a.session_switcher.message_len = copy(a.session_switcher.message_buf[:], message)
	a.renderer.full_redraw_pending = true
}

_app_open_session_switcher :: proc(a: ^App, background: bool = false) {
	if a == nil do return
	platform_tabs.tab_menu_close(&a.tab_menu)
	platform_tabs.tab_overflow_close(&a.tab_overflow)
	platform_tabs.tab_drag_reset(&a.tab_drag)
	if a.tab_rename.active do _app_cancel_tab_rename(a)
	if a.search_bar.visible {
		a.search_bar.visible = false
		_app_search_action(a, .Close)
	}
	if a.host_client.connected {
		entries, ok := host_client_list_metadata(&a.host_client)
		if ok {
			for entry in entries {
				if !entry.has_active_viewer {
					id_str := fmt.tprintf("host_ws_%d", entry.id)
					existing := session_core.session_registry_lookup(a.session_mgr.registry, id_str)
					if existing == nil {
						cs := new(session_core.Core_Session)
						cs.id = strings.clone(id_str)
						cs.is_detached = true
						cs.is_host_backed = true
						cs.host_ws_id = u64(entry.id)
						t_len := min(len(entry.title), len(cs.title_buf))
						if t_len > 0 do copy(cs.title_buf[:], entry.title[:t_len])
						cs.title_len = t_len
						termgrid.terminal_init(&cs.term, 24, 80)
						_ = session_core.session_registry_register(a.session_mgr.registry, cs)
					}
				}
			}
		}
	}
	platform_tabs.session_switcher_show(&a.session_switcher, a.session_mgr.tabs[:], a.session_mgr.active_idx, a.session_mgr.registry)
	a.session_switcher.message_len = 0
	if background {
		for m in 0 ..< a.session_switcher.match_count {
			if a.session_switcher.items[a.session_switcher.matches[m]].is_detached {
				a.session_switcher.selected_match_idx = m
				break
			}
		}
	}
	_app_layout_ui(a)
	a.renderer.full_redraw_pending = true
}

_app_close_session_switcher :: proc(a: ^App) {
	platform_tabs.session_switcher_hide(&a.session_switcher)
	_app_set_drag_region(a)
	a.renderer.full_redraw_pending = true
}

_app_refresh_session_switcher :: proc(a: ^App) {
	state := &a.session_switcher
	query := state.query
	query_len := state.query_len
	selected_id: [64]u8
	selected_len := 0
	if state.match_count > 0 {
		selected_len = copy(selected_id[:], state.items[state.matches[state.selected_match_idx]].id)
	}
	if a.host_client.connected {
		entries, ok := host_client_list_metadata(&a.host_client)
		if ok {
			for entry in entries {
				if !entry.has_active_viewer {
					id_str := fmt.tprintf("host_ws_%d", entry.id)
					existing := session_core.session_registry_lookup(a.session_mgr.registry, id_str)
					if existing == nil {
						cs := new(session_core.Core_Session)
						cs.id = strings.clone(id_str)
						cs.is_detached = true
						cs.is_host_backed = true
						cs.host_ws_id = u64(entry.id)
						t_len := min(len(entry.title), len(cs.title_buf))
						if t_len > 0 do copy(cs.title_buf[:], entry.title[:t_len])
						cs.title_len = t_len
						termgrid.terminal_init(&cs.term, 24, 80)
						_ = session_core.session_registry_register(a.session_mgr.registry, cs)
					}
				}
			}
		}
	}
	platform_tabs.session_switcher_show(state, a.session_mgr.tabs[:], a.session_mgr.active_idx, a.session_mgr.registry)
	state.query = query
	state.query_len = query_len
	platform_tabs.session_switcher_filter(state)
	for m in 0 ..< state.match_count {
		if state.items[state.matches[m]].id == string(selected_id[:selected_len]) do state.selected_match_idx = m
	}
	_app_layout_ui(a)
}

_app_detach_tab :: proc(a: ^App, idx: int) {
	if idx < 0 || idx >= len(a.session_mgr.tabs) do return
	if !session_detach_tab(&a.session_mgr, idx) {
		if !a.session_switcher.visible do _app_open_session_switcher(a)
		message := "Cannot detach this session. The terminal remains available; try again."
		_app_session_message(a, message)
		return
	}
	if len(a.session_mgr.tabs) == 0 {
		a.should_quit = true
		return
	}
	_app_resync_tab_modals(a)
	if a.session_switcher.visible do _app_refresh_session_switcher(a)
	a.renderer.full_redraw_pending = true
}

_app_execute_session_action :: proc(a: ^App, action: platform_tabs.Session_Switcher_Action, item: platform_tabs.Session_Switcher_Item) {
	switch action {
	case .None:
	case .Close:
		_app_close_session_switcher(a)
	case .Switch_Tab:
		idx := _app_tab_index_by_id(a, item.tab_id)
		if idx >= 0 {
			_ = session_switch_tab(&a.session_mgr, idx)
			_app_close_session_switcher(a)
			_app_resync_tab_modals(a)
		}
	case .Attach:
		cs := session_core.session_registry_lookup(a.session_mgr.registry, item.id)
		if cs != nil && cs.is_host_backed {
			attach_ok := host_client_attach_workspace(&a.host_client, cs.host_ws_id)
			if !attach_ok {
				_app_session_message(a, "Failed to attach host workspace.")
				return
			}
			rows := a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS
			cols := a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS
			new_idx, spawn_ok := session_spawn_host_backed(&a.session_mgr, &a.host_client, cs.host_ws_id, 1, rows, cols, &a.config, a.renderer.theme)
			if !spawn_ok {
				_app_session_message(a, "Cannot attach: maximum tabs reached.")
				return
			}
			_ = session_core.session_registry_unregister(a.session_mgr.registry, cs.id)
			session_core.session_destroy(cs)
			free(cs)
			_ = session_switch_tab(&a.session_mgr, new_idx)
			_app_close_session_switcher(a)
			_app_resync_tab_modals(a)
			_app_layout_panes(a)
			a.renderer.full_redraw_pending = true
			return
		}
		idx, attached := session_attach_tab(&a.session_mgr, cs)
		if !attached {
			message := "Cannot attach this session. It remains in the background; try again."
			if len(a.session_mgr.tabs) >= a.session_mgr.max_tabs do message = "Cannot attach: close a tab to free space, then try again."
			_app_session_message(a, message)
			return
		}
		_ = session_switch_tab(&a.session_mgr, idx)
		b := tab_active_backend(&a.session_mgr.tabs[idx])
		backend_lock_render(b)
		termgrid.damage_mark_all(&b.front_terminal.damage, nil)
		backend_unlock_render(b)
		a.session_mgr.tabs[idx].tree.root.dispatched_rows = 0
		a.session_mgr.tabs[idx].tree.root.dispatched_cols = 0
		_app_close_session_switcher(a)
		_app_resync_tab_modals(a)
		_app_layout_panes(a)
	case .Detach:
		if !item.is_detached && !item.is_persisted do _app_detach_tab(a, _app_tab_index_by_id(a, item.tab_id))
	case .Terminate:
		if item.is_persisted do return
		if item.is_detached {
			a.confirm_session_len = copy(a.confirm_session_buf[:], item.id)
			_app_close_session_switcher(a)
			platform_dialogs.confirm_dialog_show(&a.confirm_dialog, -1)
			a.confirm_dialog.background_session = true
			_app_set_drag_region(a)
		} else {
			_app_close_session_switcher(a)
			_app_request_close_tab(a, _app_tab_index_by_id(a, item.tab_id))
		}
	case .Restore_Layout:
		_app_session_message(a, "Restore saved layouts through the existing layout workflow.")
	}
	a.renderer.full_redraw_pending = true
}

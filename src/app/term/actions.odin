package term

// Term Action Dispatcher & Pane/Tab Operations
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:os"

import chrome_splits "../../core/chrome/splits"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"

_app_osc_52_sink :: proc(user_data: rawptr, text: string) -> bool {
	cb := (^Clipboard_Bridge)(user_data)
	return clipboard_set_text_guarded(cb, text)
}

// app_bind_session_extensions attaches decoupled clipboard sink to terminal sessions.
app_bind_session_extensions :: proc(app: ^Term_App, p_id: u32) {
	p := mux_feat.multiplexer_get_pane(&app.mux, p_id)
	if p != nil && p.session != nil {
		sess_feat.session_set_clipboard_sink(p.session, _app_osc_52_sink, rawptr(&app.clipboard))
	}
}

// app_spawn_terminal_pane discovers user shell, initializes a terminal pane
// within the multiplexer, and binds session extensions.
app_spawn_terminal_pane :: proc(app: ^Term_App, rows: int = 24, cols: int = 80) -> (u32, bool) {
	shell := os.get_env("SHELL", context.temp_allocator)
	if len(shell) == 0 do shell = "/bin/sh"

	new_p, err := mux_feat.multiplexer_create_terminal_pane(&app.mux, {shell = shell, rows = rows, cols = cols})
	if err != .None do return 0, false

	app_bind_session_extensions(app, new_p)
	return new_p, true
}

// app_close_tab releases every pane referenced by the tab's split tree before
// removing the tab, so no session/PTY is left orphaned in the multiplexer.
app_close_tab :: proc(app: ^Term_App, tab_idx: int) {
	if tab_idx < 0 || tab_idx >= len(app.tabs_mgr.entries) do return

	pane_ids: [dynamic]u32
	defer delete(pane_ids)
	chrome_splits.split_tree_collect_pane_ids(app.tabs_mgr.entries[tab_idx].split_tree, &pane_ids)

	for pid in pane_ids {
		terminal_view_release_pane(&app.term_view, pid)
		mux_feat.multiplexer_close_pane(&app.mux, pid)
	}

	tabs_feat.tabs_manager_close_tab(&app.tabs_mgr, tab_idx)
	if len(app.tabs_mgr.entries) == 0 {
		app.running = false
	}
	app.layout.tab_bar_force = true
}

// app_close_pane releases an individual pane, collapses the split tree,
// and closes the tab if no panes remain.
app_close_pane :: proc(app: ^Term_App, pane_id: u32) {
	if app == nil || pane_id == 0 do return

	terminal_view_release_pane(&app.term_view, pane_id)

	found_tab_idx := -1
	for i in 0..<len(app.tabs_mgr.entries) {
		tab := &app.tabs_mgr.entries[i]
		if chrome_splits.split_tree_find_leaf(tab.split_tree, pane_id) != nil {
			found_tab_idx = i
			break
		}
	}

	if found_tab_idx >= 0 {
		tab := &app.tabs_mgr.entries[found_tab_idx]
		_ = chrome_splits.split_tree_remove_pane(&tab.split_tree, pane_id, app.tabs_mgr.allocator)
		if tab.split_tree == nil {
			mux_feat.multiplexer_close_pane(&app.mux, pane_id)
			app_close_tab(app, found_tab_idx)
			return
		}
	}

	mux_feat.multiplexer_close_pane(&app.mux, pane_id)

	if found_tab_idx >= 0 {
		tab := &app.tabs_mgr.entries[found_tab_idx]
		if tab.active_pane_id == pane_id {
			tab.active_pane_id = app.mux.focused_pane_id
		}
	}

	app_sync_layout_and_winsize(app)
}

// app_reap_dead_sessions checks all terminal panes for terminated child shells
// (e.g. user typed 'exit' or sent EOF/SIGTERM) and closes them cleanly.
app_reap_dead_sessions :: proc(app: ^Term_App) -> (reaped: bool) {
	if app == nil do return false

	dead_ids: [dynamic]u32
	defer delete(dead_ids)

	for &p in app.mux.panes {
		if p.kind == .Terminal && p.session != nil {
			alive, _ := sess_feat.session_is_alive(p.session)
			if !alive {
				append(&dead_ids, p.id)
			}
		}
	}

	for pid in dead_ids {
		app_close_pane(app, pid)
		reaped = true
	}

	return reaped
}

// app_execute_action dispatches higher-level UI and workspace commands.
app_execute_action :: proc(app: ^Term_App, act: Action_Id) {
	#partial switch act {
	case .Command_Center_Toggle:
		command_center_toggle(&app.cmd_center)

	case .Tab_New:
		new_p, ok := app_spawn_terminal_pane(app, 24, 80)
		if !ok do return
		tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
		mux_feat.multiplexer_focus_pane(&app.mux, new_p)
		app.layout.tab_bar_force = true

	case .Tab_Close:
		act_idx, _ := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if act_idx >= 0 do app_close_tab(app, act_idx)

	case .Tab_Next:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			next_idx := (app.tabs_mgr.model.active_idx + 1) % cnt
			tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, next_idx)
		}
		app.layout.tab_bar_force = true

	case .Tab_Prev:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			prev_idx := (app.tabs_mgr.model.active_idx - 1 + cnt) % cnt
			tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, prev_idx)
		}
		app.layout.tab_bar_force = true

	case .Tab_Select_1, .Tab_Select_2, .Tab_Select_3, .Tab_Select_4, .Tab_Select_5, .Tab_Select_6, .Tab_Select_7, .Tab_Select_8, .Tab_Select_9:
		idx := int(act) - int(Action_Id.Tab_Select_1)
		tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, idx)
		app.layout.tab_bar_force = true

	case .Pane_Split_Right:
		new_p, ok := app_spawn_terminal_pane(app, 24, 80)
		if !ok do return
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			target_leaf := chrome_splits.split_tree_find_leaf(active_tab.split_tree, app.mux.focused_pane_id)
			if target_leaf == nil {
				target_leaf = active_tab.split_tree
			}
			chrome_splits.split_node_split(target_leaf, .Horizontal, 0.5, new_p, app.tabs_mgr.allocator)
			mux_feat.multiplexer_focus_pane(&app.mux, new_p)
			active_tab.active_pane_id = new_p
			app_sync_layout_and_winsize(app)
		}

	case .Pane_Split_Down:
		new_p, ok := app_spawn_terminal_pane(app, 24, 80)
		if !ok do return
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			target_leaf := chrome_splits.split_tree_find_leaf(active_tab.split_tree, app.mux.focused_pane_id)
			if target_leaf == nil {
				target_leaf = active_tab.split_tree
			}
			chrome_splits.split_node_split(target_leaf, .Vertical, 0.5, new_p, app.tabs_mgr.allocator)
			mux_feat.multiplexer_focus_pane(&app.mux, new_p)
			active_tab.active_pane_id = new_p
			app_sync_layout_and_winsize(app)
		}

	case .Pane_Close:
		if app.mux.focused_pane_id != 0 {
			app_close_pane(app, app.mux.focused_pane_id)
		}

	case .Pane_Focus_Next:
		mux_feat.multiplexer_cycle_focus(&app.mux)

	case .Pane_Toggle_Zoom:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil do mux_feat.multiplexer_toggle_zoom(&app.mux, p.id)

	case .Clipboard_Copy:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			_ = clipboard_copy_selection(&app.clipboard, p.session, app.mouse.selection)
		}

	case .Clipboard_Paste:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			if app.mouse.selection.active {
				mouse_clear_selection(&app.mouse)
			}
			_ = clipboard_paste(&app.clipboard, p.session)
		}

	case .Select_All:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			mouse_select_all(&app.mouse, p.id, p.session)
		}

	case .Select_Left, .Select_Right, .Select_Up, .Select_Down,
	     .Select_Word_Left, .Select_Word_Right, .Select_Line_Start, .Select_Line_End:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			mouse_keyboard_select(&app.mouse, p.id, p.session, act)
		}

	case .Scroll_Page_Up:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			page := max(1, p.session.term.rows - 2)
			p.session.scroll_offset = clamp(p.session.scroll_offset + page, 0, p.session.term.grid.history_count)
		}

	case .Scroll_Page_Down:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			page := max(1, p.session.term.rows - 2)
			p.session.scroll_offset = clamp(p.session.scroll_offset - page, 0, p.session.term.grid.history_count)
		}

	case .Scroll_Line_Up:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = clamp(p.session.scroll_offset + 3, 0, p.session.term.grid.history_count)
		}

	case .Scroll_Line_Down:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = clamp(p.session.scroll_offset - 3, 0, p.session.term.grid.history_count)
		}

	case .Scroll_To_Top:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = p.session.term.grid.history_count
		}

	case .Scroll_To_Bottom:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			p.session.scroll_offset = 0
		}

	case .Scroll_Clear:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			terminal_grid.grid_clear_history(&p.session.term.grid)
			p.session.scroll_offset = 0
			sess_feat.session_write_string(p.session, "\x0c") // Form feed / clear
		}

	case .Font_Zoom_In:
		app_adjust_font_size(app, 1.0)

	case .Font_Zoom_Out:
		app_adjust_font_size(app, -1.0)

	case .Font_Zoom_Reset:
		app_reset_font_size(app)

	case .App_Reload_Config:
		app.config = config_load()

	case .App_Quit:
		app.running = false
	}
}

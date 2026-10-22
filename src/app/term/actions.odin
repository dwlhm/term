package term

// Term Action Dispatcher & Pane/Tab Operations
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

import plat_win "../../platform/window"
import chrome_splits "../../core/chrome/splits"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"
import terminal_grid "../../core/terminal/grid"
import damage "../../core/terminal/damage"
import chrome_render "../../core/render/chrome"

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

// app_spawn_terminal_pane discovers user shell, inherits cwd from focused pane,
// initializes a terminal pane within the multiplexer, and binds session extensions.
app_spawn_terminal_pane :: proc(app: ^Term_App, rows: int = 24, cols: int = 80) -> (u32, bool) {
	shell := os.get_env("SHELL", context.temp_allocator)
	if len(shell) == 0 do shell = "/bin/sh"

	cwd := ""
	if focused := mux_feat.multiplexer_get_focused_pane(&app.mux); focused != nil && focused.session != nil {
		scratch_cwd: [1024]u8
		cwd = sess_feat.session_get_current_cwd(focused.session, scratch_cwd[:])
	}
	if len(cwd) == 0 && app != nil {
		cwd = app.default_cwd
	}
	if len(cwd) == 0 || cwd == "/" {
		cwd = os.get_env("HOME", context.temp_allocator)
	}
	cwd = config_expand_path(cwd)

	cw := app.layout.metrics.cell_w if app != nil && app.layout.metrics.cell_w > 0 else 19.0
	ch := app.layout.metrics.cell_h if app != nil && app.layout.metrics.cell_h > 0 else 43.0
	xp := int(f32(cols) * cw)
	yp := int(f32(rows) * ch)
	new_p, err := mux_feat.multiplexer_create_terminal_pane(&app.mux, {
		shell  = shell,
		cwd    = cwd,
		rows   = rows,
		cols   = cols,
		xpixel = xp,
		ypixel = yp,
	})
	if err != .None do return 0, false

	app_bind_session_extensions(app, new_p)
	return new_p, true
}

// app_select_tab activates the requested tab, synchronizes multiplexer focus to the
// tab's active pane, updates geometry & PTY winsize, marks damage on newly visible panes,
// and ensures chrome renderer redraws.
app_select_tab :: proc(app: ^Term_App, idx: int) {
	if app == nil || idx < 0 || idx >= len(app.tabs_mgr.entries) do return

	old_p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	if !tabs_feat.tabs_manager_select_tab(&app.tabs_mgr, idx) do return

	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if active_tab != nil && active_tab.active_pane_id != 0 {
		if old_p != nil && old_p.session != nil && old_p.id != active_tab.active_pane_id {
			mouse_protocol_report_focus(old_p.session, false)
		}
		mux_feat.multiplexer_focus_pane(&app.mux, active_tab.active_pane_id)
		if new_p := mux_feat.multiplexer_get_pane(&app.mux, active_tab.active_pane_id); new_p != nil && new_p.session != nil {
			mouse_protocol_report_focus(new_p.session, true)
		}
	}

	app_sync_layout_and_winsize(app)

	// Mark all visible panes in this tab as damaged so their content renders immediately
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}

	layout_tab_bar_ensure_visible(&app.layout, idx, len(app.tabs_mgr.entries), 80.0 * app.layout.metrics.scale)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	app.layout.tab_bar_reveal_timer = 2.0
}

// app_close_tab releases every pane referenced by the tab's split tree before
// removing the tab, so no session/PTY is left orphaned in the multiplexer.
app_close_tab :: proc(app: ^Term_App, tab_idx: int) {
	if app == nil || tab_idx < 0 || tab_idx >= len(app.tabs_mgr.entries) do return

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
		return
	}

	// Select and focus the newly active tab
	act_idx, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if act_idx >= 0 && active_tab != nil {
		if active_tab.active_pane_id != 0 {
			mux_feat.multiplexer_focus_pane(&app.mux, active_tab.active_pane_id)
		}
		app_sync_layout_and_winsize(app)
		for &pane in app.mux.panes {
			if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 {
				damage.damage_mark_all(&pane.session.term.damage)
			}
		}
	}

	layout_tab_bar_clamp_scroll(&app.layout, len(app.tabs_mgr.entries), 80.0 * app.layout.metrics.scale)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	app.layout.tab_bar_reveal_timer = 2.0
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
			first_leaf := chrome_splits.split_tree_first_leaf(tab.split_tree)
			if first_leaf != nil {
				tab.active_pane_id = first_leaf.pane_id
				mux_feat.multiplexer_focus_pane(&app.mux, tab.active_pane_id)
			} else {
				tab.active_pane_id = app.mux.focused_pane_id
			}
		}
	}

	app_sync_layout_and_winsize(app)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
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

// app_cycle_tab_pane moves focus forward or backward among panes in the active tab.
app_cycle_tab_pane :: proc(app: ^Term_App, forward: bool) {
	if app == nil do return
	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if active_tab != nil && active_tab.split_tree != nil {
		pane_ids: [dynamic]u32
		defer delete(pane_ids)
		chrome_splits.split_tree_collect_pane_ids(active_tab.split_tree, &pane_ids)
		if len(pane_ids) > 1 {
			cur_idx := 0
			for id, i in pane_ids {
				if id == app.mux.focused_pane_id {
					cur_idx = i
					break
				}
			}
			step := 1 if forward else -1
			next_id := pane_ids[(cur_idx + step + len(pane_ids)) % len(pane_ids)]
			old_p := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if old_p != nil && old_p.session != nil && old_p.id != next_id {
				mouse_protocol_report_focus(old_p.session, false)
			}
			mux_feat.multiplexer_focus_pane(&app.mux, next_id)
			if new_p := mux_feat.multiplexer_get_pane(&app.mux, next_id); new_p != nil && new_p.session != nil {
				mouse_protocol_report_focus(new_p.session, true)
			}
			active_tab.active_pane_id = next_id
		}
	} else {
		mux_feat.multiplexer_cycle_focus(&app.mux, forward)
	}
}

// app_open_in_finder reveals the working directory of the active pane in macOS Finder.
app_open_in_finder :: proc(app: ^Term_App) {
	if app == nil do return
	p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	cwd := ""
	if p != nil && p.session != nil {
		scratch_cwd: [1024]u8
		cwd = sess_feat.session_get_current_cwd(p.session, scratch_cwd[:])
	}
	if len(cwd) == 0 && app != nil {
		cwd = app.default_cwd
	}
	if len(cwd) == 0 {
		cwd = os.get_env("PWD", context.temp_allocator)
	}
	if len(cwd) == 0 || cwd == "/" do cwd = os.get_env("HOME", context.temp_allocator)
	if len(cwd) > 0 {
		cmd := fmt.tprintf("open \"%s\"", cwd)
		cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
		libc.system(cstr)
	}
}

// app_show_pane_context_menu triggers the authentic native macOS AppKit context menu.
app_show_pane_context_menu :: proc(app: ^Term_App, mx, my: f32) {
	if app == nil do return

	has_selection := app.mouse.selection.active
	items := []plat_win.Platform_Menu_Item{
		{title = "Open in Finder",   shortcut = "",  shift_mod = false, is_separator = false, enabled = true,          action_tag = 1},
		{title = "New Tab",          shortcut = "t", shift_mod = false, is_separator = false, enabled = true,          action_tag = 2},
		{title = "Split Pane Right", shortcut = "d", shift_mod = false, is_separator = false, enabled = true,          action_tag = 3},
		{title = "Split Pane Down",  shortcut = "d", shift_mod = true,  is_separator = false, enabled = true,          action_tag = 4},
		{title = "",                 shortcut = "",  shift_mod = false, is_separator = true,  enabled = false,         action_tag = 0},
		{title = "Copy",             shortcut = "c", shift_mod = false, is_separator = false, enabled = has_selection, action_tag = 5},
		{title = "Paste",            shortcut = "v", shift_mod = false, is_separator = false, enabled = true,          action_tag = 6},
		{title = "",                 shortcut = "",  shift_mod = false, is_separator = true,  enabled = false,         action_tag = 0},
		{title = "Close Pane",       shortcut = "w", shift_mod = true,  is_separator = false, enabled = true,          action_tag = 7},
	}

	logical_x := mx / app.window.pixel_ratio
	logical_y := my / app.window.pixel_ratio
	tag := plat_win.platform_show_context_menu(app.window.handle, logical_x, logical_y, items)

	switch tag {
	case 1: app_open_in_finder(app)
	case 2: app_execute_action(app, .Tab_New)
	case 3: app_execute_action(app, .Pane_Split_Right)
	case 4: app_execute_action(app, .Pane_Split_Down)
	case 5: app_execute_action(app, .Clipboard_Copy)
	case 6: app_execute_action(app, .Clipboard_Paste)
	case 7: app_execute_action(app, .Pane_Close)
	}
}

// app_execute_action dispatches higher-level UI and workspace commands.
app_execute_action :: proc(app: ^Term_App, act: Action_Id) {
	#partial switch act {
	case .Command_Center_Toggle:
		command_center_toggle(&app.cmd_center, .Commands, &app.tabs_mgr)

	case .Tab_Overview_Toggle:
		command_center_toggle(&app.cmd_center, .Tabs, &app.tabs_mgr)

	case .Tab_New:
		new_p, ok := app_spawn_terminal_pane(app, 24, 80)
		if !ok do return
		_, new_idx := tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
		if new_idx >= 0 {
			app_select_tab(app, new_idx)
		}

	case .Tab_Close:
		act_idx, _ := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if act_idx >= 0 do app_close_tab(app, act_idx)

	case .Tab_Next:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			next_idx := (app.tabs_mgr.model.active_idx + 1) % cnt
			app_select_tab(app, next_idx)
		}

	case .Tab_Prev:
		cnt := len(app.tabs_mgr.entries)
		if cnt > 0 {
			prev_idx := (app.tabs_mgr.model.active_idx - 1 + cnt) % cnt
			app_select_tab(app, prev_idx)
		}

	case .Tab_Select_1, .Tab_Select_2, .Tab_Select_3, .Tab_Select_4, .Tab_Select_5, .Tab_Select_6, .Tab_Select_7, .Tab_Select_8, .Tab_Select_9:
		idx := int(act) - int(Action_Id.Tab_Select_1)
		app_select_tab(app, idx)

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
		app_cycle_tab_pane(app, true)

	case .Pane_Focus_Prev:
		app_cycle_tab_pane(app, false)

	case .Pane_Toggle_Zoom:
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil {
			_ = mux_feat.multiplexer_toggle_zoom(&app.mux, p.id)
			app_sync_layout_and_winsize(app)
			for &pane in app.mux.panes {
				if pane.kind == .Terminal && pane.session != nil && pane.rect[2] > 0 {
					damage.damage_mark_all(&pane.session.term.damage)
				}
			}
			chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
		}

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
			bracketed := p.session.term.parser.bracketed_paste
			_ = clipboard_paste(&app.clipboard, p.session, bracketed)
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

	case .Toggle_Fullscreen:
		plat_win.platform_toggle_fullscreen(app.window.handle)

	case .App_Reload_Config:
		app.config = config_load()
		app_apply_config(app)

	case .App_Quit:
		app.running = false
	}
}

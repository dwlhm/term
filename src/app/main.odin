package main

// app_term main coordinator and entry point.
//
// Separates concerns cleanly:
// - Backend: PTY, parser, terminal grid state, damage, selection, cursor tracking
// - Frontend: SDL3 window, event pump, WGPU rendering pipeline, font loading
// - Main: coordinates data flow between Backend and Frontend in a single-threaded loop

import "base:runtime"
import posix "core:sys/posix"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import odin_thread "core:thread"
import "core:time"

import "vendor:sdl3"

PTY_DATA_READY :: sdl3.EventType(cast(u32)sdl3.EventType.USER + 1)

when ODIN_OS == .Darwin {
	foreign import AppKit "system:AppKit.framework"
	@(default_calling_convention="c")
	foreign AppKit {
		NSBeep :: proc() ---
	}
}

_last_notif_time: time.Time

_profile_scenario_initialized: bool
_profile_scenario: Profile_Scenario
_profile_initial_pixel_w: i32
_profile_initial_pixel_h: i32
_profile_scenario_env_checked: bool
_profile_scenario_env_enabled: bool
_profile_telemetry_env_checked: bool
_profile_telemetry_env_enabled: bool
_profile_failure_reason: Profile_Failure_Reason
_profile_failure_kind: Profile_Record_Kind

profile_scenario_enabled :: proc() -> bool {
	if !_profile_scenario_env_checked {
		_profile_scenario_env_checked = true
		value, ok := os.lookup_env("TERM_PROFILE_SCENARIO", context.temp_allocator)
		_profile_scenario_env_enabled = ok && value == "1"
	}
	return _profile_scenario_env_enabled
}

telemetry_enabled :: proc() -> bool {
	if !_profile_telemetry_env_checked {
		_profile_telemetry_env_checked = true
		value, ok := os.lookup_env("TERM_PROFILE_RESIZE_TELEMETRY", context.temp_allocator)
		_profile_telemetry_env_enabled = ok && value == "1"
	}
	return _profile_telemetry_env_enabled
}

_profile_resize_case :: proc(a: ^App, requested_w, requested_h: i32, expect_grid_change, noop: bool, kind: Profile_Record_Kind) -> bool {
	b := app_active_backend(a)
	_profile_failure_reason = .None
	_profile_failure_kind = kind
	if b == nil || requested_w <= 0 || requested_h <= 0 {
		_profile_failure_reason = .Invalid_Target
		return false
	}
	threaded := backend_is_threaded(b)
	before_rows, before_cols := b.terminal.grid.row_count, b.terminal.grid.col_count
	if threaded {
		backend_lock_render(b)
		before_rows, before_cols = b.front_terminal.grid.row_count, b.front_terminal.grid.col_count
		backend_unlock_render(b)
	}
	if noop {
		_ = app_on_resize(a, requested_w, requested_h)
		actual_rows, actual_cols := before_rows, before_cols
		if threaded {
			backend_lock_render(b)
			actual_rows, actual_cols = b.front_terminal.grid.row_count, b.front_terminal.grid.col_count
			backend_unlock_render(b)
		} else {
			actual_rows, actual_cols = b.terminal.grid.row_count, b.terminal.grid.col_count
		}
		requested_rows, requested_cols := grid_dimensions_for_pixels(requested_w, requested_h, a.renderer.cell_width, a.renderer.cell_height, a.renderer.pad_x, a.renderer.pad_y)
		profile_record_resize(_profile_scenario.phase, kind, requested_w, requested_h, a.window.pixel_w, a.window.pixel_h, i32(requested_rows), i32(requested_cols), i32(actual_rows), i32(actual_cols), 0, threaded)
		valid_noop := profile_resize_is_noop(requested_w, requested_h, a.window.pixel_w, a.window.pixel_h) && actual_rows == before_rows && actual_cols == before_cols
		if !valid_noop { _profile_failure_reason = .Noop_Mismatch }
		return valid_noop
	}
	if a.window.width <= 0 || a.window.pixel_w <= 0 || a.window.height <= 0 || a.window.pixel_h <= 0 {
		_profile_failure_reason = .Invalid_Target
		return false
	}
	started := profile_clock_ns()
	scale_x := f32(a.window.pixel_w) / f32(a.window.width)
	scale_y := f32(a.window.pixel_h) / f32(a.window.height)
	logical_w := i32(f32(requested_w) / scale_x + 0.5)
	logical_h := i32(f32(requested_h) / scale_y + 0.5)
	expected_pixel_w := i32(f32(logical_w) * scale_x + 0.5)
	expected_pixel_h := i32(f32(logical_h) * scale_y + 0.5)
	if logical_w <= 0 || logical_h <= 0 || !win.window_set_size(&a.window, logical_w, logical_h) {
		_profile_failure_reason = .Window_Set_Failed
		return false
	}
	window_deadline := u64(platform.platform_ticks_to_ns(platform.platform_now())) + PROFILE_WINDOW_RESIZE_TIMEOUT_NS
	for {
		win.window_update_pixel_size(&a.window)
		if a.window.width == logical_w && a.window.height == logical_h && a.window.pixel_w == expected_pixel_w && a.window.pixel_h == expected_pixel_h { break }
		if u64(platform.platform_ticks_to_ns(platform.platform_now())) >= window_deadline {
			_profile_failure_reason = .Window_Size_Timeout
			return false
		}
		time.sleep(time.Millisecond)
	}
	actual_w, actual_h := a.window.pixel_w, a.window.pixel_h
	req_rows, req_cols := grid_dimensions_for_pixels(requested_w, requested_h, a.renderer.cell_width, a.renderer.cell_height, a.renderer.pad_x, a.renderer.pad_y)
	actual_target_rows, actual_target_cols := grid_dimensions_for_pixels(actual_w, actual_h, a.renderer.cell_width, a.renderer.cell_height, a.renderer.pad_x, a.renderer.pad_y)
	_ = app_on_resize(a, actual_w, actual_h)
	actual_rows, actual_cols := b.terminal.grid.row_count, b.terminal.grid.col_count
	if threaded {
		deadline := u64(platform.platform_ticks_to_ns(platform.platform_now())) + PROFILE_WINDOW_RESIZE_TIMEOUT_NS
		for {
			backend_lock_render(b)
			actual_rows, actual_cols = b.front_terminal.grid.row_count, b.front_terminal.grid.col_count
			backend_unlock_render(b)
			if actual_rows == actual_target_rows && actual_cols == actual_target_cols { break }
			if u64(platform.platform_ticks_to_ns(platform.platform_now())) >= deadline {
				_profile_failure_reason = .Grid_Size_Timeout
				return false
			}
			time.sleep(time.Millisecond)
		}
	}
	elapsed := profile_elapsed_ns(started)
	profile_record_resize(_profile_scenario.phase, kind, requested_w, requested_h, actual_w, actual_h, i32(req_rows), i32(req_cols), i32(actual_rows), i32(actual_cols), elapsed, threaded)
	grid_changed := actual_rows != before_rows || actual_cols != before_cols
	if expect_grid_change != grid_changed {
		_profile_failure_reason = .Grid_Change_Missing
		return false
	}
	return true
}

_profile_scenario_resize :: proc(a: ^App, now_ns: u64) -> bool {
	if a == nil do return false
	b := app_active_backend(a)
	if b == nil do return false
	target_w, target_h, ok := profile_scenario_ladder_target(_profile_initial_pixel_w, _profile_initial_pixel_h, _profile_scenario.resize_step)
	if !ok {
		_profile_failure_reason = .Invalid_Target
		_profile_failure_kind = .Scenario_Phase
		return false
	}
	kind := Profile_Record_Kind.Width_Step if _profile_scenario.resize_step < PROFILE_LADDER_STEP_COUNT/2 else .Height_Step
	if !_profile_resize_case(a, target_w, target_h, true, false, kind) do return false
	profile_scenario_step_done(&_profile_scenario)
	rows, cols := b.terminal.grid.row_count, b.terminal.grid.col_count
	if backend_is_threaded(b) {
		backend_lock_render(b)
		rows, cols = b.front_terminal.grid.row_count, b.front_terminal.grid.col_count
		backend_unlock_render(b)
	}
	profile_record(.Scenario_Phase, .Complete, a.window.pixel_w, a.window.pixel_h, i32(rows), i32(cols), 0, backend_is_threaded(b))
	_ = now_ns
	return true
}

_profile_scenario_step :: proc(a: ^App) -> bool {
	if a == nil || !profile_scenario_enabled() do return true
	now_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	b := app_active_backend(a)
	if b == nil || b.pty.state == .Exited {
		_profile_scenario.phase = .Failed
		profile_phase_publish(.Failed)
		return false
	}
	if !_profile_scenario_initialized {
		_profile_scenario_initialized = true
		_profile_initial_pixel_w, _profile_initial_pixel_h = a.window.pixel_w, a.window.pixel_h
		if !profile_scenario_init(&_profile_scenario, now_ns, now_ns) do return false
		marker_len := 0
		for marker_len < len(_profile_scenario.marker_done) && _profile_scenario.marker_done[marker_len] != 0 { marker_len += 1 }
		marker_cols := b.terminal.grid.col_count
		if backend_is_threaded(b) {
			backend_lock_render(b)
			marker_cols = b.front_terminal.grid.col_count
			backend_unlock_render(b)
		}
		if marker_len > marker_cols {
			_profile_scenario.phase = .Failed
			profile_phase_publish(.Failed)
			return false
		}
		profile_phase_publish(.Idle)
		if telemetry_enabled() {
			if !profile_ring_init(&_profile_ring) { _profile_scenario.phase = .Failed; return false }
			sync.atomic_store(&_profile_enabled, true)
		}
		profile_record(.Scenario_Phase, .Idle, a.window.pixel_w, a.window.pixel_h, i32(b.terminal.grid.row_count), i32(b.terminal.grid.col_count), 0, backend_is_threaded(b))
	}
	if _profile_scenario.phase == .Running {
		terminal := &b.terminal
		if backend_is_threaded(b) {
			backend_lock_render(b)
			terminal = &b.front_terminal
		}
		action := profile_scenario_observe_terminal(&_profile_scenario, terminal, now_ns)
		profile_phase_publish(_profile_scenario.phase)
		if backend_is_threaded(b) { backend_unlock_render(b) }
		if action == .Advance {
			profile_record(.Scenario_Phase, .Complete, a.window.pixel_w, a.window.pixel_h, i32(terminal.grid.row_count), i32(terminal.grid.col_count), 0, backend_is_threaded(b))
			return true
		}
		if action == .Fail { _profile_scenario.phase = .Failed; return false }
	}
	action := profile_scenario_next(&_profile_scenario, now_ns)
	switch action {
	case .Resize:
		return _profile_scenario_resize(a, now_ns)
	case .Drag_Resize:
		target_w, target_h, ok := profile_scenario_drag_target(_profile_initial_pixel_w, _profile_initial_pixel_h, _profile_scenario.drag_step, PROFILE_DRAG_STEPS)
		if !ok {
			_profile_scenario.phase = .Failed
			profile_phase_publish(.Failed)
			return false
		}
		if a.window.width <= 0 || a.window.pixel_w <= 0 || a.window.height <= 0 || a.window.pixel_h <= 0 {
			_profile_scenario.phase = .Failed
			profile_phase_publish(.Failed)
			return false
		}
		scale_x := f32(a.window.pixel_w) / f32(a.window.width)
		scale_y := f32(a.window.pixel_h) / f32(a.window.height)
		logical_w := i32(f32(target_w) / scale_x + 0.5)
		logical_h := i32(f32(target_h) / scale_y + 0.5)
		if !win.window_set_size_no_sync(&a.window, logical_w, logical_h) {
			_profile_scenario.phase = .Failed
			profile_phase_publish(.Failed)
			return false
		}
		_profile_scenario.drag_step += 1
		return true
	case .Prepare, .Submit_Command:
		if !a.window.is_open do return true
		terminal := &b.terminal
		if backend_is_threaded(b) {
			backend_lock_render(b)
			terminal = &b.front_terminal
		}
		ready := profile_scenario_shell_ready(terminal)
		if backend_is_threaded(b) { backend_unlock_render(b) }
		if !ready do return true
		if action == .Prepare {
			evs: [16]input.Input_Event
			n := profile_scenario_prepare_events(evs[:])
			if n == 0 { _profile_scenario.phase = .Failed; profile_phase_publish(.Failed); return false }
			_, ok := app_dispatch_input_events(a, evs[:n])
			if !ok { _profile_scenario.phase = .Failed; profile_phase_publish(.Failed); return false }
			_profile_scenario.echo_prepared = true
			return true
		}
		evs: [256]input.Input_Event
		n := profile_scenario_command_events(&_profile_scenario, evs[:])
		if n == 0 { _profile_scenario.phase = .Failed; profile_phase_publish(.Failed); return false }
		_, ok := app_dispatch_input_events(a, evs[:n])
		if !ok { _profile_scenario.phase = .Failed; profile_phase_publish(.Failed); return false }
		_profile_scenario.phase = .Running
		profile_phase_publish(.Running)
		_profile_scenario.phase_deadline_ns = now_ns + PROFILE_PHASE_TIMEOUT_NS
		profile_record(.Scenario_Phase, .Running, a.window.pixel_w, a.window.pixel_h, i32(b.terminal.grid.row_count), i32(b.terminal.grid.col_count), 0, backend_is_threaded(b))
	case .Stop:
		profile_record(.Scenario_Phase, _profile_scenario.phase, a.window.pixel_w, a.window.pixel_h, i32(b.terminal.grid.row_count), i32(b.terminal.grid.col_count), 0, backend_is_threaded(b))
		return false
	case .Fail:
		_profile_scenario.phase = .Failed
		profile_phase_publish(.Failed)
		return false
	case .None, .Advance:
	}
	return true
}

_app_show_notification :: proc(title: string, message: string) {
	when ODIN_OS == .Darwin {
		now := time.now()
		if _last_notif_time._nsec != 0 && time.diff(_last_notif_time, now) < 1 * time.Second {
			return
		}
		_last_notif_time = now

		c_prog := strings.clone_to_cstring("/usr/bin/osascript", context.temp_allocator)
		c_e := strings.clone_to_cstring("-e", context.temp_allocator)
		c_script := strings.clone_to_cstring("on run {msg, ttl}\ndisplay notification msg with title ttl\nend run", context.temp_allocator)
		c_msg := strings.clone_to_cstring(message, context.temp_allocator)
		c_ttl := strings.clone_to_cstring(title, context.temp_allocator)
		c_argv := [6]cstring{c_prog, c_e, c_script, c_msg, c_ttl, nil}

		pid := posix.fork()
		if pid == 0 {
			if posix.fork() == 0 {
				posix.close(0)
				posix.close(1)
				posix.close(2)
				posix.execvp(c_prog, raw_data(c_argv[:]))
				posix._exit(1)
			}
			posix._exit(0)
		}
		if pid > 0 {
			posix.waitpid(pid, nil, {})
		}
	}
}

import termgrid "../terminal"
import render "../render"
import win "../platform/window"
import input "../platform/input"
import pty "../platform/pty"
import platform "../platform"
import platform_tabs "../platform/tabs"
import platform_dialogs "../platform/dialogs"
import platform_chrome "../platform/chrome"
import config "../config"
import i18n "../i18n"
import inter "../interaction"
import ui "../ui"
import instance "../render/instance"

// App composes Multi-Session Manager, UI Chrome, and Frontend subsystems.
App :: struct {
	session_mgr:         Session_Manager,
	using backend:       Backend, // Active tab backend fallback for tests/headless
	using frontend:      Frontend,
	tab_bar:             platform_tabs.Tab_Bar_State,
	tab_rects:           [MAX_TABS]platform_tabs.Rect_f32,
	search_bar:          platform_chrome.Search_Bar_State,
	tab_drag:            platform_tabs.Tab_Drag_State,
	tab_menu:            platform_tabs.Tab_Menu_State,
	tab_rename:          platform_tabs.Tab_Rename_State,
	tab_overflow:        platform_tabs.Tab_Overflow_State,
	ui_theme:            ui.UI_Theme,
	base_title:          string,
	hud_active:          bool,
	confirm_dialog:      platform_dialogs.Confirm_Dialog_State,
	drag_region:         win.Drag_Region,
	drop_fx:             Drop_Fx_State,
	pty_monitor_thread:  ^odin_thread.Thread,
	pty_monitor_running: b32,
	pty_event_pending:   b32,
	pending_wake_event:  sdl3.Event,
	has_wake_event:      bool,
}

pty_monitor_proc :: proc(t: ^odin_thread.Thread) {
	a := (^App)(t.data)
	if a == nil do return

	pfds: [MAX_TABS + 1]posix.pollfd

	for sync.atomic_load(&a.pty_monitor_running) {
		count := 0

		// Gather active PTY master file descriptors across all tabs
		for i in 0 ..< len(a.session_mgr.tabs) {
			s := &a.session_mgr.tabs[i]
			if s.backend.pty.state == .Running && s.backend.pty.master >= 0 {
				if count < len(pfds) {
					pfds[count] = posix.pollfd{fd = posix.FD(s.backend.pty.master), events = {.IN}}
					count += 1
				}
			}
		}

		// Also check single backend fallback if no tabs
		if count == 0 && a.backend.pty.state == .Running && a.backend.pty.master >= 0 {
			pfds[0] = posix.pollfd{fd = posix.FD(a.backend.pty.master), events = {.IN}}
			count = 1
		}

		if count == 0 {
			time.sleep(10 * time.Millisecond)
			continue
		}

		r := posix.poll(&pfds[0], posix.nfds_t(count), 50)
		if r > 0 {
			has_data := false
			for i in 0 ..< count {
				if (pfds[i].revents & {.IN, .HUP, .ERR}) != {} {
					has_data = true
					break
				}
			}
			if has_data {
				if !sync.atomic_load(&a.pty_event_pending) {
					sync.atomic_store(&a.pty_event_pending, true)
					user_ev: sdl3.Event
					user_ev.type = PTY_DATA_READY
					_ = sdl3.PushEvent(&user_ev)
				}
				time.sleep(1 * time.Millisecond)
			}
		}
	}
}


// app_active_backend resolves the currently active session backend.
app_active_backend :: proc(a: ^App) -> ^Backend {
	if a == nil do return nil
	if len(a.session_mgr.tabs) > 0 && a.session_mgr.active_idx >= 0 && a.session_mgr.active_idx < len(a.session_mgr.tabs) {
		return &a.session_mgr.tabs[a.session_mgr.active_idx].backend
	}
	return &a.backend
}

// app_global holds the active App pointer for callbacks.
app_global: ^App

// _app_tab_index_by_id resolves a tab's logical index by its stable id, or -1.
_app_tab_index_by_id :: proc(a: ^App, id: u32) -> int {
	if a == nil do return -1
	for i in 0 ..< len(a.session_mgr.tabs) {
		if a.session_mgr.tabs[i].id == id do return i
	}
	return -1
}

// _app_active_tab_id returns the stable id of the focused tab, or 0 when none.
_app_active_tab_id :: proc(a: ^App) -> u32 {
	if a == nil do return 0
	idx := a.session_mgr.active_idx
	if idx < 0 || idx >= len(a.session_mgr.tabs) do return 0
	return a.session_mgr.tabs[idx].id
}

// _app_begin_tab_drag arms a tab reorder gesture from a press at (px, py).
_app_begin_tab_drag :: proc(a: ^App, tab_idx: int, px, py: f32) {
	if a == nil do return
	if tab_idx < 0 || tab_idx >= len(a.session_mgr.tabs) do return
	tab_id := a.session_mgr.tabs[tab_idx].id
	_ = platform_tabs.tab_drag_begin(&a.tab_drag, tab_idx, tab_id, px, py)
}

// _app_commit_tab_drop maps a drop boundary to a final index and reorders the
// session manager, then rebinds modals and arms the tab chrome animation.
_app_commit_tab_drop :: proc(a: ^App, from_idx, drop_gap: int) {
	if a == nil do return
	to_idx := drop_gap
	if to_idx > from_idx do to_idx -= 1
	_ = session_reorder_tab(&a.session_mgr, from_idx, to_idx)
	_app_resync_tab_modals(a)
	platform_tabs.tab_bar_anim_activate(&a.tab_bar)
	a.renderer.full_redraw_pending = true
}

// _app_begin_tab_rename starts inline editing on a tab seeded with its display title.
_app_begin_tab_rename :: proc(a: ^App, tab_idx: int) {
	if a == nil do return
	if tab_idx < 0 || tab_idx >= len(a.session_mgr.tabs) do return
	tab := &a.session_mgr.tabs[tab_idx]
	title := session_title_display(tab)
	_ = platform_tabs.tab_rename_begin(&a.tab_rename, tab_idx, tab.id, title)
	a.renderer.full_redraw_pending = true
}

// _app_commit_tab_rename applies the edit buffer; an empty buffer clears the override.
_app_commit_tab_rename :: proc(a: ^App) {
	if a == nil || !a.tab_rename.active do return
	tab_idx := _app_tab_index_by_id(a, a.tab_rename.tab_id)
	if tab_idx >= 0 {
		text := platform_tabs.tab_rename_text(&a.tab_rename)
		if len(text) == 0 {
			_ = session_clear_title_override(&a.session_mgr.tabs[tab_idx])
		} else {
			_ = session_set_title_override(&a.session_mgr.tabs[tab_idx], text)
		}
	}
	_app_cancel_tab_rename(a)
}

// _app_cancel_tab_rename abandons the edit session.
_app_cancel_tab_rename :: proc(a: ^App) {
	if a == nil do return
	platform_tabs.tab_rename_cancel(&a.tab_rename)
	a.renderer.full_redraw_pending = true
}

// _app_resync_tab_modals rebinds the menu and rename state by stable tab id,
// closing or cancelling when their target tab has disappeared.
_app_resync_tab_modals :: proc(a: ^App) {
	if a == nil do return
	if a.tab_menu.visible {
		idx := _app_tab_index_by_id(a, a.tab_menu.target_id)
		if idx < 0 {
			platform_tabs.tab_menu_close(&a.tab_menu)
		} else {
			a.tab_menu.target_idx = idx
		}
	}
	if a.tab_rename.active {
		idx := _app_tab_index_by_id(a, a.tab_rename.tab_id)
		if idx < 0 {
			platform_tabs.tab_rename_cancel(&a.tab_rename)
		} else {
			a.tab_rename.tab_idx = idx
		}
	}
}

// _app_build_ui_tabs snapshots tab display metadata for chrome rendering and
// overflow refresh. Titles borrow session buffers and are valid only during the call.
_app_build_ui_tabs :: proc(a: ^App, out: []platform_tabs.Tab_Info) -> int {
	if a == nil do return 0
	n := min(len(a.session_mgr.tabs), len(out))
	for i in 0 ..< n {
		t := &a.session_mgr.tabs[i]
		out[i] = platform_tabs.Tab_Info{
			id        = t.id,
			title     = session_title_display(t),
			is_active = (i == a.session_mgr.active_idx),
			is_exited = (t.status == .Exited),
			has_bell  = t.has_bell,
		}
	}
	return n
}

// _app_open_tab_overflow toggles the all-tabs dropdown. It only opens when the
// tab bar is actually overflowing, seeding selection with the active tab.
_app_open_tab_overflow :: proc(a: ^App) {
	if a == nil do return
	if a.tab_overflow.visible {
		platform_tabs.tab_overflow_close(&a.tab_overflow)
		_app_set_drag_region(a)
		a.renderer.full_redraw_pending = true
		return
	}
	if a.tab_bar.overflow_rect.w <= 0 do return
	a.tab_overflow = platform_tabs.Tab_Overflow_State{visible = true, selected_tab_id = _app_active_tab_id(a)}
	_app_layout_ui(a)
	_app_set_drag_region(a)
	a.renderer.full_redraw_pending = true
}

// _app_activate_overflow_selection switches to the dropdown's selected tab and closes it.
_app_activate_overflow_selection :: proc(a: ^App) {
	if a == nil do return
	idx := _app_tab_index_by_id(a, a.tab_overflow.selected_tab_id)
	if idx >= 0 {
		_ = session_switch_tab(&a.session_mgr, idx)
		_ = platform_tabs.tab_bar_scroll_to_tab(&a.tab_bar, idx)
	}
	platform_tabs.tab_overflow_close(&a.tab_overflow)
	_app_resync_tab_modals(a)
	platform_tabs.tab_bar_anim_activate(&a.tab_bar)
	_app_set_drag_region(a)
	a.renderer.full_redraw_pending = true
}

// _app_execute_tab_menu performs a chosen context menu action against its target tab.
_app_execute_tab_menu :: proc(a: ^App, item: platform_tabs.Tab_Menu_Item, target_idx: int) {
	if a == nil do return
	switch item {
	case .Close:
		_app_request_close_tab(a, target_idx)
	case .Close_Others:
		_ = session_close_others(&a.session_mgr, target_idx)
	case .Close_To_Right:
		_ = session_close_to_right(&a.session_mgr, target_idx)
	case .New_Tab:
		shell, _ := _resolve_shell()
		shell_argv := _resolve_shell_argv(shell)
		rows := a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS
		cols := a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS
		new_idx, spawn_ok := session_spawn(&a.session_mgr, shell, shell_argv, rows, cols, &a.config, a.renderer.theme)
		if spawn_ok {
			new_b := &a.session_mgr.tabs[new_idx].backend
			backend_set_clipboard_callbacks(new_b, &a.frontend, _frontend_clipboard_write_cb, _frontend_clipboard_read_cb)
			session_switch_tab(&a.session_mgr, new_idx)
		}
	case .Rename:
		_app_begin_tab_rename(a, target_idx)
	}
	_app_resync_tab_modals(a)
	platform_tabs.tab_bar_anim_activate(&a.tab_bar)
	a.renderer.full_redraw_pending = true
}

// _app_close_tab_confirmed closes the tab at idx and rebinds the chrome modals
// that pointed at it. Closing the final tab requests application quit.
_app_close_tab_confirmed :: proc(a: ^App, idx: int) {
	if a == nil do return
	if idx < 0 || idx >= len(a.session_mgr.tabs) do return
	_ = session_close_tab(&a.session_mgr, idx)
	if len(a.session_mgr.tabs) == 0 do a.should_quit = true
	a.renderer.full_redraw_pending = true
	_app_resync_tab_modals(a)
}

// _app_request_close_tab opens the in-app confirm dialog when the tab still has
// a running process, otherwise it closes the tab immediately.
_app_request_close_tab :: proc(a: ^App, idx: int) {
	if a == nil do return
	if idx < 0 || idx >= len(a.session_mgr.tabs) do return
	tab := &a.session_mgr.tabs[idx]
	if pty.pty_has_running_processes(&tab.backend.pty) {
		platform_dialogs.confirm_dialog_show(&a.confirm_dialog, idx, tab.id)
		a.renderer.full_redraw_pending = true
		_app_set_drag_region(a)
		return
	}
	_app_close_tab_confirmed(a, idx)
}

// _app_apply_confirm_action resolves a dialog action against its target tab,
// hides the dialog, and refreshes the drag region and a full redraw.
_app_apply_confirm_action :: proc(a: ^App, action: platform_dialogs.Confirm_Dialog_Action) {
	if a == nil do return
	switch action {
	case .Confirm:
		idx := _app_tab_index_by_id(a, a.confirm_dialog.target_tab_id)
		platform_dialogs.confirm_dialog_hide(&a.confirm_dialog)
		if idx >= 0 do _app_close_tab_confirmed(a, idx)
	case .Cancel:
		platform_dialogs.confirm_dialog_hide(&a.confirm_dialog)
	case .None:
	}
	_app_set_drag_region(a)
	a.renderer.full_redraw_pending = true
}

// _app_set_drag_region syncs the OS window-move region to the trailing toolbar
// area, disabling it whenever a modal surface (dialog/menu/rename) owns input.
_app_set_drag_region :: proc(a: ^App) {
	if a == nil do return
	dr := a.tab_bar.drag_rect
	enabled := dr.w > 0 && dr.h > 0 && !a.confirm_dialog.visible && !a.tab_menu.visible && !a.tab_rename.active && !a.tab_overflow.visible
	a.drag_region = win.Drag_Region{
		x = dr.x, y = dr.y, w = dr.w, h = dr.h,
		enabled = enabled,
		pending_double_click = a.drag_region.pending_double_click,
		last_native_event = a.drag_region.last_native_event,
	}
	_ = win.window_set_drag_region(&a.window, &a.drag_region)
}

_app_response_cb :: _backend_response_cb
_app_clipboard_cb :: _backend_clipboard_cb
_app_clipboard_read_cb :: _backend_clipboard_read_cb

// app_init initializes Frontend and Backend subsystems in order.
app_init :: proc(a: ^App, rows, cols: int, prog: string, argv: []string) -> bool {
	if a == nil {
		return false
	}
	a.pty.master = -1
	a.pty.pid = -1
	if len(prog) == 0 {
		return false
	}

	load_ok: bool
	a.config, load_ok = config.config_load()
	if !load_ok {
		a.config = config.config_default()
	}

	if len(a.config.locale) > 0 {
		i18n.i18n_init(i18n.i18n_locale_from_string(a.config.locale))
	} else {
		i18n.i18n_init(i18n.i18n_locale_from_env())
	}

	app_theme := termgrid.Theme{
		name                 = a.config.theme_name,
		foreground           = a.config.foreground,
		background           = a.config.background,
		selection_foreground = a.config.selection_foreground,
		selection_background = a.config.selection_background,
		ansi16               = a.config.ansi16,
		palette_256_policy   = .Xterm_Cube_Grayscale,
	}

	eff_cols := a.config.cols if a.config.cols > 0 && cols == APP_DEFAULT_COLS else cols
	eff_rows := a.config.rows if a.config.rows > 0 && rows == APP_DEFAULT_ROWS else rows
	app_title := a.config.title if len(a.config.title) > 0 else APP_TITLE

	// (1) Frontend initialization (window, GPU device, queue, surface, renderer)
	cell_w, cell_h, pad_x, pad_y, front_ok := frontend_init(
		&a.frontend,
		app_title,
		eff_rows,
		eff_cols,
		&a.config,
		app_theme,
	)
	if !front_ok {
		config.config_destroy(&a.config)
		return false
	}

	init_rows, init_cols := grid_dimensions_for_pixels(
		a.window.pixel_w, a.window.pixel_h, cell_w, cell_h, pad_x, pad_y,
	)

	// (2) Session Manager & UI Chrome initialization
	session_manager_init(&a.session_mgr, MAX_TABS)
	platform_tabs.tabs_init(&a.tab_bar)
	platform_chrome.search_bar_init(&a.search_bar)
	platform_tabs.tab_drag_reset(&a.tab_drag)
	platform_tabs.tab_menu_init(&a.tab_menu)
	platform_tabs.tab_rename_init(&a.tab_rename)
	platform_dialogs.confirm_dialog_init(&a.confirm_dialog)
	platform_tabs.tab_overflow_close(&a.tab_overflow)
	a.ui_theme = ui.theme_catppuccin_mocha()
	a.should_quit = false

	// The window exists after frontend_init; install the (inert) drag region now
	// and let each layout pass refresh its bounds.
	_ = win.window_set_drag_region(&a.window, &a.drag_region)

	// (3) Spawn initial Tab Session
	spawn_idx, spawn_ok := session_spawn(&a.session_mgr, prog, argv, init_rows, init_cols, &a.config, app_theme)
	if !spawn_ok {
		session_manager_destroy(&a.session_mgr)
		frontend_destroy(&a.frontend)
		config.config_destroy(&a.config)
		return false
	}
	active_b := &a.session_mgr.tabs[spawn_idx].backend
	platform_tabs.tab_bar_anim_activate(&a.tab_bar)

	// Connect decoupled clipboard callbacks from Backend to Frontend
	backend_set_clipboard_callbacks(
		active_b,
		&a.frontend,
		_frontend_clipboard_write_cb,
		_frontend_clipboard_read_cb,
	)
	app_global = a

	render.renderer_resize_grid(&a.renderer, &active_b.terminal, i32(init_rows), i32(init_cols))
	_app_sync_focus(a)
	a.last_px_w = a.window.pixel_w
	a.last_px_h = a.window.pixel_h
	a.base_title = app_title
	a.hud_active = false

	if a.debug_frames {
		valid := 0
		for i in 0..<len(a.renderer.atlas.slots) {
			if a.renderer.atlas.slots[i].valid {
				valid += 1
			}
		}
		fmt.eprintf(
			"app_debug: init rows=%d cols=%d atlas_valid=%d/%d surface=%dx%d strategy=%v font='%s'\n",
			active_b.terminal.grid.row_count,
			active_b.terminal.grid.col_count,
			valid,
			len(a.renderer.atlas.slots),
			a.renderer.surface_w,
			a.renderer.surface_h,
			a.renderer.strategy,
			a.font_path,
		)
	}

	_ = sdl3.AddEventWatch(_app_event_watch, a)

	sync.atomic_store(&a.pty_monitor_running, true)
	sync.atomic_store(&a.pty_event_pending, false)
	a.pty_monitor_thread = odin_thread.create(pty_monitor_proc)
	if a.pty_monitor_thread != nil {
		a.pty_monitor_thread.data = a
		odin_thread.start(a.pty_monitor_thread)
	}

	return true
}

// app_destroy tears down Session Manager and Frontend in order.
app_destroy :: proc(a: ^App) {
	if a == nil {
		return
	}
	if a.pty_monitor_thread != nil {
		sync.atomic_store(&a.pty_monitor_running, false)
		odin_thread.join(a.pty_monitor_thread)
		odin_thread.destroy(a.pty_monitor_thread)
		a.pty_monitor_thread = nil
	}
	sdl3.RemoveEventWatch(_app_event_watch, a)
	session_manager_destroy(&a.session_mgr)
	if a.backend.drain_buf != nil {
		backend_destroy(&a.backend)
	}
	profile_ring_stop_and_join(&_profile_ring)
	if _profile_scenario_initialized {
		status_path, status_ok := os.lookup_env("TERM_PROFILE_RESIZE_STATUS_FILE", context.temp_allocator)
		if status_ok && len(status_path) > 0 {
			status := "invalid"
			reason := _profile_failure_reason
			if _profile_scenario.phase != .Complete && reason == .None { reason = .Scenario_Failed }
			if _profile_scenario.phase == .Complete {
				if sync.atomic_load(&_profile_export_failed) {
					reason = .Telemetry_Export_Failed
				} else if sync.atomic_load(&_profile_ring.dropped) != 0 {
					status = "valid"
					reason = .Telemetry_Dropped_Records
				} else {
					status = "valid"
					reason = .None
				}
			}
			status_text := fmt.tprintf("%s\nreason=%s\nresize_kind=%v\n", status, profile_failure_reason_name(reason), _profile_failure_kind)
			_ = os.write_entire_file(status_path, status_text)
		}
	}
	_ = win.window_clear_drag_region(&a.window)
	frontend_destroy(&a.frontend)
	config.config_destroy(&a.config)
}

_app_sync_focus :: proc(a: ^App) {
	if a == nil || a.window.handle == nil {
		return
	}
	flags := sdl3.GetWindowFlags(a.window.handle)
	b := app_active_backend(a)
	if b != nil {
		backend_set_focused(b, .INPUT_FOCUS in flags)
	}
}

_app_pointer_cell :: proc(a: ^App, x, y: f32) -> termgrid.Terminal_Point {
	if a == nil {
		return termgrid.Terminal_Point{}
	}
	b := app_active_backend(a)
	if b == nil do return termgrid.Terminal_Point{}
	return frontend_pointer_cell(&a.frontend, b.terminal.grid.row_count, b.terminal.grid.col_count, x, y)
}

_app_pointer_point :: proc(a: ^App, x, y: f32) -> termgrid.Terminal_Point {
	viewport := _app_pointer_cell(a, x, y)
	b := app_active_backend(a)
	if b == nil do return termgrid.Terminal_Point{}
	return termgrid.terminal_view_point_from_viewport(
		&b.terminal,
		&b.view,
		viewport,
	)
}

_app_pointer_wheel_delta :: backend_pointer_wheel_delta
_app_pointer_selection_changed :: backend_pointer_selection_changed

_app_route_pointer :: proc(a: ^App, pointer: input.Input_Pointer_Event) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false

	if b.terminal.mouse_tracking != .None && !pointer.shift {
		pt := _app_pointer_cell(a, pointer.x, pointer.y)
		col := clamp(pt.col + 1, 1, max(1, b.terminal.grid.col_count))
		row := clamp(pt.row + 1, 1, max(1, b.terminal.grid.row_count))

		if pointer.kind == .Wheel {
			delta := backend_accumulate_wheel(b, pointer)
			if delta == 0 {
				return true
			}
			p_wheel := pointer
			p_wheel.wheel_y = 1 if delta > 0 else -1
			p_wheel.wheel_integer_y = 1 if delta > 0 else -1
			buf: [32]u8
			n := input.mouse_encode_sgr(p_wheel, col, row, pointer.shift, buf[:])
			if n > 0 {
				for _ in 0 ..< abs(delta) {
					_ = pty.pty_write(&b.pty, buf[:n])
				}
			}
			b.last_mouse_col = col
			b.last_mouse_row = row
			return true
		}

		if pointer.kind == .Motion {
			if b.terminal.mouse_tracking == .Normal {
				return true
			}
			if b.terminal.mouse_tracking == .Button_Event && !pointer.primary_down && pointer.button == 0 {
				return true
			}
			if col == b.last_mouse_col && row == b.last_mouse_row {
				return true
			}
		}

		buf: [32]u8
		n := input.mouse_encode_sgr(pointer, col, row, pointer.shift, buf[:])
		if n > 0 {
			_ = pty.pty_write(&b.pty, buf[:n])
		}
		b.last_mouse_col = col
		b.last_mouse_row = row
		return true
	}

	pt_viewport := _app_pointer_cell(a, pointer.x, pointer.y)
	doc_pt := termgrid.terminal_view_point_from_viewport(&b.terminal, &b.view, pt_viewport)
	p_doc := pointer
	p_doc.x = f32(doc_pt.col * APP_CELL_W)
	p_doc.y = f32(doc_pt.row * APP_CELL_H)
	total_doc_rows := termgrid.scrollback_len(&b.terminal.scrollback) + b.terminal.grid.row_count

	consumed, action := inter.interaction_dispatch_pointer(
		&b.interaction,
		p_doc,
		b.terminal.is_alt_screen,
		total_doc_rows,
		b.terminal.grid.col_count,
		APP_CELL_W,
		APP_CELL_H,
	)

	if consumed {
		if pointer.kind == .Button_Down && pointer.button == 1 {
			clicks := pointer.clicks == 0 ? 1 : pointer.clicks
			if clicks == 2 {
				start, end := inter.interaction_select_word_bounds(&b.terminal, doc_pt)
				b.interaction.selection_anchor = start
				b.interaction.visual_cursor = end
			} else if clicks >= 3 {
				start, end := inter.interaction_select_line_bounds(&b.terminal, doc_pt)
				b.interaction.selection_anchor = start
				b.interaction.visual_cursor = end
			}
		}

		switch action {
		case .Copy:
			text := inter.interaction_extract_selection_text(&b.terminal, &b.interaction)
			if len(text) > 0 {
				_app_clipboard_cb(transmute([]u8)text)
				delete(text)
			}
			termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
			b.view_generation += 1
		case .Resume_Live:
			termgrid.terminal_view_set_offset(&b.view, &b.terminal, 0)
			b.view_generation += 1
		case .Scroll_To_Match:
			if b.interaction.search_active && b.interaction.search_match_count > 0 {
				match_row := b.interaction.search_matches[b.interaction.search_match_idx].row
				sb_len := termgrid.scrollback_len(&b.terminal.scrollback)
				target_offset := max(0, sb_len - match_row)
				termgrid.terminal_view_set_offset(&b.view, &b.terminal, target_offset)
				b.view_generation += 1
			}
		case .Paste, .None:
		case .Open_Link:
			term_ref := &b.front_terminal if backend_is_threaded(b) else &b.terminal
			target := inter.interaction_detect_link_at_point(term_ref, doc_pt)
			if target.kind == .URL {
				url_str := string(target.text[:target.len])
				_ = sdl3.OpenURL(fmt.ctprintf("%s", url_str))
			} else if target.kind == .Path {
				path_str := string(target.text[:target.len])
				clean_path := path_str
				colon_idx := strings.index(path_str, ":")
				if colon_idx > 0 {
					clean_path = path_str[:colon_idx]
				}
				if strings.has_prefix(clean_path, "~/") {
					home := os.get_env("HOME", context.temp_allocator)
					clean_path = fmt.tprintf("%s/%s", home, clean_path[2:])
				}
				when ODIN_OS == .Darwin {
					c_prog := strings.clone_to_cstring("/usr/bin/open", context.temp_allocator)
					c_opt := strings.clone_to_cstring("--", context.temp_allocator)
					c_path := strings.clone_to_cstring(clean_path, context.temp_allocator)
					c_argv := [4]cstring{c_prog, c_opt, c_path, nil}
					pid := posix.fork()
					if pid == 0 {
						if posix.fork() == 0 {
							posix.close(0)
							posix.close(1)
							posix.close(2)
							posix.execvp(c_prog, raw_data(c_argv[:]))
							posix._exit(1)
						}
						posix._exit(0)
					}
					if pid > 0 {
						posix.waitpid(pid, nil, {})
					}
				}
			}
		}

		b.view.selection.active = b.interaction.selection_active
		b.view.selection.anchor = b.interaction.selection_anchor
		b.view.selection.focus = b.interaction.visual_cursor
		b.view.selection.block = (b.interaction.visual_kind == .Block)
		b.view.visual_mode = (b.interaction.mode == .Visual)
		b.view_generation += 1
		return true
	}

	switch pointer.kind {
	case .Wheel:
		if b.terminal.is_alt_screen {
			delta := backend_accumulate_wheel(b, pointer)
			if delta == 0 {
				return true
			}
			alt_lines := b.config.alt_screen_wheel_lines if b.config.alt_screen_wheel_lines > 0 else APP_ALT_SCREEN_WHEEL_LINES
			steps := abs(delta) * alt_lines
			code: u8 = 'A' if delta > 0 else 'B'
			seq: [3]u8
			if b.terminal.app_cursor_keys {
				seq = {0x1B, 'O', code}
			} else {
				seq = {0x1B, '[', code}
			}
			for _ in 0 ..< steps {
				_ = pty.pty_write(&b.pty, seq[:])
			}
			return true
		}
		delta := backend_accumulate_wheel(b, pointer)
		old_offset := b.view.scrollback_offset
		_ = termgrid.terminal_view_scroll(&b.view, &b.terminal, delta)
		if old_offset != b.view.scrollback_offset {
			if b.view.scrollback_offset > 0 && b.interaction.viewport_flow == .Live {
				inter.interaction_pause_viewport(&b.interaction, b.view.scrollback_offset)
			} else if b.view.scrollback_offset == 0 && b.interaction.mode == .Passthrough {
				inter.interaction_resume_viewport(&b.interaction)
			}
			b.view_generation += 1
			a.renderer.full_redraw_pending = true
			if backend_is_threaded(b) {
				b.front_view = b.view
			}
		}
	case .Button_Down:
		if pointer.button != 1 {
			return true
		}
		point := _app_pointer_point(a, pointer.x, pointer.y)
		_ = _app_pointer_selection_changed(b, point, true)
		_ = win.window_capture_mouse(&a.window, true)
	case .Motion:
		if b.view.selection.active && b.view.selection.anchor != b.view.selection.focus && !pointer.primary_down {
			return true
		}
		if b.view.selection.active && pointer.primary_down {
			point := _app_pointer_point(a, pointer.x, pointer.y)
			_ = _app_pointer_selection_changed(b, point, false)
		}
	case .Button_Up:
		if pointer.button != 1 {
			return true
		}
		if b.view.selection.active {
			point := _app_pointer_point(a, pointer.x, pointer.y)
			_ = _app_pointer_selection_changed(b, point, false)
		}
		_ = win.window_capture_mouse(&a.window, false)
	}
	return true
}

_app_copy_selection :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false
	copied: string
	if backend_is_threaded(b) {
		if b.front_interaction.selection_active {
			copied = inter.interaction_extract_selection_text(&b.front_terminal, &b.front_interaction)
		} else {
			copied = backend_copy_selection(b)
		}
	} else {
		if b.interaction.selection_active {
			copied = inter.interaction_extract_selection_text(&b.terminal, &b.interaction)
		} else {
			copied = backend_copy_selection(b)
		}
	}
	defer delete(copied)
	if len(copied) == 0 {
		return false
	}
	return win.window_set_clipboard_text(&a.window, copied)
}

_app_paste_clipboard :: proc(a: ^App) -> bool {
	b := app_active_backend(a)
	if a == nil || b == nil || b.pty.state == .Exited {
		return false
	}
	text := win.window_get_clipboard_text(&a.window)
	if len(text) == 0 {
		delete(text)
		return true
	}
	if backend_is_threaded(b) {
		return backend_push_event(b, UI_Event{type = .Paste, text = text})
	}
	defer delete(text)
	return backend_paste(b, text)
}

// _app_shell_quote_path wraps a file path in single quotes for shell safety.
// Embedded single quotes are escaped as '\''.
// Caller must delete the returned string.
_app_shell_quote_path :: proc(path: string) -> string {
	if len(path) == 0 {
		return strings.clone("")
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '\'')
	for ch in path {
		if ch == '\'' {
			strings.write_string(&b, "'\\''")
		} else {
			strings.write_rune(&b, ch)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.clone(strings.to_string(b))
}

_app_request_zoom :: proc(a: ^App, direction: int) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false
	return frontend_request_zoom(&a.frontend, b.pty.state, direction)
}

_app_apply_zoom :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false
	return frontend_apply_zoom(&a.frontend, &b.terminal, &b.pty)
}

app_reload_config :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	new_cfg, ok := config.config_load()
	if !ok {
		config.config_destroy(&new_cfg)
		return false
	}

	theme := termgrid.Theme{
		name                 = new_cfg.theme_name,
		foreground           = new_cfg.foreground,
		background           = new_cfg.background,
		selection_foreground = new_cfg.selection_foreground,
		selection_background = new_cfg.selection_background,
		ansi16               = new_cfg.ansi16,
		palette_256_policy   = .Xterm_Cube_Grayscale,
	}

	theme_changed := new_cfg.theme_name != a.config.theme_name ||
		new_cfg.foreground != a.config.foreground ||
		new_cfg.background != a.config.background ||
		new_cfg.selection_foreground != a.config.selection_foreground ||
		new_cfg.selection_background != a.config.selection_background ||
		new_cfg.ansi16 != a.config.ansi16

	if theme_changed {
		for &tab in a.session_mgr.tabs {
			backend_apply_theme(&tab.backend, theme)
		}
		if active_b := app_active_backend(a); active_b != nil && len(a.session_mgr.tabs) == 0 {
			backend_apply_theme(active_b, theme)
		}
		frontend_apply_theme(&a.frontend, theme)
	}

	if new_cfg.font_size > 0 && new_cfg.font_size != a.config.font_size {
		a.zoom_target_logical_size = new_cfg.font_size
		_ = _app_apply_zoom(a)
	}

	config.config_destroy(&a.config)
	a.config = new_cfg
	return true
}

app_dispatch_input_events :: proc(a: ^App, evs: []input.Input_Event) -> (quit: bool, ok: bool) {
	if a == nil {
		return true, false
	}
	active_b := app_active_backend(a)
	if active_b == nil {
		return true, false
	}
	ok = true
	for ev in evs {
		active_b = app_active_backend(a)
		if active_b == nil || a.should_quit do break
		if ev.paste_shadow && !a.tab_rename.active && !a.search_bar.visible do continue

		if ev.event_type == .Drop {
			drop_fx_handle(&a.drop_fx, ev.drop)
		}

		// (0) Confirm dialog modal gate: while visible it owns every event so
		// nothing leaks to the terminal, the menu, or the hotkey router.
		if a.confirm_dialog.visible {
			switch ev.event_type {
			case .Key:
				_, c_action := platform_dialogs.confirm_dialog_dispatch_key(&a.confirm_dialog, ev)
				_app_apply_confirm_action(a, c_action)
				continue
			case .Pointer:
				_, c_action := platform_dialogs.confirm_dialog_dispatch_pointer(
					&a.confirm_dialog,
					ev.pointer.x,
					ev.pointer.y,
					ev.pointer.kind == .Button_Down && ev.pointer.button == sdl3.BUTTON_LEFT,
				)
				_app_apply_confirm_action(a, c_action)
				continue
			case .Local:
				continue
			case .Drop:
				if len(ev.drop.text) > 0 {
					delete(ev.drop.text)
				}
				continue
			}
		}

		// (0) Modal tab chrome: inline rename then context menu own every key event.
		if ev.event_type == .Key {
			if a.tab_rename.active {
				consumed, r_action := platform_tabs.tab_rename_dispatch_key(&a.tab_rename, ev)
				if consumed {
					switch r_action {
					case .Commit:
						_app_commit_tab_rename(a)
					case .Cancel:
						_app_cancel_tab_rename(a)
					case .Changed, .None:
						a.renderer.full_redraw_pending = true
					}
					continue
				}
			} else if a.tab_menu.visible {
				consumed, m_action, item := platform_tabs.tab_menu_dispatch_key(&a.tab_menu, ev, len(a.session_mgr.tabs), a.session_mgr.max_tabs)
				if consumed {
					switch m_action {
					case .Activated:
						_app_execute_tab_menu(a, item, a.tab_menu.target_idx)
						platform_tabs.tab_menu_close(&a.tab_menu)
					case .Dismissed:
						platform_tabs.tab_menu_close(&a.tab_menu)
					case .None:
					}
					a.renderer.full_redraw_pending = true
					continue
				}
			} else if a.tab_overflow.visible {
				tabs_tmp: [MAX_TABS]platform_tabs.Tab_Info
				n := _app_build_ui_tabs(a, tabs_tmp[:])
				o_action := platform_tabs.tab_overflow_dispatch_key(&a.tab_overflow, tabs_tmp[:n], ev)
				switch o_action {
				case .Activate:
					_app_activate_overflow_selection(a)
				case .Dismiss:
					platform_tabs.tab_overflow_close(&a.tab_overflow)
					_app_set_drag_region(a)
					a.renderer.full_redraw_pending = true
				case .None:
					a.renderer.full_redraw_pending = true
				}
				continue
			}
		}

		// (1) Global Hotkey Router
		if ev.event_type == .Key && !ev.is_release {
			if ev.ctrl && !ev.gui && !ev.alt {
				if ev.kind == .Tab {
					if len(a.session_mgr.tabs) > 0 {
						if ev.shift {
							prev_idx := (a.session_mgr.active_idx - 1 + len(a.session_mgr.tabs)) % len(a.session_mgr.tabs)
							session_switch_tab(&a.session_mgr, prev_idx)
						} else {
							next_idx := (a.session_mgr.active_idx + 1) % len(a.session_mgr.tabs)
							session_switch_tab(&a.session_mgr, next_idx)
						}
						_app_resync_tab_modals(a)
						platform_tabs.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
						continue
					}
				}
			}

			if ev.gui {
				if ev.alt && (ev.rune == 'd' || ev.rune == 'D') {
					if ev.shift {
						_ = session_close_to_right(&a.session_mgr, a.session_mgr.active_idx)
					} else {
						_ = session_close_others(&a.session_mgr, a.session_mgr.active_idx)
					}
					_app_resync_tab_modals(a)
					platform_tabs.tab_bar_anim_activate(&a.tab_bar)
					a.renderer.full_redraw_pending = true
					continue
				}
				if ev.shift && (ev.rune == '\\' || ev.rune == '|') {
					_app_open_tab_overflow(a)
					continue
				}
				if ev.ctrl && (ev.rune == 'z' || ev.rune == 'Z') {
					_ = win.window_zoom(&a.window)
					win.window_update_pixel_size(&a.window)
					a.renderer.full_redraw_pending = true
					continue
				}
				if !ev.shift && !ev.alt && !ev.ctrl && (ev.rune == 'r' || ev.rune == 'R') {
					_app_begin_tab_rename(a, a.session_mgr.active_idx)
					continue
				}
				if ev.rune == 't' || ev.rune == 'T' {
					shell, _ := _resolve_shell()
					shell_argv := _resolve_shell_argv(shell)
					rows := a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS
					cols := a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS
					new_idx, spawn_ok := session_spawn(&a.session_mgr, shell, shell_argv, rows, cols, &a.config, a.renderer.theme)
					if spawn_ok {
						new_b := &a.session_mgr.tabs[new_idx].backend
						backend_set_clipboard_callbacks(new_b, &a.frontend, _frontend_clipboard_write_cb, _frontend_clipboard_read_cb)
						session_switch_tab(&a.session_mgr, new_idx)
						_app_resync_tab_modals(a)
						ui.tab_bar_anim_activate(&a.tab_bar)
					}
					a.renderer.full_redraw_pending = true
					continue
				} else if ev.rune == 'd' || ev.rune == 'D' {
					_app_request_close_tab(a, a.session_mgr.active_idx)
					continue
				} else if ev.shift && (ev.rune == '[' || ev.rune == '{') {
					if len(a.session_mgr.tabs) > 0 {
						prev_idx := (a.session_mgr.active_idx - 1 + len(a.session_mgr.tabs)) % len(a.session_mgr.tabs)
						session_switch_tab(&a.session_mgr, prev_idx)
						_app_resync_tab_modals(a)
						ui.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
					}
					continue
				} else if ev.shift && (ev.rune == ']' || ev.rune == '}') {
					if len(a.session_mgr.tabs) > 0 {
						next_idx := (a.session_mgr.active_idx + 1) % len(a.session_mgr.tabs)
						session_switch_tab(&a.session_mgr, next_idx)
						_app_resync_tab_modals(a)
						ui.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
					}
					continue
				} else if ev.rune == 'f' || ev.rune == 'F' {
					a.search_bar.visible = !a.search_bar.visible
					if a.search_bar.visible {
						_app_layout_ui(a)
						inter.interaction_enter_search(&active_b.interaction)
						if backend_is_threaded(active_b) {
							active_b.front_interaction = active_b.interaction
						}
					} else {
						inter.interaction_exit_to_passthrough(&active_b.interaction)
						if backend_is_threaded(active_b) {
							active_b.front_interaction = active_b.interaction
						}
					}
					a.renderer.full_redraw_pending = true
					continue
				} else if ev.rune == '9' {
					if len(a.session_mgr.tabs) > 0 {
						session_switch_tab(&a.session_mgr, len(a.session_mgr.tabs) - 1)
						_app_resync_tab_modals(a)
						ui.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
						continue
					}
				} else if ev.rune >= '1' && ev.rune <= '8' {
					idx := int(ev.rune - '1')
					if idx < len(a.session_mgr.tabs) {
						session_switch_tab(&a.session_mgr, idx)
						_app_resync_tab_modals(a)
						ui.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
						continue
					}
				}
			}
		}

		// (2) Search Bar Key Dispatch
		if a.search_bar.visible && ev.event_type == .Key {
			consumed, s_action := platform_chrome.search_bar_dispatch_key(&a.search_bar, ev)
			if consumed {
				switch s_action {
				case .Query_Changed:
					_ = platform_chrome.search_bar_execute_scan(&a.search_bar, &active_b.terminal, active_b.interaction.search_matches[:])
					copy(active_b.interaction.search_query[:], a.search_bar.query[:a.search_bar.query_len])
					active_b.interaction.search_len = a.search_bar.query_len
					active_b.interaction.search_match_count = a.search_bar.match_count
					active_b.interaction.search_match_idx = a.search_bar.match_idx
					active_b.interaction.search_active = true
					if a.search_bar.match_count > 0 {
						match_row := active_b.interaction.search_matches[active_b.interaction.search_match_idx].row
						sb_len := termgrid.scrollback_len(&active_b.terminal.scrollback)
						target_offset := clamp(sb_len - match_row, 0, termgrid.terminal_view_max_offset(&active_b.terminal))
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, target_offset)
						active_b.view_generation += 1
						if backend_is_threaded(active_b) {
							active_b.front_view = active_b.view
						}
					}
					if backend_is_threaded(active_b) {
						active_b.front_interaction = active_b.interaction
					}
					a.renderer.full_redraw_pending = true
				case .Next_Match, .Prev_Match:
					if a.search_bar.match_count > 0 {
						if s_action == .Next_Match {
							a.search_bar.match_idx = (a.search_bar.match_idx + 1) % a.search_bar.match_count
						} else {
							a.search_bar.match_idx = (a.search_bar.match_idx - 1 + a.search_bar.match_count) % a.search_bar.match_count
						}
						active_b.interaction.search_match_idx = a.search_bar.match_idx
						match_row := active_b.interaction.search_matches[active_b.interaction.search_match_idx].row
						sb_len := termgrid.scrollback_len(&active_b.terminal.scrollback)
						target_offset := clamp(sb_len - match_row, 0, termgrid.terminal_view_max_offset(&active_b.terminal))
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, target_offset)
						active_b.view_generation += 1
						if backend_is_threaded(active_b) {
							active_b.front_view = active_b.view
							active_b.front_interaction = active_b.interaction
						}
						a.renderer.full_redraw_pending = true
					}
				case .Close:
					a.search_bar.visible = false
					inter.interaction_exit_to_passthrough(&active_b.interaction)
					termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, 0)
					active_b.view_generation += 1
					if backend_is_threaded(active_b) {
						active_b.front_view = active_b.view
						active_b.front_interaction = active_b.interaction
					}
					a.renderer.full_redraw_pending = true
				case .None:
				}
				continue
			}
		}

		switch ev.event_type {
		case .Key:
			state_before := active_b.interaction
			consumed, action := inter.interaction_dispatch_key(&active_b.interaction, ev, active_b.terminal.is_alt_screen)
			if consumed {
				if active_b.interaction.search_active {
					q := string(active_b.interaction.search_query[:active_b.interaction.search_len])
					active_b.interaction.search_match_count = inter.interaction_search_scan(
						&active_b.terminal,
						q,
						active_b.interaction.search_matches[:],
					)
					if active_b.interaction.search_match_idx >= active_b.interaction.search_match_count {
						active_b.interaction.search_match_idx = 0
					}
				}
				switch action {
				case .Copy:
					text := inter.interaction_extract_selection_text(&active_b.terminal, &active_b.interaction)
					if len(text) == 0 && state_before.selection_active {
						text = inter.interaction_extract_selection_text(&active_b.terminal, &state_before)
					}
					if len(text) > 0 {
						_app_clipboard_cb(transmute([]u8)text)
						delete(text)
					}
					termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, 0)
					active_b.view_generation += 1
				case .Resume_Live:
					termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, 0)
					active_b.view_generation += 1
				case .Scroll_To_Match:
					if active_b.interaction.search_active && active_b.interaction.search_match_count > 0 {
						match_row := active_b.interaction.search_matches[active_b.interaction.search_match_idx].row
						sb_len := termgrid.scrollback_len(&active_b.terminal.scrollback)
						target_offset := max(0, sb_len - match_row)
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, target_offset)
						active_b.view_generation += 1
					}
				case .Paste:
					buf: [4096]u8
					n := _app_clipboard_read_cb(active_b, buf[:])
					if n > 0 {
						backend_paste(active_b, string(buf[:n]))
					}
				case .None, .Open_Link:
				}
				active_b.view.selection.active = active_b.interaction.selection_active
				active_b.view.selection.anchor = active_b.interaction.selection_anchor
				active_b.view.selection.focus = active_b.interaction.visual_cursor
				active_b.view.selection.block = (active_b.interaction.visual_kind == .Block)
				active_b.view.visual_mode = (active_b.interaction.mode == .Visual)
				active_b.view_generation += 1
				if backend_is_threaded(active_b) {
					active_b.front_view = active_b.view
					active_b.front_interaction = active_b.interaction
				}
				continue
			}

			if active_b.pty.state == .Exited {
				switch app_handle_exited_key(ev) {
				case .Relaunch:
					_ = app_relaunch(a)
				case .Quit:
					if len(a.session_mgr.tabs) > 0 {
						session_close_tab(&a.session_mgr, a.session_mgr.active_idx)
						if len(a.session_mgr.tabs) == 0 {
							a.should_quit = true
						}
						_app_resync_tab_modals(a)
					} else {
						a.should_quit = true
					}
					a.renderer.full_redraw_pending = true
					continue
				case .None:
				}
			} else {
				key_ev := [1]input.Input_Event{ev}
				kitty_flags := termgrid.terminal_kitty_active(&active_b.terminal).flags
				ok = input.input_pump_events(&active_b.pty, key_ev[:], kitty_flags, active_b.terminal.app_cursor_keys) && ok
			}
		case .Local:
			switch ev.action {
			case .Copy:
				if !_app_copy_selection(a) {
					ok = false
				}
			case .Paste:
				if a.tab_rename.active || a.search_bar.visible || a.tab_menu.visible || a.tab_overflow.visible do continue
				if !_app_paste_clipboard(a) {
					ok = false
				}
			case .Zoom_In:
				_ = _app_request_zoom(a, 1)
			case .Zoom_Out:
				_ = _app_request_zoom(a, -1)
			case .Reload_Config:
				_ = app_reload_config(a)
			case .None:
			}
		case .Drop:
			if ev.drop.kind == .File || ev.drop.kind == .Text {
				if len(ev.drop.text) > 0 && active_b.pty.state != .Exited {
					if ev.drop.kind == .File {
						// Shell-quote path: wrap in single quotes, escape embedded single quotes
						quoted := _app_shell_quote_path(ev.drop.text)
						_ = backend_paste(active_b, quoted)
						delete(quoted)
					} else {
						_ = backend_paste(active_b, ev.drop.text)
					}
					delete(ev.drop.text)
				} else if len(ev.drop.text) > 0 {
					delete(ev.drop.text)
				}
			}
		case .Pointer:
			// Refresh logical rectangles before hit testing, including resize events.
			_app_layout_ui(a)
			primary_click := ev.pointer.kind == .Button_Down && ev.pointer.button == sdl3.BUTTON_LEFT
			// Pointer Hit & Focus Gate
			px := ev.pointer.x
			py := ev.pointer.y

			// (0a) Modal tab chrome: context menu, inline rename, then drag. Each
			// branch consumes before terminal routing so nothing leaks to the PTY.
			modal_tab_count := len(a.session_mgr.tabs)
			modal_max_tabs := a.session_mgr.max_tabs
			if a.tab_menu.visible {
				consumed, m_action, item := platform_tabs.tab_menu_dispatch_pointer(&a.tab_menu, px, py, primary_click, modal_tab_count, modal_max_tabs)
				if consumed {
					switch m_action {
					case .Activated:
						_app_execute_tab_menu(a, item, a.tab_menu.target_idx)
						platform_tabs.tab_menu_close(&a.tab_menu)
					case .Dismissed:
						platform_tabs.tab_menu_close(&a.tab_menu)
					case .None:
					}
					a.renderer.full_redraw_pending = true
					continue
				}
			}
			if a.tab_rename.active {
				edit_idx := a.tab_rename.tab_idx
				title_rect := platform_tabs.Rect_f32{}
				if edit_idx >= 0 && edit_idx < modal_tab_count && edit_idx < len(a.tab_rects) {
					title_rect = a.tab_rects[edit_idx]
				}
				consumed, r_action := platform_tabs.tab_rename_dispatch_pointer(&a.tab_rename, px, py, primary_click, title_rect)
				if consumed {
					switch r_action {
					case .Commit:
						_app_commit_tab_rename(a)
					case .Cancel:
						_app_cancel_tab_rename(a)
					case .Changed, .None:
						a.renderer.full_redraw_pending = true
					}
					continue
				}
			}
			if a.tab_drag.phase != .Idle {
				from_idx := a.tab_drag.from_idx
				from_id := a.tab_drag.from_id
				consumed, d_action, drop_gap := platform_tabs.tab_drag_dispatch_pointer(
					&a.tab_drag,
					&a.tab_bar,
					modal_tab_count,
					a.tab_rects[:modal_tab_count],
					px,
					py,
					ev.pointer.kind,
					ev.pointer.button,
				)
				if consumed {
					switch d_action {
					case .Drop:
						resolved := _app_tab_index_by_id(a, from_id)
						if resolved < 0 do resolved = from_idx
						_app_commit_tab_drop(a, resolved, drop_gap)
					case .Cancel, .Move, .None:
						a.renderer.full_redraw_pending = true
					}
					continue
				}
			}

			if a.tab_overflow.visible {
				tabs_tmp: [MAX_TABS]platform_tabs.Tab_Info
				n := _app_build_ui_tabs(a, tabs_tmp[:])
				wheel := 0
				if ev.pointer.kind == .Wheel do wheel = _app_pointer_wheel_delta(ev.pointer)
				o_action := platform_tabs.tab_overflow_dispatch_pointer(&a.tab_overflow, tabs_tmp[:n], px, py, primary_click, wheel)
				switch o_action {
				case .Activate:
					_app_activate_overflow_selection(a)
				case .Dismiss:
					platform_tabs.tab_overflow_close(&a.tab_overflow)
					_app_set_drag_region(a)
				case .None:
				}
				a.renderer.full_redraw_pending = true
				continue
			}

			// (a) Search Bar Hit
			if a.search_bar.visible && platform_chrome.point_in_rect(px, py, a.search_bar.rect) {
				consumed, s_action := platform_chrome.search_bar_dispatch_pointer(&a.search_bar, px, py, primary_click)
				if consumed {
					switch s_action {
					case .Query_Changed:
						_ = platform_chrome.search_bar_execute_scan(&a.search_bar, &active_b.terminal, active_b.interaction.search_matches[:])
						copy(active_b.interaction.search_query[:], a.search_bar.query[:a.search_bar.query_len])
						active_b.interaction.search_len = a.search_bar.query_len
						active_b.interaction.search_match_count = a.search_bar.match_count
						active_b.interaction.search_match_idx = a.search_bar.match_idx
						active_b.interaction.search_active = true
						if a.search_bar.match_count > 0 {
							match_row := active_b.interaction.search_matches[active_b.interaction.search_match_idx].row
							sb_len := termgrid.scrollback_len(&active_b.terminal.scrollback)
							target_offset := clamp(sb_len - match_row, 0, termgrid.terminal_view_max_offset(&active_b.terminal))
							termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, target_offset)
							active_b.view_generation += 1
							if backend_is_threaded(active_b) {
								active_b.front_view = active_b.view
							}
						}
						if backend_is_threaded(active_b) {
							active_b.front_interaction = active_b.interaction
						}
						a.renderer.full_redraw_pending = true
					case .Next_Match, .Prev_Match:
						if a.search_bar.match_count > 0 {
							if s_action == .Next_Match {
								a.search_bar.match_idx = (a.search_bar.match_idx + 1) % a.search_bar.match_count
							} else {
								a.search_bar.match_idx = (a.search_bar.match_idx - 1 + a.search_bar.match_count) % a.search_bar.match_count
							}
							active_b.interaction.search_match_idx = a.search_bar.match_idx
							match_row := active_b.interaction.search_matches[active_b.interaction.search_match_idx].row
							sb_len := termgrid.scrollback_len(&active_b.terminal.scrollback)
							target_offset := clamp(sb_len - match_row, 0, termgrid.terminal_view_max_offset(&active_b.terminal))
							termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, target_offset)
							active_b.view_generation += 1
							if backend_is_threaded(active_b) {
								active_b.front_view = active_b.view
								active_b.front_interaction = active_b.interaction
							}
							a.renderer.full_redraw_pending = true
						}
					case .Close:
						a.search_bar.visible = false
						inter.interaction_exit_to_passthrough(&active_b.interaction)
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, 0)
						active_b.view_generation += 1
						if backend_is_threaded(active_b) {
							active_b.front_view = active_b.view
							active_b.front_interaction = active_b.interaction
						}
						a.renderer.full_redraw_pending = true
					case .None:
					}
					continue
				}
			}

			// (b) Tab Bar Hit (wheel over the bar scrolls tabs; never forwarded to the terminal)
			if py < platform_tabs.TAB_BAR_HEIGHT {
				if ev.pointer.kind == .Wheel {
					wheel_ticks := _app_pointer_wheel_delta(ev.pointer)
					_ = platform_tabs.tabs_scroll(&a.tab_bar, wheel_ticks)
					a.renderer.full_redraw_pending = true
					_app_layout_ui(a)
					continue
				}

				// Right-click over a tab opens the discovery menu before dispatch.
				if ev.pointer.kind == .Button_Down && ev.pointer.button == sdl3.BUTTON_RIGHT {
					rc_count := len(a.session_mgr.tabs)
					rc_target, rc_idx := platform_tabs.tab_bar_hit_test(&a.tab_bar, rc_count, a.tab_rects[:rc_count], px, py)
					if rc_target == .Tab_Item && rc_idx >= 0 && rc_idx < rc_count {
						win_w := f32(a.window.width) if a.window.width > 0 else f32(a.window.pixel_w)
						win_h := f32(a.window.height) if a.window.height > 0 else f32(a.window.pixel_h)
						platform_tabs.tab_menu_open(&a.tab_menu, rc_idx, a.session_mgr.tabs[rc_idx].id, rc_count, a.session_mgr.max_tabs, px, py, win_w, win_h)
						a.renderer.full_redraw_pending = true
						continue
					}
				}

				a.renderer.full_redraw_pending = true
				tab_count := len(a.session_mgr.tabs)
				is_down := ev.pointer.kind == .Button_Down
				consumed, t_action, target_idx := platform_tabs.tabs_dispatch_pointer(
					&a.tab_bar,
					tab_count,
					a.tab_rects[:tab_count],
					px,
					py,
					is_down,
					ev.pointer.button,
					ev.pointer.clicks,
				)
				if consumed {
					switch t_action {
					case .Switch_Tab:
						if is_down && ev.pointer.clicks == 2 {
							_app_begin_tab_rename(a, target_idx)
						} else {
							if session_switch_tab(&a.session_mgr, target_idx) {
								_ = platform_tabs.tab_bar_scroll_to_tab(&a.tab_bar, target_idx)
							}
							if is_down {
								_app_begin_tab_drag(a, target_idx, px, py)
							}
							_app_resync_tab_modals(a)
							platform_tabs.tab_bar_anim_activate(&a.tab_bar)
							a.renderer.full_redraw_pending = true
						}
					case .Close_Tab:
						_app_request_close_tab(a, target_idx)
						continue
					case .New_Tab:
						shell, _ := _resolve_shell()
						shell_argv := _resolve_shell_argv(shell)
						rows := a.renderer.rows > 0 ? int(a.renderer.rows) : APP_DEFAULT_ROWS
						cols := a.renderer.cols > 0 ? int(a.renderer.cols) : APP_DEFAULT_COLS
						new_idx, spawn_ok := session_spawn(&a.session_mgr, shell, shell_argv, rows, cols, &a.config, a.renderer.theme)
						if spawn_ok {
							new_b := &a.session_mgr.tabs[new_idx].backend
							backend_set_clipboard_callbacks(new_b, &a.frontend, _frontend_clipboard_write_cb, _frontend_clipboard_read_cb)
							session_switch_tab(&a.session_mgr, new_idx)
						}
						_app_resync_tab_modals(a)
						platform_tabs.tab_bar_anim_activate(&a.tab_bar)
						a.renderer.full_redraw_pending = true
					case .Context_Menu:
						// Handled by the right-click intercept above.
					case .Show_Overflow:
						_app_open_tab_overflow(a)
					case .Window_Zoom:
						_ = win.window_zoom(&a.window)
						win.window_update_pixel_size(&a.window)
					case .None:
					}
					continue
				}
			} else {
				if a.tab_bar.hover_tab_idx != -1 || a.tab_bar.hover_close_idx != -1 || a.tab_bar.hover_new_tab {
					a.tab_bar.hover_tab_idx = -1
					a.tab_bar.hover_close_idx = -1
					a.tab_bar.hover_new_tab = false
					a.tab_bar.hover_target = .None
					a.renderer.full_redraw_pending = true
				}
			}

			// (c) Terminal scrollbar hit/drag
			if active_b != nil && active_b.terminal.scrollbar.visible {
				sb := &active_b.terminal.scrollbar
				if sb.is_dragging {
					if ev.pointer.kind == .Motion {
						new_offset := termgrid.scrollbar_drag(sb, py)
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, new_offset)
						active_b.view_generation += 1
						a.renderer.full_redraw_pending = true
						continue
					} else if ev.pointer.kind == .Button_Up && ev.pointer.button == sdl3.BUTTON_LEFT {
						sb.is_dragging = false
						a.renderer.full_redraw_pending = true
						continue
					}
				} else if ev.pointer.kind == .Button_Down && ev.pointer.button == sdl3.BUTTON_LEFT {
					hit_thumb, hit_track := termgrid.scrollbar_hit_test(sb, px, py)
					if hit_thumb {
						sb.is_dragging = true
						sb.drag_start_y = py
						sb.drag_start_offset = sb.offset
						continue
					} else if hit_track {
						new_offset := termgrid.scrollbar_drag(sb, py)
						termgrid.terminal_view_set_offset(&active_b.view, &active_b.terminal, new_offset)
						active_b.view_generation += 1
						a.renderer.full_redraw_pending = true
						continue
					}
				}
			}

			// (d) Terminal mapping owns the logical-to-pixel and content offset conversion.
			if !_app_route_pointer(a, ev.pointer) {
				ok = false
			}
		}
	}
	quit = a.should_quit || !a.window.is_open
	return quit, ok
}

_app_apply_resize :: proc(a: ^App) {
	b := app_active_backend(a)
	if b == nil do return
	rows := b.terminal.grid.row_count
	cols := b.terminal.grid.col_count
	if rows > 0 && cols > 0 {
		render.renderer_resize_grid(&a.renderer, &b.terminal, i32(rows), i32(cols))
	}
	if a.window.pixel_w > 0 && a.window.pixel_h > 0 {
		render.renderer_resize(&a.renderer, u32(a.window.pixel_w), u32(a.window.pixel_h))
	}
	a.last_px_w = a.window.pixel_w
	a.last_px_h = a.window.pixel_h
}

_app_mark_cursor_dirty :: proc(a: ^App, row, col: int) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false
	return backend_mark_cursor_dirty(b, row, col)
}

app_show_banner :: proc(a: ^App) {
	if a != nil {
		b := app_active_backend(a)
		if b != nil {
			backend_show_banner(b)
		}
	}
}

app_relaunch :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false
	return backend_relaunch(b)
}

app_on_resize :: proc(a: ^App, pixel_w: i32, pixel_h: i32) -> (resized: bool) {
	threaded := false
	started_ns := profile_clock_ns()
	if a == nil || pixel_w <= 0 || pixel_h <= 0 {
		return false
	}
	b := app_active_backend(a)
	if b == nil do return false

	frontend_update_padding(&a.frontend)

	rows, cols := grid_dimensions_for_pixels(
		pixel_w,
		pixel_h,
		a.renderer.cell_width,
		a.renderer.cell_height,
		a.renderer.pad_x,
		a.renderer.pad_y,
	)

	threaded = backend_is_threaded(b)
	if threaded {
		backend_lock_render(b)
		defer backend_unlock_render(b)
		render.renderer_resize(&a.renderer, u32(pixel_w), u32(pixel_h))
		win.platform_setup_metal_layer(a.window.handle)
		a.frontend.last_px_w = pixel_w
		a.frontend.last_px_h = pixel_h
		a.last_px_w = pixel_w
		a.last_px_h = pixel_h
		profile_record(.Resize_Begin, _profile_scenario.phase, pixel_w, pixel_h, i32(rows), i32(cols), 0, true)
		backend_push_event(b, UI_Event{
			type = .Resize,
			pixel_w = pixel_w,
			pixel_h = pixel_h,
			rows = rows,
			cols = cols,
		})
		elapsed := profile_elapsed_ns(started_ns)
		profile_record(.Resize_End, _profile_scenario.phase, pixel_w, pixel_h, i32(rows), i32(cols), elapsed, true)
		return true
	}

	profile_record(.Resize_Begin, _profile_scenario.phase, pixel_w, pixel_h, i32(rows), i32(cols), 0, false)
	resized = frontend_on_resize(&a.frontend, &b.terminal, &b.pty, pixel_w, pixel_h)
	elapsed := profile_elapsed_ns(started_ns)
	profile_record(.Resize_End, _profile_scenario.phase, pixel_w, pixel_h, i32(rows), i32(cols), elapsed, false)
	a.last_px_w = pixel_w
	a.last_px_h = pixel_h
	return resized
}

_app_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	if event == nil || userdata == nil {
		return true
	}
	#partial switch event.type {
	case .WINDOW_LEAVE_FULLSCREEN, .WINDOW_RESTORED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		a := (^App)(userdata)
		if a.window.handle != nil && event.window.windowID == sdl3.GetWindowID(a.window.handle) {
			win.window_restore_unified_titlebar(&a.window)
			win.window_update_pixel_size(&a.window)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			a.renderer.full_redraw_pending = true
		}
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		a := (^App)(userdata)
		if a.window.handle != nil && event.window.windowID == sdl3.GetWindowID(a.window.handle) {
			// 1. Purge intermediate unrendered resize events from the SDL queue.
			// During VSync presentation wait, intermediate events accumulate in SDL.
			// Flushing them ensures we discard stale backlog and only render the latest state.
			sdl3.FlushEvents(sdl3.EventType.WINDOW_RESIZED, sdl3.EventType.WINDOW_PIXEL_SIZE_CHANGED)

			// 2. Fetch the latest live window pixel size directly from the OS
			win.window_update_pixel_size(&a.window)
			size_changed := a.window.pixel_w != a.last_px_w || a.window.pixel_h != a.last_px_h
			active_b := app_active_backend(a)

			if active_b != nil && active_b.pty.master >= 0 && !backend_is_threaded(active_b) {
				_ = backend_drain_pty(active_b)
			}

			is_exposed := event.type == .WINDOW_EXPOSED

			if size_changed || is_exposed {
				if size_changed {
					app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
				}
				if active_b != nil {
					threaded := backend_is_threaded(active_b)
					if threaded {
						backend_lock_render(active_b)
					}
					state := backend_get_render_state(active_b)
					state.debug_frames = a.debug_frames
					_app_stage_ui(a)
					_ = frontend_render(&a.frontend, &state)
					if threaded {
						backend_unlock_render(active_b)
					}
				}
			}
		}
	}
	return true
}

_app_compute_hud_title :: proc(s: ^inter.Interaction_State) -> string {
	if s == nil do return ""
	switch s.mode {
	case .Visual:
		kind_str := "CHAR"
		switch s.visual_kind {
		case .Char:  kind_str = "CHAR"
		case .Line:  kind_str = "LINE"
		case .Block: kind_str = "BLOCK"
		}
		if s.paused_lines_accumulated > 0 {
			return fmt.tprintf(APP_HUD_VISUAL_PAUSED_FMT, kind_str, s.paused_lines_accumulated)
		}
		return fmt.tprintf(APP_HUD_VISUAL_FMT, kind_str)

	case .Search:
		if s.search_len == 0 {
			return APP_HUD_FIND_PROMPT
		}
		q := string(s.search_query[:s.search_len])
		if s.search_match_count == 0 {
			return fmt.tprintf(APP_HUD_FIND_EMPTY_FMT, q)
		}
		idx := s.search_match_idx + 1
		return fmt.tprintf(APP_HUD_FIND_FMT, q, idx, s.search_match_count)

	case .Passthrough:
		if s.viewport_flow == .Paused {
			if s.paused_lines_accumulated > 0 {
				return fmt.tprintf(APP_HUD_PAUSED_ACC_FMT, s.paused_lines_accumulated)
			}
			return APP_HUD_PAUSED_FMT
		}
	}
	return ""
}

_app_sync_title :: proc(a: ^App) {
	if a == nil do return
	active_b := app_active_backend(a)
	if active_b == nil do return

	if osc_title := backend_take_title(active_b); len(osc_title) > 0 {
		a.base_title = osc_title
		if !a.hud_active {
			frontend_set_title(&a.frontend, osc_title)
		}
	}

	inter_ptr := &active_b.front_interaction if backend_is_threaded(active_b) else &active_b.interaction
	if inter_ptr.mode != .Passthrough || inter_ptr.viewport_flow == .Paused {
		hud_title := _app_compute_hud_title(inter_ptr)
		if len(hud_title) > 0 {
			frontend_set_title(&a.frontend, hud_title)
			a.hud_active = true
		}
	} else if a.hud_active {
		title := a.base_title
		if len(title) == 0 {
			title = a.config.title if len(a.config.title) > 0 else APP_TITLE
		}
		frontend_set_title(&a.frontend, title)
		a.hud_active = false
	}
}

app_compute_hud_title :: _app_compute_hud_title

_app_drain_terminal_events :: proc(a: ^App, term_ref: ^termgrid.Terminal) {
	if a == nil || term_ref == nil do return
	active_b := app_active_backend(a)
	if active_b == nil do return

	if clip_text, ok := backend_take_pending_clipboard(active_b); ok {
		win.window_set_clipboard_text(&a.window, clip_text)
	}

	if term_ref.bell_event {
		term_ref.bell_event = false
		when ODIN_OS == .Darwin {
			NSBeep()
		}
	}

	for term_ref.notification_count > 0 {
		notif, ok := termgrid.terminal_pop_notification(term_ref)
		if ok {
			title := string(notif.title[:notif.title_len])
			message := string(notif.message[:notif.message_len])
			_app_show_notification(title, message)
		}
	}
}

// app_frame executes one tick of the main loop.
_app_layout_ui :: proc(a: ^App) {
	if a == nil do return
	window_w := f32(a.window.width) if a.window.width > 0 else f32(a.window.pixel_w)
	window_h := f32(a.window.height) if a.window.height > 0 else f32(a.window.pixel_h)
	tab_count := len(a.session_mgr.tabs)
	a.tab_bar.max_title_len = a.config.tab_max_title_len if a.config.tab_max_title_len > 0 else 16
	titles: [MAX_TABS]string
	for i in 0 ..< tab_count {
		titles[i] = session_title_display(&a.session_mgr.tabs[i])
	}
	_ = platform_tabs.tabs_layout(&a.tab_bar, window_w, tab_count, a.tab_rects[:tab_count], a.session_mgr.active_idx, titles[:tab_count])
	if a.tab_overflow.visible {
		tabs_tmp: [MAX_TABS]platform_tabs.Tab_Info
		n := _app_build_ui_tabs(a, tabs_tmp[:])
		platform_tabs.tab_overflow_refresh(&a.tab_overflow, tabs_tmp[:n], &a.tab_bar, window_w, window_h)
	}
	if a.tab_menu.visible {
		platform_tabs.tab_menu_refresh(&a.tab_menu, tab_count, a.session_mgr.max_tabs)
		platform_tabs.tab_menu_layout(&a.tab_menu, window_w, window_h)
	}
	if a.search_bar.visible {
		platform_chrome.search_bar_layout(&a.search_bar, window_w)
	}
	if a.confirm_dialog.visible {
		platform_dialogs.confirm_dialog_layout(&a.confirm_dialog, window_w, window_h)
	}
	_app_set_drag_region(a)
}

_app_stage_ui :: proc(a: ^App) {
	if a == nil || a.window.handle == nil do return
	_app_layout_ui(a)
	ui_tabs: [MAX_TABS]platform_tabs.Tab_Info
	tab_count := _app_build_ui_tabs(a, ui_tabs[:])
	_ = ui.ui_render_stage(
		&a.renderer,
		&a.ui_theme,
		i18n.i18n_get(),
		&a.tab_bar,
		ui_tabs[:tab_count],
		a.tab_rects[:tab_count],
		&a.search_bar,
		f32(a.window.width) if a.window.width > 0 else f32(a.window.pixel_w),
		f32(a.window.height) if a.window.height > 0 else f32(a.window.pixel_h),
		frontend_content_scale(&a.frontend),
		a.base_title,
		&a.tab_drag,
		&a.tab_menu,
		&a.tab_rename,
		&a.confirm_dialog,
		&a.tab_overflow,
	)

	// One shared logical-space surface; the shader applies the Retina scale once.
	waves: [instance.WATER_MAX_WAVES]instance.Water_Wave
	count := 0
	for sp in a.drop_fx.splashes {
		if sp.active {
			waves[count] = instance.Water_Wave{
				origin_age_strength = {sp.x, sp.y, sp.time, sp.strength},
				lifetime_params = {sp.max_t, 0, 0, 0},
			}
			count += 1
		}
	}
	ui.ui_stage_water_surface(&a.renderer, a.renderer.screen_w, a.renderer.screen_h, frontend_content_scale(&a.frontend), waves[:count], ui.Color{0.53, 0.61, 0.65, 0.68})
}

_e2e_resize_frame: int = 0
_last_frame_ticks: i64 = 0
_has_last_frame_ticks: bool = false

// _app_frame_dt_ms returns the elapsed time since the previous frame in milliseconds,
// clamped to [0, TAB_BAR_ANIM_DT_MAX_MS] so stalls never produce oversized animation jumps.
_app_frame_dt_ms :: proc() -> f32 {
	now := platform.platform_now()
	if !_has_last_frame_ticks {
		_last_frame_ticks = now
		_has_last_frame_ticks = true
		return 0
	}
	dt_ns := platform.platform_ticks_to_ns(now - _last_frame_ticks)
	_last_frame_ticks = now
	dt_ms := f32(dt_ns) / 1_000_000.0
	return clamp(dt_ms, 0, platform_tabs.TAB_BAR_ANIM_DT_MAX_MS)
}

_app_render_unlock :: proc(data: rawptr) {
	b := (^Backend)(data)
	if b != nil {
		backend_unlock_render(b)
	}
}

app_frame :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	when ODIN_OS == .Darwin {
		pool := win.platform_autorelease_pool_push()
		defer win.platform_autorelease_pool_pop(pool)
	}
	defer free_all(context.temp_allocator)

	if ! _profile_scenario_step(a) { return false }

	if e2e_val, ok := os.lookup_env("TERM_E2E_RESIZE", context.temp_allocator); ok && e2e_val == "1" {
		time.sleep(16 * time.Millisecond)
		_e2e_resize_frame += 1
		if _e2e_resize_frame == 30 {
			_ = os.write_entire_file("/tmp/term_e2e_ready_phase1", transmute([]u8)string("1"))
			fmt.println("[E2E] Phase 1 ready (680x480, 80 cols)")
		} else if _e2e_resize_frame == 60 {
			win.window_set_size(&a.window, 600, 480)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			fmt.println("[E2E] Step 1: Resized window to 600x480 (70 cols)")
		} else if _e2e_resize_frame == 90 {
			win.window_set_size(&a.window, 520, 480)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			fmt.println("[E2E] Step 2: Resized window to 520x480 (60 cols)")
		} else if _e2e_resize_frame == 120 {
			win.window_set_size(&a.window, 440, 480)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			fmt.println("[E2E] Step 3: Resized window to 440x480 (50 cols)")
		} else if _e2e_resize_frame == 140 {
			_ = os.write_entire_file("/tmp/term_e2e_ready_phase2", transmute([]u8)string("1"))
			fmt.println("[E2E] Phase 2 ready (440x480, shrunk to 50 cols)")
		} else if _e2e_resize_frame == 170 {
			win.window_set_size(&a.window, 600, 480)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			fmt.println("[E2E] Step 4: Resized window to 600x480 (70 cols)")
		} else if _e2e_resize_frame == 200 {
			win.window_set_size(&a.window, 680, 480)
			app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			fmt.println("[E2E] Step 5: Resized window back to 680x480 (80 cols)")
		} else if _e2e_resize_frame == 230 {
			_ = os.write_entire_file("/tmp/term_e2e_ready_phase3", transmute([]u8)string("1"))
			fmt.println("[E2E] Phase 3 ready (680x480, restored to 80 cols)")
		}
	}

	// (1) Drain and poll all active sessions (fair scheduling 64KB/tick)
	any_damaged := false
	had_tabs := len(a.session_mgr.tabs) > 0
	if had_tabs {
		any_damaged = session_poll_all(&a.session_mgr, 65536)
		if len(a.session_mgr.tabs) == 0 {
			a.should_quit = true
			return false
		}
	}
	sync.atomic_store(&a.pty_event_pending, false)

	if a.should_quit {
		return false
	}

	active_b := app_active_backend(a)
	if active_b == nil {
		return false
	}

	// The main loop owns PTY parsing and terminal state for every tab.
	n_events := 0
	if a.window.handle != nil {
		evs: [input.INPUT_PUMP_MAX_EVENTS]input.Input_Event
		first_ev: ^sdl3.Event = nil
		if a.has_wake_event {
			first_ev = &a.pending_wake_event
			a.has_wake_event = false
		}
		n_events = input.window_poll_input(&a.window, evs[:], input.INPUT_PUMP_MAX_EVENTS, first_ev)
		quit, _ := app_dispatch_input_events(a, evs[:n_events])
		if quit {
			a.should_quit = true
			return false
		}
		if win.window_take_titlebar_double_click(&a.drag_region) {
			_ = win.window_zoom(&a.window)
			win.window_update_pixel_size(&a.window)
			a.renderer.full_redraw_pending = true
		}
		active_b = app_active_backend(a)
		if active_b == nil do return false
		_app_sync_focus(a)
		resized := app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
		_ = _app_apply_zoom(a)
		if resized && len(a.session_mgr.tabs) > 0 {
			if session_poll_all(&a.session_mgr, 65536) {
				any_damaged = true
			}
		}
	}

	// Legacy headless callers do not use the session manager.
	if len(a.session_mgr.tabs) == 0 {
		if backend_drain_pty(active_b) > 0 {
			any_damaged = true
		}
	}
	threaded := backend_is_threaded(active_b)
	active_term := &active_b.front_terminal if threaded else &active_b.terminal

	if _damage_cells(active_term) > 0 {
		any_damaged = true
	}
	if a.renderer.rows != i32(active_term.grid.row_count) || a.renderer.cols != i32(active_term.grid.col_count) {
		render.renderer_resize_grid(&a.renderer, active_term, i32(active_term.grid.row_count), i32(active_term.grid.col_count))
		any_damaged = true
	}
	_app_drain_terminal_events(a, active_term)

	// Window title sync from backend / interaction HUD
	_app_sync_title(a)

	cursor_changed, position_changed, style_changed, old_row, old_col := backend_sync_cursor(active_b)
	if cursor_changed || position_changed {
		_app_mark_cursor_dirty(a, old_row, old_col)
		cur := termgrid.terminal_get_cursor(active_term)
		_app_mark_cursor_dirty(a, cur.row, cur.col)
	} else if style_changed {
		cur := termgrid.terminal_get_cursor(active_term)
		_app_mark_cursor_dirty(a, cur.row, cur.col)
	}

	dt_ms := _app_frame_dt_ms()
	dt_sec := dt_ms / 1000.0

	drop_fx_anim_active, drop_fx_changed := drop_fx_tick(&a.drop_fx, dt_sec)
	if drop_fx_changed {
		a.renderer.full_redraw_pending = true
	}

	anim_active := a.tab_bar.anim.anim_active
	if platform_tabs.tabs_anim_update(&a.tab_bar, a.session_mgr.active_idx, dt_ms, a.ui_theme.motion.hover_ms, a.ui_theme.motion.active_ms) {
		a.renderer.full_redraw_pending = true
		anim_active = true
	}
	if drop_fx_anim_active {
		a.renderer.full_redraw_pending = true
		anim_active = true
	}

	is_dirty := any_damaged || n_events > 0 || a.renderer.full_redraw_pending || anim_active
	if is_dirty {
		if threaded {
			backend_lock_render(active_b)
			a.frontend.renderer.unlock_cb = _app_render_unlock
			a.frontend.renderer.unlock_data = rawptr(active_b)
		}
		state := backend_get_render_state(active_b)
		state.debug_frames = a.debug_frames
		_app_stage_ui(a)
		_ = frontend_render(&a.frontend, &state)
		if threaded {
			a.frontend.renderer.unlock_cb = nil
			a.frontend.renderer.unlock_data = nil
			backend_unlock_render(active_b)
		}
	}

	backend_poll_exit(active_b)

	return !a.should_quit
}

main :: proc() {
	shell, shell_allocated := _resolve_shell()
	defer if shell_allocated { delete(shell) }
	shell_argv := _resolve_shell_argv(shell)
	fmt.printf("Term: starting %s (%dx%d)\n", shell, APP_DEFAULT_COLS, APP_DEFAULT_ROWS)

	app := new(App, runtime.heap_allocator())
	if !app_init(app, APP_DEFAULT_ROWS, APP_DEFAULT_COLS, shell, shell_argv) {
		free(app, runtime.heap_allocator())
		fmt.println("ERROR: app_init failed")
		return
	}
	defer {
		app_destroy(app)
		free(app, runtime.heap_allocator())
	}

	for !app.should_quit {
		if !app_frame(app) {
			break
		}
		if app.should_quit {
			break
		}

		drop_fx_anim_active := drop_fx_active(&app.drop_fx)
		anim_active := app.tab_bar.anim.anim_active || drop_fx_anim_active
		ev: sdl3.Event
		has_ev := false
		if anim_active || profile_scenario_enabled() {
			if sdl3.WaitEventTimeout(&ev, 16) {
				has_ev = true
			}
		} else {
			if sdl3.WaitEvent(&ev) {
				has_ev = true
			}
		}

		if has_ev {
			app.pending_wake_event = ev
			app.has_wake_event = true
		}
	}
	fmt.println("Term: quit")
}

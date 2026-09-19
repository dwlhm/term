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
import "core:time"

import "vendor:sdl3"

when ODIN_OS == .Darwin {
	foreign import AppKit "system:AppKit.framework"
	@(default_calling_convention="c")
	foreign AppKit {
		NSBeep :: proc() ---
	}
}

_last_notif_time: time.Time

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
import config "../config"
import inter "../interaction"
import ui "../ui"

// App composes Multi-Session Manager, UI Chrome, and Frontend subsystems.
App :: struct {
	session_mgr:    Session_Manager,
	using backend:  Backend, // Active tab backend fallback for tests/headless
	using frontend: Frontend,
	tab_bar:        ui.Tab_Bar_State,
	tab_rects:      [MAX_TABS]ui.Rect_f32,
	search_bar:     ui.Search_Bar_State,
	ui_theme:       ui.UI_Theme,
	ui_style:       ui.UI_Style,
	base_title:     string,
	hud_active:     bool,
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
	ui.tab_bar_init(&a.tab_bar)
	ui.search_bar_init(&a.search_bar)
	a.ui_theme = ui.theme_catppuccin_mocha()
	a.ui_style = .Modern_Flat
	a.should_quit = false

	// (3) Spawn initial Tab Session
	spawn_idx, spawn_ok := session_spawn(&a.session_mgr, prog, argv, init_rows, init_cols, &a.config, app_theme)
	if !spawn_ok {
		session_manager_destroy(&a.session_mgr)
		frontend_destroy(&a.frontend)
		config.config_destroy(&a.config)
		return false
	}
	active_b := &a.session_mgr.tabs[spawn_idx].backend

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
	return true
}

// app_destroy tears down Session Manager and Frontend in order.
app_destroy :: proc(a: ^App) {
	if a == nil {
		return
	}
	sdl3.RemoveEventWatch(_app_event_watch, a)
	session_manager_destroy(&a.session_mgr)
	if a.backend.drain_buf != nil {
		backend_destroy(&a.backend)
	}
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
			delta := _app_pointer_wheel_delta(pointer)
			if delta == 0 {
				return true
			}
			steps := abs(delta) * APP_ALT_SCREEN_WHEEL_LINES
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
		delta := _app_pointer_wheel_delta(pointer)
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
						a.renderer.full_redraw_pending = true
						continue
					}
				}
			}

			if ev.gui {
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
					}
					a.renderer.full_redraw_pending = true
					continue
				} else if ev.rune == 'w' || ev.rune == 'W' {
					target_idx := a.session_mgr.active_idx
					if target_idx >= 0 && target_idx < len(a.session_mgr.tabs) {
						target_tab := &a.session_mgr.tabs[target_idx]
						confirmed := true
						if pty.pty_has_running_processes(&target_tab.backend.pty) {
							tab_title := string(target_tab.title_buf[:target_tab.title_len])
							confirmed = win.window_show_close_tab_alert(&a.window, tab_title)
						}
						if confirmed {
							session_close_tab(&a.session_mgr, target_idx)
							if len(a.session_mgr.tabs) == 0 {
								a.should_quit = true
							}
							a.renderer.full_redraw_pending = true
							continue
						}
					}
					continue
				} else if ev.shift && (ev.rune == '[' || ev.rune == '{') {
					if len(a.session_mgr.tabs) > 0 {
						prev_idx := (a.session_mgr.active_idx - 1 + len(a.session_mgr.tabs)) % len(a.session_mgr.tabs)
						session_switch_tab(&a.session_mgr, prev_idx)
						a.renderer.full_redraw_pending = true
					}
					continue
				} else if ev.shift && (ev.rune == ']' || ev.rune == '}') {
					if len(a.session_mgr.tabs) > 0 {
						next_idx := (a.session_mgr.active_idx + 1) % len(a.session_mgr.tabs)
						session_switch_tab(&a.session_mgr, next_idx)
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
						a.renderer.full_redraw_pending = true
						continue
					}
				} else if ev.rune >= '1' && ev.rune <= '8' {
					idx := int(ev.rune - '1')
					if idx < len(a.session_mgr.tabs) {
						session_switch_tab(&a.session_mgr, idx)
						a.renderer.full_redraw_pending = true
						continue
					}
				}
			}
		}

		// (2) Search Bar Key Dispatch
		if a.search_bar.visible && ev.event_type == .Key {
			consumed, s_action := ui.search_bar_dispatch_key(&a.search_bar, ev)
			if consumed {
				switch s_action {
				case .Query_Changed:
					_ = ui.search_bar_execute_scan(&a.search_bar, &active_b.terminal, active_b.interaction.search_matches[:])
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
		case .Pointer:
			// Refresh logical rectangles before hit testing, including resize events.
			_app_layout_ui(a)
			primary_click := ev.pointer.kind == .Button_Down && ev.pointer.button == sdl3.BUTTON_LEFT
			// Pointer Hit & Focus Gate
			px := ev.pointer.x
			py := ev.pointer.y

			// (a) Search Bar Hit
			if a.search_bar.visible && ui.point_in_rect(px, py, a.search_bar.rect) {
				consumed, s_action := ui.search_bar_dispatch_pointer(&a.search_bar, px, py, primary_click)
				if consumed {
					switch s_action {
					case .Query_Changed:
						_ = ui.search_bar_execute_scan(&a.search_bar, &active_b.terminal, active_b.interaction.search_matches[:])
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

			// (b) Tab Bar Hit
			if py < ui.TAB_BAR_HEIGHT && ev.pointer.kind != .Wheel {
				a.renderer.full_redraw_pending = true
				tab_count := len(a.session_mgr.tabs)
				consumed, t_action, target_idx := ui.tab_bar_dispatch_pointer(
					&a.tab_bar,
					tab_count,
					a.tab_rects[:tab_count],
					px,
					py,
					ev.pointer.kind == .Button_Down,
					ev.pointer.button,
					ev.pointer.clicks,
				)
				if consumed {
					switch t_action {
					case .Switch_Tab:
						session_switch_tab(&a.session_mgr, target_idx)
						a.renderer.full_redraw_pending = true
					case .Close_Tab:
						if target_idx >= 0 && target_idx < len(a.session_mgr.tabs) {
							target_tab := &a.session_mgr.tabs[target_idx]
							confirmed := true
							if pty.pty_has_running_processes(&target_tab.backend.pty) {
								tab_title := string(target_tab.title_buf[:target_tab.title_len])
								confirmed = win.window_show_close_tab_alert(&a.window, tab_title)
							}
							if confirmed {
								session_close_tab(&a.session_mgr, target_idx)
								if len(a.session_mgr.tabs) == 0 {
									a.should_quit = true
								}
								a.renderer.full_redraw_pending = true
								continue
							}
						}
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
						a.renderer.full_redraw_pending = true
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

			// (c) Terminal mapping owns the logical-to-pixel and content offset conversion.
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

_app_debug_dump_grid :: proc(a: ^App) {
	if a != nil {
		b := app_active_backend(a)
		if b != nil {
			_frontend_debug_dump_grid(&b.terminal)
		}
	}
}

_app_write_banner_text :: proc(a: ^App, s: string) {
	if a != nil {
		b := app_active_backend(a)
		if b != nil {
			_backend_write_banner_text(b, s)
		}
	}
}

app_show_banner :: proc(a: ^App) {
	if a != nil {
		b := app_active_backend(a)
		if b != nil {
			backend_show_banner(b)
		}
	}
}

app_show_banner_fail :: proc(a: ^App) {
	if a != nil {
		b := app_active_backend(a)
		if b != nil {
			backend_show_banner_fail(b)
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
	if a == nil {
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

	if backend_is_threaded(b) {
		backend_lock_render(b)
		defer backend_unlock_render(b)
		render.renderer_resize(&a.renderer, u32(pixel_w), u32(pixel_h))
		a.frontend.last_px_w = pixel_w
		a.frontend.last_px_h = pixel_h
		a.last_px_w = pixel_w
		a.last_px_h = pixel_h
		backend_push_event(b, UI_Event{
			type = .Resize,
			pixel_w = pixel_w,
			pixel_h = pixel_h,
			rows = rows,
			cols = cols,
		})
		for i in 0 ..< len(a.session_mgr.tabs) {
			tab := &a.session_mgr.tabs[i]
			if &tab.backend != b && (tab.backend.terminal.grid.row_count != rows || tab.backend.terminal.grid.col_count != cols) {
				termgrid.terminal_resize(&tab.backend.terminal, rows, cols)
				termgrid.damage_mark_all(&tab.backend.terminal.damage, nil)
				tab.backend.view_generation += 1
			}
		}
		return true
	}

	resized = frontend_on_resize(&a.frontend, &b.terminal, &b.pty, pixel_w, pixel_h)
	a.last_px_w = pixel_w
	a.last_px_h = pixel_h

	for i in 0 ..< len(a.session_mgr.tabs) {
		tab := &a.session_mgr.tabs[i]
		if &tab.backend != b && (tab.backend.terminal.grid.row_count != rows || tab.backend.terminal.grid.col_count != cols) {
			termgrid.terminal_resize(&tab.backend.terminal, rows, cols)
			pty.pty_set_winsize(&tab.backend.pty, rows, cols)
			termgrid.damage_mark_all(&tab.backend.terminal.damage, nil)
			tab.backend.view_generation += 1
		}
	}
	return resized
}

_app_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	if event == nil || userdata == nil {
		return true
	}
	#partial switch event.type {
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		a := (^App)(userdata)
		if a.window.handle != nil && event.window.windowID == sdl3.GetWindowID(a.window.handle) {
			win.window_update_pixel_size(&a.window)
			size_changed := a.window.pixel_w != a.last_px_w || a.window.pixel_h != a.last_px_h
			new_rows, new_cols := grid_dimensions_for_pixels(
				a.window.pixel_w,
				a.window.pixel_h,
				a.renderer.cell_width,
				a.renderer.cell_height,
				a.renderer.pad_x,
				a.renderer.pad_y,
			)
			active_b := app_active_backend(a)
			cur_rows := active_b.terminal.grid.row_count if active_b != nil else 0
			cur_cols := active_b.terminal.grid.col_count if active_b != nil else 0
			grid_changed := (new_rows != cur_rows || new_cols != cur_cols)
			if size_changed {
				app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
			}
			if grid_changed && active_b != nil && active_b.pty.master >= 0 && !backend_is_threaded(active_b) {
				if pty.pty_wait_readable(&active_b.pty, 4) {
					_ = backend_drain_pty(active_b)
				}
			} else if active_b != nil && active_b.pty.master >= 0 && !backend_is_threaded(active_b) {
				_ = backend_drain_pty(active_b)
			}
			if size_changed || event.type == .WINDOW_EXPOSED {
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
app_sync_title        :: _app_sync_title

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
	tab_count := len(a.session_mgr.tabs)
	_ = ui.tab_bar_layout(&a.tab_bar, window_w, tab_count, a.tab_rects[:tab_count])
	if a.search_bar.visible {
		ui.search_bar_layout(&a.search_bar, window_w)
	}
}

_app_stage_ui :: proc(a: ^App) {
	if a == nil || a.window.handle == nil do return
	_app_layout_ui(a)
	tab_count := len(a.session_mgr.tabs)
	ui_tabs: [MAX_TABS]ui.UI_Tab_Info
	for i in 0 ..< tab_count {
		t := &a.session_mgr.tabs[i]
		ui_tabs[i] = ui.UI_Tab_Info{
			title     = string(t.title_buf[:t.title_len]),
			is_active = (i == a.session_mgr.active_idx),
			is_exited = (t.status == .Exited),
			has_bell  = t.has_bell,
		}
	}
	_ = ui.ui_render_stage(
		&a.renderer,
		&a.ui_theme,
		a.ui_style,
		&a.tab_bar,
		ui_tabs[:tab_count],
		a.session_mgr.active_idx,
		a.tab_rects[:tab_count],
		&a.search_bar,
		f32(a.window.width) if a.window.width > 0 else f32(a.window.pixel_w),
		f32(a.window.height) if a.window.height > 0 else f32(a.window.pixel_h),
		frontend_content_scale(&a.frontend),
	)
}

_e2e_resize_frame: int = 0

app_frame :: proc(a: ^App) -> bool {
	if a == nil {
		return false
	}
	defer free_all(context.temp_allocator)

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
	had_tabs := len(a.session_mgr.tabs) > 0
	if had_tabs {
		_ = session_poll_all(&a.session_mgr, 65536)
		if len(a.session_mgr.tabs) == 0 {
			a.should_quit = true
			return false
		}
	}

	if a.should_quit {
		return false
	}

	active_b := app_active_backend(a)
	if active_b == nil {
		return false
	}

	// The main loop owns PTY parsing and terminal state for every tab.
	if a.window.handle != nil {
		evs: [input.INPUT_PUMP_MAX_EVENTS]input.Input_Event
		n := input.window_poll_input(&a.window, evs[:], input.INPUT_PUMP_MAX_EVENTS)
		quit, _ := app_dispatch_input_events(a, evs[:n])
		if quit {
			a.should_quit = true
			return false
		}
		active_b = app_active_backend(a)
		if active_b == nil do return false
		_app_sync_focus(a)
		resized := app_on_resize(a, a.window.pixel_w, a.window.pixel_h)
		_ = _app_apply_zoom(a)
		if resized && len(a.session_mgr.tabs) > 0 {
			_ = session_poll_all(&a.session_mgr, 65536)
		}
	}

	// Legacy headless callers do not use the session manager.
	if len(a.session_mgr.tabs) == 0 {
		backend_drain_pty(active_b)
	}
	if a.renderer.rows != i32(active_b.terminal.grid.row_count) || a.renderer.cols != i32(active_b.terminal.grid.col_count) {
		render.renderer_resize_grid(&a.renderer, &active_b.terminal, i32(active_b.terminal.grid.row_count), i32(active_b.terminal.grid.col_count))
	}
	_app_drain_terminal_events(a, &active_b.terminal)

	// Window title sync from backend / interaction HUD
	_app_sync_title(a)

	cursor_changed, position_changed, style_changed, old_row, old_col := backend_sync_cursor(active_b)
	if cursor_changed || position_changed {
		_app_mark_cursor_dirty(a, old_row, old_col)
		cur := termgrid.terminal_get_cursor(&active_b.terminal)
		_app_mark_cursor_dirty(a, cur.row, cur.col)
	} else if style_changed {
		cur := termgrid.terminal_get_cursor(&active_b.terminal)
		_app_mark_cursor_dirty(a, cur.row, cur.col)
	}

	state := backend_get_render_state(active_b)
	state.debug_frames = a.debug_frames
	_app_stage_ui(a)
	_ = frontend_render(&a.frontend, &state)

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

	for app_frame(app) {
	}
	fmt.println("Term: quit")
}

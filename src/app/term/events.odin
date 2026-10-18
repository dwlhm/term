package term

// Term Event Processing, Input Routing & Dispatch
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "vendor:sdl3"

import plat_win "../../platform/window"
import contract "../../core/render/contract"
import chrome_render "../../core/render/chrome"
import damage "../../core/terminal/damage"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

// FRAME_TICK_MS is the WaitEventTimeout wake interval: it paces cursor blink and
// tab-bar animation, and bounds PTY output latency when no SDL event arrives.
FRAME_TICK_MS :: 8

app_handle_window_resize :: proc(app: ^Term_App) {
	plat_win.window_update_pixel_size(&app.window)
	if app.window.pixel_w <= 0 || app.window.pixel_h <= 0 do return

	scale := app.window.pixel_ratio
	layout_set_scale(&app.layout, scale)

	if app.text_atlas.cell_w > 0 {
		app.layout.metrics.cell_w = app.text_atlas.cell_w
		app.layout.metrics.cell_h = app.text_atlas.cell_h
	}

	size_changed := app.layout.screen_w != f32(app.window.pixel_w) || app.layout.screen_h != f32(app.window.pixel_h)

	// Rendering pipeline is fully in pixel space.
	app.layout.screen_w = f32(app.window.pixel_w)
	app.layout.screen_h = f32(app.window.pixel_h)

	if size_changed {
		contract.configure_surface(app.surface, app.device, app.format, u32(app.window.pixel_w), u32(app.window.pixel_h))
		composer_view_resize(&app.composer, app.layout.screen_w, app.layout.screen_h)
		chrome_view_resize(&app.chrome_view, u32(app.layout.screen_w), u32(app.layout.screen_h))
	}

	app.mouse.cell_w = app.layout.metrics.cell_w
	app.mouse.cell_h = app.layout.metrics.cell_h
	app.mouse.pad_x = app.layout.metrics.pane_pad_x
	app.mouse.pad_y = app.layout.metrics.pane_pad_y

	when ODIN_OS == .Darwin {
		plat_win.platform_setup_metal_layer(app.window.handle)
	}

	app_sync_layout_and_winsize(app)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
}

app_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	if event == nil || userdata == nil do return true
	#partial switch event.type {
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED:
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		app := (^Term_App)(userdata)
		if app != nil && app.running && app.window.handle != nil && event.window.windowID == sdl3.GetWindowID(app.window.handle) {
			sdl3.FlushEvents(sdl3.EventType.WINDOW_RESIZED, sdl3.EventType.WINDOW_PIXEL_SIZE_CHANGED)
			app_handle_window_resize(app)
			_ = mux_feat.multiplexer_drain_all(&app.mux)
			app_render_frame(app, true)
		}
	}
	return true
}

app_handle_mouse_button_down :: proc(app: ^Term_App, ev: sdl3.MouseButtonEvent) {
	// Scale SDL3 logical coords to pixel space on Retina displays.
	ratio := app.window.pixel_ratio
	mx := f32(ev.x) * ratio
	my := f32(ev.y) * ratio

	if app.tab_switcher.visible {
		target_tab, handled := tab_switcher_handle_click(&app.tab_switcher, mx, my)
		if target_tab >= 0 do app_select_tab(app, target_tab)
		if handled do return
	}

	// Click on tab pills, buttons, or free space in tab bar
	scale := app.layout.metrics.scale
	bar_h := app.layout.metrics.tab_bar_height
	tab_h: f32 = 22.0 * scale
	tab_y := (bar_h - tab_h) * 0.5
	tab_w: f32 = 140.0 * scale
	tab_gap: f32 = 6.0 * scale
	tabs_x := app.layout.metrics.traffic_clearance + 6.0 * scale

	// Fixed right-side buttons: [⊞] Overview and [+] New Tab
	btn_w: f32 = tab_h
	btn_gap: f32 = 4.0 * scale
	right_margin: f32 = 12.0 * scale
	btn_ov_x := app.layout.screen_w - right_margin - btn_w
	btn_plus_x := btn_ov_x - btn_gap - btn_w
	tabs_end_x := btn_plus_x - 8.0 * scale

	if my >= 0 && my <= bar_h {
		// 1. Click on [⊞] Show All Tabs button
		if mx >= btn_ov_x && mx <= btn_ov_x + btn_w && my >= tab_y && my <= tab_y + tab_h {
			app_execute_action(app, .Tab_Overview_Toggle)
			return
		}

		// 2. Click on [+] new tab button
		if mx >= btn_plus_x && mx <= btn_plus_x + btn_w && my >= tab_y && my <= tab_y + tab_h {
			app_execute_action(app, .Tab_New)
			return
		}

		// 3. Click on tab pills & close buttons within visible bounds
		for i in 0..<len(app.tabs_mgr.entries) {
			tab_item_x := tabs_x + f32(i) * (tab_w + tab_gap) - app.layout.tab_scroll_offset
			draw_x := max(tabs_x, tab_item_x)
			draw_r := min(tabs_end_x, tab_item_x + tab_w)
			if draw_x >= draw_r do continue

			if mx >= draw_x && mx <= draw_r && my >= tab_y && my <= tab_y + tab_h {
				if mx >= tab_item_x + tab_w - 24.0 * scale {
					app_close_tab(app, i)
				} else {
					app_select_tab(app, i)
				}
				return
			}
		}

		// 4. Double click on free space in title bar -> Toggle Maximize / Zoom
		if ev.clicks == 2 {
			plat_win.platform_toggle_maximize(app.window.handle)
			return
		}

		// Tab bar click absorbed, prevent fallthrough into panes
		return
	}

	// Focus clicked pane & initiate selection
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			mux_feat.multiplexer_focus_pane(&app.mux, p.id)
			_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
			if active_tab != nil {
				active_tab.active_pane_id = p.id
			}
			scroll_off := p.session.scroll_offset if p.session != nil else 0
			mods := sdl3.GetModState()
			is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
			is_alt   := (mods & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
			mouse_on_button_down(&app.mouse, {mx, my}, u8(ev.button), p.id, p.rect, p.session, scroll_off, int(ev.clicks), is_shift, is_alt)
			break
		}
	}
}

app_handle_mouse_wheel :: proc(app: ^Term_App, ev: sdl3.MouseWheelEvent) {
	ratio := app.window.pixel_ratio
	mx := ev.mouse_x * ratio
	my := ev.mouse_y * ratio

	// If Tab Switcher modal is visible, route wheel scrolling to it
	if app.tab_switcher.visible {
		tab_switcher_handle_wheel(&app.tab_switcher, ev.y)
		app.layout.tab_bar_force = true
		return
	}

	// If scrolling over tab bar, scroll tabs horizontally smoothly
	if my <= app.layout.metrics.tab_bar_height {
		scale := app.layout.metrics.scale
		wheel_delta := (ev.x != 0.0 ? ev.x : -ev.y) * 16.0 * scale
		app.layout.tab_scroll_offset += wheel_delta
		layout_tab_bar_clamp_scroll(&app.layout, len(app.tabs_mgr.entries), 80.0 * scale)
		app.layout.tab_bar_force = true
		return
	}

	target_pane: ^mux_feat.Pane_Entry = nil
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			target_pane = &p
			break
		}
	}
	if target_pane == nil {
		target_pane = mux_feat.multiplexer_get_focused_pane(&app.mux)
	}

	if target_pane != nil && target_pane.session != nil {
		sess := target_pane.session
		lines := int(ev.y * 3.0)
		if lines == 0 {
			if ev.y > 0 do lines = 1
			else if ev.y < 0 do lines = -1
		}

		if sess.term.parser.in_alt_screen {
			// In alternate screen (less, vim, man, nano), stream cursor keys to PTY
			up_key := "\x1bOA" if sess.term.parser.cursor_key_mode else "\x1b[A"
			down_key := "\x1bOB" if sess.term.parser.cursor_key_mode else "\x1b[B"
			if lines > 0 {
				for _ in 0..<lines {
					sess_feat.session_write_string(sess, up_key)
				}
			} else if lines < 0 {
				for _ in 0..<(-lines) {
					sess_feat.session_write_string(sess, down_key)
				}
			}
		} else {
			// In normal screen (shell CLI output), scroll viewport into scrollback history
			max_history := sess.term.grid.history_count
			sess.scroll_offset = clamp(sess.scroll_offset + lines, 0, max_history)
			if app.mouse.is_down && app.mouse.button == sdl3.BUTTON_LEFT {
				mouse_on_motion(&app.mouse, app.mouse.pos, target_pane.rect, sess, sess.scroll_offset)
			}
		}
	}
}

app_handle_text_input :: proc(app: ^Term_App, text: string) {
	if app.cmd_center.visible {
		command_center_handle_text(&app.cmd_center, text)
	} else if app.tab_switcher.visible {
		tab_switcher_handle_text(&app.tab_switcher, &app.tabs_mgr, text)
	} else {
		p := mux_feat.multiplexer_get_focused_pane(&app.mux)
		if p != nil && p.session != nil {
			if app.mouse.selection.active {
				mouse_clear_selection(&app.mouse)
			}
			p.session.scroll_offset = 0 // Auto-scroll to bottom on input
			sess_feat.session_write_string(p.session, text)
		}
	}
}

app_handle_key_down :: proc(app: ^Term_App, ev: sdl3.KeyboardEvent) {
	if app.cmd_center.visible {
		act, handled := command_center_handle_key(&app.cmd_center, ev.key)
		if act != .None do app_execute_action(app, act)
		if handled do return
	} else if app.tab_switcher.visible {
		target_tab, handled := tab_switcher_handle_key(&app.tab_switcher, &app.tabs_mgr, ev.key)
		if target_tab >= 0 do app_select_tab(app, target_tab)
		if handled do return
	}

	// Escape clears text selection if active
	if ev.key == sdl3.K_ESCAPE && app.mouse.selection.active {
		mouse_clear_selection(&app.mouse)
		return
	}

	is_shift := (ev.mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE

	// If text selection is active, pressing an unshifted arrow key deselects
	if app.mouse.selection.active && !is_shift {
		switch ev.key {
		case sdl3.K_LEFT, sdl3.K_RIGHT, sdl3.K_UP, sdl3.K_DOWN:
			mouse_clear_selection(&app.mouse)
		}
	}

	act, ok := keymap_evaluate(ev.key, ev.mod)
	p := mux_feat.multiplexer_get_focused_pane(&app.mux)

	// In alternate screen (e.g. vim), allow Shift+Arrow to stream to application instead of GUI selection
	if ok && p != nil && p.session != nil && p.session.term.parser.in_alt_screen && is_selection_action(act) {
		ok = false
	}

	if ok {
		app_execute_action(app, act)
	} else {
		res, encoded := input_encode_key(ev.key, ev.mod)
		if encoded {
			if p != nil && p.session != nil {
				if app.mouse.selection.active {
					mouse_clear_selection(&app.mouse)
				}
				p.session.scroll_offset = 0 // Auto-scroll to bottom on input
				_, _ = sess_feat.session_write(p.session, res.bytes[:res.len])
			}
		}
	}
}

app_process_events :: proc(app: ^Term_App, non_blocking: bool = false) -> (dirty: bool) {
	ev: sdl3.Event
	if non_blocking {
		if !sdl3.PollEvent(&ev) do return false
	} else {
		// Block until an event arrives or the animation tick elapses, then drain
		// any events queued behind it.
		if !sdl3.WaitEventTimeout(&ev, FRAME_TICK_MS) do return false
	}

	for {
		#partial switch ev.type {
		case .QUIT:
			app.running = false
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_EXPOSED:
			sdl3.FlushEvents(sdl3.EventType.WINDOW_RESIZED, sdl3.EventType.WINDOW_PIXEL_SIZE_CHANGED)
			app_handle_window_resize(app)
		case .MOUSE_MOTION:
			ratio := app.window.pixel_ratio
			app.layout.mouse_y = f32(ev.motion.y) * ratio
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			pane_rect := pane.rect if pane != nil else [4]f32{0, 0, 0, 0}
			sess := pane.session if pane != nil else nil
			scroll_off := sess.scroll_offset if sess != nil else 0
			mouse_on_motion(&app.mouse, {f32(ev.motion.x) * ratio, f32(ev.motion.y) * ratio}, pane_rect, sess, scroll_off)
		case .MOUSE_BUTTON_DOWN:
			app_handle_mouse_button_down(app, ev.button)
		case .MOUSE_BUTTON_UP:
			mouse_on_button_up(&app.mouse, u8(ev.button.button))
		case .MOUSE_WHEEL:
			app_handle_mouse_wheel(app, ev.wheel)
		case .TEXT_INPUT:
			app_handle_text_input(app, string(ev.text.text))
		case .KEY_DOWN:
			app_handle_key_down(app, ev.key)
		}

		if !sdl3.PollEvent(&ev) do break
	}
	return true
}

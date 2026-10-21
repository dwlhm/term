package term

// Term Event Processing, Input Routing & Dispatch
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:runtime"
import "vendor:sdl3"

import cursor "../../core/cursor"
import plat_win "../../platform/window"
import contract "../../core/render/contract"
import chrome_render "../../core/render/chrome"
import chrome_hit "../../core/chrome/hit_test"
import chrome_splits "../../core/chrome/splits"
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

	curr_fs := plat_win.platform_is_fullscreen(app.window.handle)
	fs_changed := app.layout.is_fullscreen != curr_fs
	app.layout.is_fullscreen = curr_fs

	size_changed := app.layout.screen_w != f32(app.window.pixel_w) || app.layout.screen_h != f32(app.window.pixel_h)

	if !size_changed && !fs_changed do return

	if fs_changed && !app.layout.is_fullscreen {
		plat_win.platform_setup_unified_titlebar(app.window.handle)
		plat_win.window_update_pixel_size(&app.window)
	}

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
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED, .WINDOW_LEAVE_FULLSCREEN, .WINDOW_ENTER_FULLSCREEN, .WINDOW_RESTORED:
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

	if app.cmd_center.visible {
		res := command_center_handle_click(&app.cmd_center, mx, my)
		if res.handled {
			if res.action != .None do app_execute_action(app, res.action)
			if res.target_tab >= 0 do app_select_tab(app, res.target_tab)
			return
		}
	}

	// Click on tab pills, buttons, or free space in tab bar
	scale := app.layout.metrics.scale
	bar_h := app.layout.metrics.tab_bar_height
	anim_offset_y: f32 = -(1.0 - app.layout.tab_bar_anim_t) * (bar_h + 6.0 * scale) if app.layout.is_fullscreen else 0.0
	tab_h: f32 = 22.0 * scale
	tab_y := (bar_h - tab_h) * 0.5 + anim_offset_y
	tab_w: f32 = 140.0 * scale
	tab_gap: f32 = 6.0 * scale
	tabs_x := (12.0 * scale) if app.layout.is_fullscreen else (app.layout.metrics.traffic_clearance + 6.0 * scale)

	// Fixed right-side buttons: [⊞] Overview and [+] New Tab
	btn_w: f32 = tab_h
	btn_gap: f32 = 4.0 * scale
	right_margin: f32 = 12.0 * scale
	btn_ov_x := app.layout.screen_w - right_margin - btn_w
	btn_plus_x := btn_ov_x - btn_gap - btn_w
	tabs_end_x := btn_plus_x - 8.0 * scale

	tab_bar_interactive := !app.layout.is_fullscreen || app.layout.tab_bar_anim_t > 0.5
	if tab_bar_interactive && my >= 0 && my <= (bar_h + anim_offset_y) {
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

	// 1. Right-click on pane opens native macOS NSMenu
	if ev.button == sdl3.BUTTON_RIGHT {
		for &p in app.mux.panes {
			if mouse_is_in_rect({mx, my}, p.rect) {
				old_focus := app.mux.focused_pane_id
				if old_focus != p.id {
					if old_p := mux_feat.multiplexer_get_pane(&app.mux, old_focus); old_p != nil && old_p.session != nil {
						mouse_protocol_report_focus(old_p.session, false)
					}
					mux_feat.multiplexer_focus_pane(&app.mux, p.id)
					if p.session != nil {
						mouse_protocol_report_focus(p.session, true)
					}
				}
				_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
				if active_tab != nil do active_tab.active_pane_id = p.id
				break
			}
		}
		app_show_pane_context_menu(app, mx, my)
		return
	}

	// 2. Left-click on split divider or drag handle button
	if ev.button == sdl3.BUTTON_LEFT {
		_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
		if active_tab != nil && active_tab.split_tree != nil {
			hit := chrome_hit.chrome_hit_test(nil, active_tab.split_tree, {mx, my})
			if hit.kind == .Split_Divider && hit.split_node != nil {
				app.mouse.is_dragging_divider = true
				app.mouse.drag_split_node = hit.split_node
				app.mouse.is_down = true
				app.mouse.button = u8(ev.button)
				shape := cursor.Mouse_Cursor.Col_Resize if (hit.split_node.kind == .Horizontal) else cursor.Mouse_Cursor.Row_Resize
				app_set_mouse_cursor(shape)
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				return
			}
		}
	}

	// Focus clicked pane & initiate selection or mouse reporting
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			old_focus_id := app.mux.focused_pane_id
			if old_focus_id != p.id {
				if old_p := mux_feat.multiplexer_get_pane(&app.mux, old_focus_id); old_p != nil && old_p.session != nil {
					mouse_protocol_report_focus(old_p.session, false)
				}
				mux_feat.multiplexer_focus_pane(&app.mux, p.id)
				if p.session != nil {
					mouse_protocol_report_focus(p.session, true)
				}
			}
			_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
			if active_tab != nil {
				active_tab.active_pane_id = p.id
			}
			scroll_off := p.session.scroll_offset if p.session != nil else 0
			mods := sdl3.GetModState()
			is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
			is_alt   := (mods & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
			is_ctrl  := (mods & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE

			if mouse_protocol_should_handle(p.session, is_shift) {
				if seq, ok := mouse_protocol_encode(p.session, .Press, u8(ev.button), mx, my, p.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y, 0.0, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write_string(p.session, seq)
				}
				app.mouse.pos = {mx, my}
				app.mouse.is_down = true
				app.mouse.button = u8(ev.button)
			} else {
				mouse_on_button_down(&app.mouse, {mx, my}, u8(ev.button), p.id, p.rect, p.session, scroll_off, int(ev.clicks), is_shift, is_alt)
			}
			break
		}
	}
}

app_handle_mouse_wheel :: proc(app: ^Term_App, ev: sdl3.MouseWheelEvent) {
	ratio := app.window.pixel_ratio
	mx := ev.mouse_x * ratio
	my := ev.mouse_y * ratio

	// If Command Center / Tab Switcher modal is visible, route wheel scrolling to it
	if app.cmd_center.visible {
		command_center_handle_wheel(&app.cmd_center, ev.y)
		app.layout.tab_bar_force = true
		return
	}

	// If scrolling over tab bar, scroll tabs horizontally smoothly
	if (!app.layout.is_fullscreen || app.layout.tab_bar_anim_t > 0.5) && my <= app.layout.metrics.tab_bar_height {
		scale := app.layout.metrics.scale
		wheel_delta := (ev.x != 0.0 ? ev.x : -ev.y) * 16.0 * scale
		app.layout.tab_scroll_offset += wheel_delta
		layout_tab_bar_clamp_scroll(&app.layout, len(app.tabs_mgr.entries), 80.0 * scale)
		app.layout.tab_bar_reveal_timer = 2.0
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
		mods := sdl3.GetModState()
		is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
		is_alt   := (mods & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
		is_ctrl  := (mods & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE

		eff_speed := sess.custom_scroll_speed if sess.custom_scroll_speed > 0.0 else (app.scroll_speed if app.scroll_speed > 0.0 else 1.0)
		sess.scroll_accum += ev.y * eff_speed
		if abs(sess.scroll_accum) < 1.0 do return

		ticks := int(sess.scroll_accum)
		sess.scroll_accum -= f32(ticks)

		if mouse_protocol_should_handle(sess, is_shift) {
			wheel_dir: f32 = 1.0 if ticks > 0 else -1.0
			count := abs(ticks)
			for _ in 0..<count {
				if seq, ok := mouse_protocol_encode(sess, .Wheel, 0, mx, my, target_pane.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y, wheel_dir, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write_string(sess, seq)
				}
			}
			return
		}

		if sess.term.parser.in_alt_screen {
			// In alternate screen (less, vim, man, nano), stream cursor keys to PTY
			up_key := "\x1bOA" if sess.term.parser.cursor_key_mode else "\x1b[A"
			down_key := "\x1bOB" if sess.term.parser.cursor_key_mode else "\x1b[B"
			if ticks > 0 {
				for _ in 0..<ticks {
					sess_feat.session_write_string(sess, up_key)
				}
			} else if ticks < 0 {
				for _ in 0..<(-ticks) {
					sess_feat.session_write_string(sess, down_key)
				}
			}
		} else {
			// In normal screen (shell CLI output), scroll viewport into scrollback history
			max_history := sess.term.grid.history_count
			sess.scroll_offset = clamp(sess.scroll_offset + ticks, 0, max_history)
			if app.mouse.is_down && app.mouse.button == sdl3.BUTTON_LEFT {
				mouse_on_motion(&app.mouse, app.mouse.pos, target_pane.rect, sess, sess.scroll_offset)
			}
		}
	}
}

app_handle_text_input :: proc(app: ^Term_App, text: string) {
	if app.cmd_center.visible {
		command_center_handle_text(&app.cmd_center, text, &app.tabs_mgr)
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
		res := command_center_handle_key(&app.cmd_center, ev.key, &app.tabs_mgr)
		if res.handled {
			if res.action != .None do app_execute_action(app, res.action)
			if res.target_tab >= 0 do app_select_tab(app, res.target_tab)
			return
		}
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
		app_cursor := p != nil && p.session != nil && p.session.term.parser.cursor_key_mode
		res, encoded := input_encode_key(ev.key, ev.mod, app_cursor)
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
		case .WINDOW_FOCUS_GAINED:
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if pane != nil && pane.session != nil {
				mouse_protocol_report_focus(pane.session, true)
			}
		case .WINDOW_FOCUS_LOST:
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if pane != nil && pane.session != nil {
				mouse_protocol_report_focus(pane.session, false)
			}
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_EXPOSED, .WINDOW_LEAVE_FULLSCREEN, .WINDOW_ENTER_FULLSCREEN, .WINDOW_RESTORED:
			sdl3.FlushEvents(sdl3.EventType.WINDOW_RESIZED, sdl3.EventType.WINDOW_PIXEL_SIZE_CHANGED)
			app_handle_window_resize(app)
		case .MOUSE_MOTION:
			ratio := app.window.pixel_ratio
			mx := f32(ev.motion.x) * ratio
			my := f32(ev.motion.y) * ratio
			app.layout.mouse_y = my

			// A. If dragging split divider, dynamically update partition ratio
			if app.mouse.is_dragging_divider && app.mouse.drag_split_node != nil {
				node := app.mouse.drag_split_node
				scale := app.layout.metrics.scale
				gap := app.layout.metrics.pane_gap

				if node.kind == .Horizontal {
					app_set_mouse_cursor(.Col_Resize)
					avail_w := max(1.0, node.rect[2] - gap)
					new_left_w := mx - node.rect[0] - gap * 0.5
					new_ratio := new_left_w / avail_w
					min_ratio := clamp((60.0 * scale) / avail_w, 0.05, 0.45)
					max_ratio := 1.0 - min_ratio
					node.ratio = clamp(new_ratio, min_ratio, max_ratio)
				} else if node.kind == .Vertical {
					app_set_mouse_cursor(.Row_Resize)
					avail_h := max(1.0, node.rect[3] - gap)
					new_top_h := my - node.rect[1] - gap * 0.5
					new_ratio := new_top_h / avail_h
					min_ratio := clamp((40.0 * scale) / avail_h, 0.05, 0.45)
					max_ratio := 1.0 - min_ratio
					node.ratio = clamp(new_ratio, min_ratio, max_ratio)
				}

				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				if !sdl3.PollEvent(&ev) do break
				continue
			}

			// B. If not dragging, perform hover test on split dividers for cursor & grip highlight
			prev_hovered := app.mouse.hovered_split_node
			app.mouse.hovered_split_node = nil
			divider_cursor_handled := false
			_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
			if active_tab != nil && active_tab.split_tree != nil {
				hit := chrome_hit.chrome_hit_test(nil, active_tab.split_tree, {mx, my})
				if hit.kind == .Split_Divider && hit.split_node != nil {
					app.mouse.hovered_split_node = hit.split_node
					app.mouse.hovered_is_horiz = (hit.split_node.kind == .Horizontal)
					if cur, handled := chrome_hit.chrome_hit_cursor(hit); handled {
						app_set_mouse_cursor(cur)
						divider_cursor_handled = true
					}
					if prev_hovered != hit.split_node {
						chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					}
				}
			}
			if prev_hovered != nil && app.mouse.hovered_split_node == nil {
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
			}

			if app.mouse.hovered_split_node != nil {
				if !sdl3.PollEvent(&ev) do break
				continue
			}

			mods := sdl3.GetModState()
			is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
			is_alt   := (mods & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
			is_ctrl  := (mods & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE

			hovered_pane: ^mux_feat.Pane_Entry = nil
			for &p in app.mux.panes {
				if mouse_is_in_rect({mx, my}, p.rect) {
					hovered_pane = &p
					break
				}
			}

			// C. Autonomous Cursor Determination: Chrome View -> Terminal/Session -> Window Default
			if !divider_cursor_handled {
				if cur, handled := chrome_view_cursor(&app.chrome_view, &app.layout, &app.tabs_mgr, &app.cmd_center, {mx, my}); handled {
					app_set_mouse_cursor(cur)
				} else if hovered_pane != nil {
					if hovered_pane.kind == .Terminal && hovered_pane.session != nil {
						app_set_mouse_cursor(sess_feat.session_get_mouse_cursor(hovered_pane.session, is_shift))
					} else {
						app_set_mouse_cursor(.Default)
					}
				} else {
					app_set_mouse_cursor(.Default)
				}
			}

			pane := hovered_pane if hovered_pane != nil else mux_feat.multiplexer_get_focused_pane(&app.mux)
			pane_rect := pane.rect if pane != nil else [4]f32{0, 0, 0, 0}
			sess := pane.session if pane != nil else nil
			scroll_off := sess.scroll_offset if sess != nil else 0

			// Report mouse motion only to the focused pane when hovered or when dragging within it
			if pane != nil && pane.is_focused && mouse_protocol_should_handle(sess, is_shift) {
				btn := app.mouse.button if app.mouse.is_down else u8(0)
				is_btn_down := app.mouse.is_down
				if sess.term.parser.mouse_mode == .Any_Event || (sess.term.parser.mouse_mode == .Button_Event && is_btn_down) {
					if seq, ok := mouse_protocol_encode(sess, .Motion, btn, mx, my, pane_rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y, 0.0, is_shift, is_alt, is_ctrl); ok {
						sess_feat.session_write_string(sess, seq)
					}
				}
			} else {
				mouse_on_motion(&app.mouse, {mx, my}, pane_rect, sess, scroll_off)
			}
		case .MOUSE_BUTTON_DOWN:
			app_handle_mouse_button_down(app, ev.button)
		case .MOUSE_BUTTON_UP:
			if app.mouse.is_dragging_divider {
				app.mouse.is_dragging_divider = false
				app.mouse.drag_split_node = nil
				mouse_on_button_up(&app.mouse, u8(ev.button.button))
				if app.mouse.hovered_split_node != nil {
					shape := cursor.Mouse_Cursor.Col_Resize if app.mouse.hovered_is_horiz else cursor.Mouse_Cursor.Row_Resize
					app_set_mouse_cursor(shape)
				} else {
					app_set_mouse_cursor(.Default)
				}
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				if !sdl3.PollEvent(&ev) do break
				continue
			}

			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			ratio := app.window.pixel_ratio
			mx := f32(ev.button.x) * ratio
			my := f32(ev.button.y) * ratio
			mods := sdl3.GetModState()
			is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
			is_alt   := (mods & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
			is_ctrl  := (mods & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE
			if pane != nil && mouse_protocol_should_handle(pane.session, is_shift) {
				if seq, ok := mouse_protocol_encode(pane.session, .Release, u8(ev.button.button), mx, my, pane.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y, 0.0, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write_string(pane.session, seq)
				}
			}
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

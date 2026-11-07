package term

// Term Event Processing, Input Routing & Dispatch
// Part of Tier 3 Application Shell (src/app/term/*).

import "base:intrinsics"
import "base:runtime"
import "core:time"
import "vendor:sdl3"

import cursor "../../core/cursor"
import plat_win "../../platform/window"
import contract "../../core/render/contract"
import chrome_render "../../core/render/chrome"
import chrome_hit "../../core/chrome/hit_test"
import chrome_splits "../../core/chrome/splits"
import damage "../../core/terminal/damage"
import core_terminal "../../core/terminal"
import ie "../../core/terminal/input_encode"
import tabs_feat "../../features/tabs"
import mux_feat "../../features/multiplexer"
import sess_feat "../../features/session"

// FRAME_TICK_MS is the WaitEventTimeout wake interval: it paces cursor blink and
// tab-bar animation, and bounds PTY output latency when no SDL event arrives.
FRAME_TICK_MS :: 8

app_handle_window_resize :: proc(app: ^Term_App) -> bool {
	curr_fs := plat_win.platform_is_fullscreen(app.window.handle)
	fs_changed := app.layout.is_fullscreen != curr_fs
	app.layout.is_fullscreen = curr_fs

	if fs_changed && !app.layout.is_fullscreen {
		// SDL3 resets NSWindow styleMask & titlebar properties when exiting macOS fullscreen space.
		// Re-apply unified titlebar (FullSizeContentView, TitleHidden, TitlebarAppearsTransparent)
		// BEFORE querying pixel size and computing size_changed so setStyleMask:'s synchronous
		// viewport update is captured in the same pass.
		plat_win.platform_setup_unified_titlebar(app.window.handle)
		blur_enabled := config_resolve_window_blur(&app.config)
		plat_win.platform_setup_metal_layer(app.window.handle, !blur_enabled)
	}

	plat_win.window_update_pixel_size(&app.window)
	if app.window.pixel_w <= 0 || app.window.pixel_h <= 0 do return false

	scale := app.window.pixel_ratio
	scale_changed := app.layout.metrics.scale != scale
	layout_set_scale(&app.layout, scale)

	if app.text_atlas.cell_w > 0 {
		app.layout.metrics.cell_w = app.text_atlas.cell_w
		app.layout.metrics.cell_h = app.text_atlas.cell_h
	}
	if app.text_atlas.ui_cell_w > 0 {
		app.layout.metrics.ui_cell_w = app.text_atlas.ui_cell_w
		app.layout.metrics.ui_cell_h = app.text_atlas.ui_cell_h
		app.layout.metrics.ui_atlas = &app.text_atlas.ui_glyph_atlas.atlas
	}

	target_w := f32(app.window.pixel_w)
	target_h := f32(app.window.pixel_h)
	size_changed := app.layout.screen_w != target_w ||
		app.layout.screen_h != target_h ||
		app.composer.screen_w != target_w ||
		app.composer.screen_h != target_h ||
		scale_changed

	if !size_changed && !fs_changed do return false

	// Rendering pipeline is fully in pixel space.
	app.layout.screen_w = target_w
	app.layout.screen_h = target_h

	if size_changed {
		contract.configure_surface(app.surface, app.device, app.format, u32(app.window.pixel_w), u32(app.window.pixel_h))
		composer_view_resize(&app.composer, app.layout.screen_w, app.layout.screen_h)
		chrome_view_resize(&app.chrome_view, u32(app.layout.screen_w), u32(app.layout.screen_h))
	}

	app.mouse.cell_w = app.layout.metrics.cell_w
	app.mouse.cell_h = app.layout.metrics.cell_h
	app.mouse.pad_x = app.layout.metrics.pane_pad_x
	app.mouse.pad_y = app.layout.metrics.pane_pad_y

	app_sync_layout_and_winsize(app, false)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	return true
}

app_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	if event == nil || userdata == nil do return true
	#partial switch event.type {
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED, .WINDOW_LEAVE_FULLSCREEN, .WINDOW_ENTER_FULLSCREEN, .WINDOW_RESTORED:
		app := (^Term_App)(userdata)
		if app == nil || !app.running || app.window.handle == nil do return true
		if event.window.windowID != sdl3.GetWindowID(app.window.handle) do return true
		if app.in_event_watch {
			app.resize_pending = true
			return true
		}
		context = runtime.default_context()
		defer free_all(context.temp_allocator)
		app.in_event_watch = true
		defer app.in_event_watch = false
		for {
			app.resize_pending = false
			drained_pre := mux_feat.multiplexer_drain_all(&app.mux)
			resized := app_handle_window_resize(app)
			drained_post := mux_feat.multiplexer_drain_all(&app.mux)
			expose := event.type == .WINDOW_EXPOSED || event.type == .WINDOW_RESTORED
			if resized || drained_pre > 0 || drained_post > 0 || expose {
				app_render_frame(app, true)
			}
			if !app.resize_pending do break
		}
	}
	return true
}

app_handle_mouse_button_down :: proc(app: ^Term_App, ev: sdl3.MouseButtonEvent) {
	// Scale SDL3 logical coords to pixel space on Retina displays.
	ratio := app.window.pixel_ratio
	mx := f32(ev.x) * ratio
	my := f32(ev.y) * ratio

	if quit_dialog_handle_click(app, mx, my) {
		chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
		return
	}
	if app.cmd_center.visible {
		res := command_center_handle_click(&app.cmd_center, mx, my, app_command_center_sources(app))
		if res.handled {
			app_apply_command_center_result(app, res)
			return
		}
	}

	// Click on tab pills, buttons, or free space in tab bar
	pill_w := session_pill_width(&app.layout, &app.session_reg)
	if hover, in_bar := tab_bar_hit_test(&app.layout, len(app.tabs_mgr.entries), pill_w, mx, my); in_bar {
		switch hover.kind {
		case .Overview:
			app_execute_action(app, .Tab_Overview_Toggle)
		case .New_Tab:
			app_execute_action(app, .Tab_New)
		case .Session_Pill:
			app_execute_action(app, .Sessions_Toggle)
		case .Tab_Close:
			app_close_tab(app, hover.tab_idx)
			new_hover, _ := tab_bar_hit_test(&app.layout, len(app.tabs_mgr.entries), session_pill_width(&app.layout, &app.session_reg), mx, my)
			app.layout.tab_bar_hover = new_hover
		case .Tab:
			app_select_tab(app, hover.tab_idx)
		case .None:
			if ev.clicks == 2 {
				plat_win.platform_toggle_maximize(app.window.handle)
			}
		}
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

	// 2. Scrollbar thumb drag (scrollback) takes precedence over selection.
	if ev.button == sdl3.BUTTON_LEFT {
		if pane := scrollbar_hit_pane(app, mx, my); pane != nil {
			if scrollbar_begin_drag(app, pane, my) {
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				return
			}
		}
	}

	// 3. Cmd+Click on an OSC 8 hyperlink opens it in the default browser.
	if ev.button == sdl3.BUTTON_LEFT && (sdl3.GetModState() & sdl3.KMOD_GUI) != sdl3.KMOD_NONE {
		if app_open_hyperlink_at(app, mx, my) do return
	}

	// 4. Left-click on split divider or drag handle button
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
				eff_px, eff_py := pane_grid_pad(p.rect, p.session.term.rows, p.session.term.cols, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
				if seq, ok := mouse_protocol_encode(p.session, .Press, u8(ev.button), mx, my, p.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, eff_px, eff_py, 0.0, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write(p.session, seq.bytes[:seq.len])
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
	if app.quit.dialog.visible do return
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
		pill_w := session_pill_width(&app.layout, &app.session_reg)
		layout_tab_bar_clamp_scroll(&app.layout, len(app.tabs_mgr.entries), pill_w)
		new_hover, _ := tab_bar_hit_test(&app.layout, len(app.tabs_mgr.entries), pill_w, mx, my)
		app.layout.tab_bar_hover = new_hover
		chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
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
				eff_px, eff_py := pane_grid_pad(target_pane.rect, sess.term.rows, sess.term.cols, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
				if seq, ok := mouse_protocol_encode(sess, .Wheel, 0, mx, my, target_pane.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, eff_px, eff_py, wheel_dir, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write(sess, seq.bytes[:seq.len])
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
	if app.quit.dialog.visible do return // modal: typing never reaches a pane
	if app.suppress_text_input {
		app.suppress_text_input = false
		return
	}
	if app.search.active {
		app_search_append(app, text)
	} else if app.cmd_center.visible {
		command_center_handle_text(&app.cmd_center, text, app_command_center_sources(app))
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
	if quit_dialog_handle_key(app, ev.key) {
		chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
		return
	}
	if app.search.active {
		switch ev.key {
		case sdl3.K_ESCAPE:
			app_search_close(app)
			return
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			app_search_step(app, (ev.mod & sdl3.KMOD_SHIFT) == sdl3.KMOD_NONE)
			return
		}
		if app_search_handle_key(app, ev.key, ev.mod) {
			return
		}
	}

	if app.cmd_center.visible {
		res := command_center_handle_key(&app.cmd_center, ev.key, ev.mod, app_command_center_sources(app))
		if res.handled {
			app_apply_command_center_result(app, res)
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
		if p == nil || p.session == nil do return
		kev, res, encoded := _encode_sdl_key(p.session, ev, .Repeat if ev.repeat else .Press)
		if !encoded do return
		if app.mouse.selection.active {
			mouse_clear_selection(&app.mouse)
		}
		p.session.scroll_offset = 0 // Auto-scroll to bottom on input
		sess_feat.session_write(p.session, res.bytes[:res.len])
		// A keystroke that SDL also reports as TEXT_INPUT must not be
		// delivered twice: Option combos arrive as ESC+char and, under the
		// Kitty "report all keys" flag, plain printable keys arrive as
		// CSI u while the platform still emits the character as text.
		if kev.mods & {.Super, .Ctrl} == {} && ie.key_is_printable(kev) {
			app.suppress_text_input = true
		}
	}
}

// _encode_sdl_key encodes an SDL key for the program in sess, with the modes
// it asked for (DECCKM, Kitty keyboard flags).
@(private = "file")
_encode_sdl_key :: proc(sess: ^sess_feat.Terminal_Session, ev: sdl3.KeyboardEvent, kind: ie.Key_Event_Kind) -> (kev: ie.Key_Event, res: ie.Encoded, ok: bool) {
	kev = sdl_key_event(ev.key, ev.mod, kind) or_return
	modes := ie.Key_Modes{
		app_cursor  = sess.term.parser.cursor_key_mode,
		kitty_flags = core_terminal.terminal_kitty_keyboard_flags(&sess.term),
	}
	res = ie.encode_key(kev, modes) or_return
	return kev, res, true
}

// app_handle_key_up reports key releases when the application enabled the Kitty
// keyboard protocol's event-type reporting.
app_handle_key_up :: proc(app: ^Term_App, ev: sdl3.KeyboardEvent) {
	p := mux_feat.multiplexer_get_focused_pane(&app.mux)
	if p == nil || p.session == nil do return

	// encode_key reports a release only under Kitty event-type reporting and
	// never for keys sent as legacy bytes (they have no event field).
	_, res, encoded := _encode_sdl_key(p.session, ev, .Release)
	if !encoded do return
	sess_feat.session_write(p.session, res.bytes[:res.len])
}

// app_update_hyperlink_hover synchronizes the OSC 8 hover highlight and mouse
// cursor against the pointer's position and the Cmd modifier state.
// - Background tint: shows whenever hovering over a link (plain hover OR Cmd+hover).
// - Mouse cursor: changes to Hand (Pointer) / Not_Allowed ONLY when Cmd is held!
app_update_hyperlink_hover :: proc(app: ^Term_App) -> bool {
	if app == nil do return false
	mods := sdl3.GetModState()
	is_cmd := (mods & sdl3.KMOD_GUI) != sdl3.KMOD_NONE
	is_shift := (mods & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
	mx, my := app.mouse.pos.x, app.mouse.pos.y

	hovered_pane: ^mux_feat.Pane_Entry = nil
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			hovered_pane = &p
			break
		}
	}

	new_hover: Hyperlink_Hover
	if !app.mouse.is_down && hovered_pane != nil && hovered_pane.kind == .Terminal && hovered_pane.session != nil {
		new_hover = app_hyperlink_highlight(app, mx, my)
	}

	changed := (app.mouse.hover_link != new_hover)
	app.mouse.hover_link = new_hover

	if hovered_pane != nil && hovered_pane.kind == .Terminal && hovered_pane.session != nil {
		if is_cmd && new_hover.active {
			app_set_mouse_cursor(.Not_Allowed if new_hover.blocked else .Pointer)
		} else {
			app_set_mouse_cursor(sess_feat.session_get_mouse_cursor(hovered_pane.session, is_shift))
		}
	} else {
		app_set_mouse_cursor(.Default)
	}

	return changed
}

app_handle_drop_position :: proc(app: ^Term_App, drop: sdl3.DropEvent) {
	if app == nil || !app.drop_effect.enabled do return
	ratio := app.window.pixel_ratio
	mx := f32(drop.x) * ratio
	my := f32(drop.y) * ratio

	target_pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			target_pane = &p
			break
		}
	}
	p_id := target_pane.id if target_pane != nil else 0
	p_rect := target_pane.rect if target_pane != nil else [4]f32{0, 0, app.layout.screen_w, app.layout.screen_h}
	drop_effect_on_drag_pos(&app.drop_effect, {mx, my}, p_id, p_rect)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
}

app_handle_drop_file :: proc(app: ^Term_App, drop: sdl3.DropEvent, is_text: bool = false) {
	if app == nil do return
	ratio := app.window.pixel_ratio
	mx := f32(drop.x) * ratio
	my := f32(drop.y) * ratio

	target_pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
	for &p in app.mux.panes {
		if mouse_is_in_rect({mx, my}, p.rect) {
			target_pane = &p
			break
		}
	}
	if target_pane != nil {
		mux_feat.multiplexer_focus_pane(&app.mux, target_pane.id)
	}
	p_id := target_pane.id if target_pane != nil else 0
	p_rect := target_pane.rect if target_pane != nil else [4]f32{0, 0, app.layout.screen_w, app.layout.screen_h}
	drop_effect_on_drop(&app.drop_effect, {mx, my}, p_id, p_rect)

	if target_pane != nil && target_pane.session != nil && drop.data != nil {
		raw_data := string(drop.data)
		payload := escape_shell_path(raw_data, context.temp_allocator) if !is_text else raw_data
		if len(payload) > 0 {
			sess_feat.session_write_string(target_pane.session, payload)
		}
	}
	if app.drop_effect.enabled {
		chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	}
}

app_wakeup_callback :: proc "contextless" (user_data: rawptr) {
	if user_data == nil do return
	app := (^Term_App)(user_data)
	if !intrinsics.atomic_exchange_explicit(&app.wakeup_pending, true, .Acq_Rel) {
		ev: sdl3.Event
		ev.type = .USER
		_ = sdl3.PushEvent(&ev)
	}
}

app_compute_wait_timeout_ms :: proc(app: ^Term_App, non_blocking: bool) -> i32 {
	if app == nil || non_blocking do return 0
	if intrinsics.atomic_load_explicit(&app.wakeup_pending, .Acquire) do return 0
	if app.last_frame_acquire_failed do return FRAME_TICK_MS
	if app.composer.sched.force_next || app.composer.sched.damage_pending do return 0
	if app_needs_animation(app) || _app_any_pane_sync_output(app) do return FRAME_TICK_MS
	if len(app.diag.grid_dump_dir) > 0 do return 16

	timeout_ms := app_quit_wait_ms(app)
	if app.layout.is_fullscreen && app.layout.tab_bar_reveal_timer > 0.0 {
		reveal_ms := max(1, i32(app.layout.tab_bar_reveal_timer * 1000.0) + 1)
		if timeout_ms < 0 || reveal_ms < timeout_ms do timeout_ms = reveal_ms
	}

	if app.composer.sched.next_deadline > 0 {
		now_ns := u64(time.duration_nanoseconds(time.since(app.start_time)))
		if now_ns >= app.composer.sched.next_deadline do return 0
		rem_ms := max(1, i32((app.composer.sched.next_deadline - now_ns + 999_999) / 1_000_000))
		if timeout_ms < 0 || rem_ms < timeout_ms {
			timeout_ms = rem_ms
		}
	}
	return timeout_ms
}

App_Event_Dirty :: struct {
	term:   bool,
	chrome: bool,
}

app_process_events :: proc(app: ^Term_App, non_blocking: bool = false) -> (dirty: App_Event_Dirty) {
	ev: sdl3.Event
	timeout_ms := app_compute_wait_timeout_ms(app, non_blocking)
	if timeout_ms == 0 {
		if !sdl3.PollEvent(&ev) {
			intrinsics.atomic_store_explicit(&app.wakeup_pending, false, .Release)
			return {}
		}
	} else if timeout_ms < 0 {
		if !sdl3.WaitEvent(&ev) {
			intrinsics.atomic_store_explicit(&app.wakeup_pending, false, .Release)
			return {}
		}
	} else {
		if !sdl3.WaitEventTimeout(&ev, timeout_ms) {
			intrinsics.atomic_store_explicit(&app.wakeup_pending, false, .Release)
			return {}
		}
	}
	intrinsics.atomic_store_explicit(&app.wakeup_pending, false, .Release)

	for {
		app.window_visible = app_window_visible_after(app.window_visible, ev.type)
		#partial switch ev.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			dirty.chrome = true
			app_request_quit_flow(app)
		case .WINDOW_FOCUS_GAINED:
			app.window_focused = true
			cursor_reset_blink(&app.cursor, u64(time.duration_nanoseconds(time.since(app.start_time))))
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if pane != nil && pane.session != nil {
				mouse_protocol_report_focus(pane.session, true)
			}
			dirty.term = true
			dirty.chrome = true
		case .WINDOW_FOCUS_LOST:
			app.window_focused = false
			pane := mux_feat.multiplexer_get_focused_pane(&app.mux)
			if pane != nil && pane.session != nil {
				mouse_protocol_report_focus(pane.session, false)
			}
			if app.mouse.hover_link.active {
				dirty.term = true
			}
			if app.layout.tab_bar_hover.kind != .None {
				app.layout.tab_bar_hover = {kind = .None, tab_idx = -1}
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				dirty.chrome = true
			}
			app.mouse.hover_link = {}
			app_set_mouse_cursor(.Default)
			dirty.term = true
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_EXPOSED, .WINDOW_LEAVE_FULLSCREEN, .WINDOW_ENTER_FULLSCREEN, .WINDOW_RESTORED:
			sdl3.FlushEvents(sdl3.EventType.WINDOW_RESIZED, sdl3.EventType.WINDOW_PIXEL_SIZE_CHANGED)
			if app_handle_window_resize(app) || ev.type == .WINDOW_EXPOSED || ev.type == .WINDOW_RESTORED {
				dirty.term = true
				dirty.chrome = true
			}
		case .MOUSE_MOTION:
			ratio := app.window.pixel_ratio
			mx := f32(ev.motion.x) * ratio
			my := f32(ev.motion.y) * ratio
			prev_mouse_y := app.layout.mouse_y
			app.layout.mouse_y = my
			app.mouse.pos = {mx, my}
			if app.layout.is_fullscreen && ((prev_mouse_y <= app.layout.metrics.auto_hide_trigger_y) != (my <= app.layout.metrics.auto_hide_trigger_y)) {
				dirty.chrome = true
			}

			if app.quit.dialog.visible {
				if app.layout.tab_bar_hover.kind != .None {
					app.layout.tab_bar_hover = {kind = .None, tab_idx = -1}
					chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					dirty.chrome = true
				}
				if quit_dialog_handle_motion(app, mx, my) {
					chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					dirty.chrome = true
				}
				if !sdl3.PollEvent(&ev) do break
				continue
			}
			if app.cmd_center.visible {
				if app.layout.tab_bar_hover.kind != .None {
					app.layout.tab_bar_hover = {kind = .None, tab_idx = -1}
					chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					dirty.chrome = true
				}
				if command_center_handle_motion(&app.cmd_center, mx, my) {
					chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					dirty.chrome = true
				}
				if !sdl3.PollEvent(&ev) do break
				continue
			}

			new_tb_hover, in_tb := tab_bar_hit_test(&app.layout, len(app.tabs_mgr.entries), session_pill_width(&app.layout, &app.session_reg), mx, my)
			app.layout.tab_bar_hovered = in_tb
			if new_tb_hover != app.layout.tab_bar_hover {
				app.layout.tab_bar_hover = new_tb_hover
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				dirty.chrome = true
			}

			// A0. Dragging the scrollback thumb
			if scrollbar_drag_active(app) {
				dirty.chrome = true
				if pane := mux_feat.multiplexer_get_pane(&app.mux, app.mouse.scrollbar_pane_id); pane != nil {
					scrollbar_update_drag(app, pane, my)
					chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
					dirty.term = true
				}
				if !sdl3.PollEvent(&ev) do break
				continue
			}

			// A. If dragging split divider, dynamically update partition ratio
			if app.mouse.is_dragging_divider && app.mouse.drag_split_node != nil {
				dirty.chrome = true
				dirty.term = true
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

			// A1. Scrollbar hover highlight
			hovered_sb: u32 = 0
			if pane := scrollbar_hit_pane(app, mx, my); pane != nil do hovered_sb = pane.id
			if hovered_sb != app.mouse.hovered_scrollbar {
				app.mouse.hovered_scrollbar = hovered_sb
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				dirty.chrome = true
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
						dirty.chrome = true
					}
				}
			}
			if prev_hovered != nil && app.mouse.hovered_split_node == nil {
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
				dirty.chrome = true
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

			// C. Autonomous Cursor Determination: Chrome View -> Hyperlink (Cmd-gated) -> Terminal/Session -> Window Default
			if !divider_cursor_handled {
				if cur, handled := chrome_view_cursor(&app.chrome_view, &app.layout, &app.tabs_mgr, &app.cmd_center, {mx, my}, &app.session_reg); handled {
					if app.mouse.hover_link.active do dirty.term = true
					app.mouse.hover_link = {}
					app_set_mouse_cursor(cur)
				} else if hovered_pane != nil {
					if hovered_pane.kind == .Terminal && hovered_pane.session != nil {
						if app_update_hyperlink_hover(app) do dirty.term = true
					} else {
						if app.mouse.hover_link.active do dirty.term = true
						app.mouse.hover_link = {}
						app_set_mouse_cursor(.Default)
					}
				} else {
					if app.mouse.hover_link.active do dirty.term = true
					app.mouse.hover_link = {}
					app_set_mouse_cursor(.Default)
				}
			}

			pane := hovered_pane if hovered_pane != nil else mux_feat.multiplexer_get_focused_pane(&app.mux)
			pane_rect := pane.rect if pane != nil else [4]f32{0, 0, 0, 0}
			sess := pane.session if pane != nil else nil
			scroll_off := sess.scroll_offset if sess != nil else 0

			// Report mouse motion only to the focused pane when hovered or when dragging within it
			if pane != nil && pane.is_focused && mouse_protocol_should_handle(sess, is_shift) {
				// The tracking mode (?1002 drag / ?1003 any motion) decides what is reported.
				btn := app.mouse.button if app.mouse.is_down else u8(0)
				eff_px, eff_py := pane_grid_pad(pane_rect, sess.term.rows, sess.term.cols, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
				if seq, ok := mouse_protocol_encode(sess, .Motion, btn, mx, my, pane_rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, eff_px, eff_py, 0.0, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write(sess, seq.bytes[:seq.len])
				}
			} else {
				prev_sel := app.mouse.selection
				mouse_on_motion(&app.mouse, {mx, my}, pane_rect, sess, scroll_off)
				if app.mouse.selection != prev_sel {
					dirty.term = true
				}
			}
		case .MOUSE_BUTTON_DOWN:
			dirty.chrome = true
			dirty.term = true
			app_handle_mouse_button_down(app, ev.button)
		case .MOUSE_BUTTON_UP:
			dirty.chrome = true
			dirty.term = true
			if scrollbar_drag_active(app) {
				scrollbar_end_drag(app)
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
			}
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
				eff_px, eff_py := pane_grid_pad(pane.rect, pane.session.term.rows, pane.session.term.cols, app.layout.metrics.cell_w, app.layout.metrics.cell_h, app.layout.metrics.pane_pad_x, app.layout.metrics.pane_pad_y)
				if seq, ok := mouse_protocol_encode(pane.session, .Release, u8(ev.button.button), mx, my, pane.rect, app.layout.metrics.cell_w, app.layout.metrics.cell_h, eff_px, eff_py, 0.0, is_shift, is_alt, is_ctrl); ok {
					sess_feat.session_write(pane.session, seq.bytes[:seq.len])
				}
			}
			mouse_on_button_up(&app.mouse, u8(ev.button.button))
		case .MOUSE_WHEEL:
			dirty.term = true
			dirty.chrome = true
			app_handle_mouse_wheel(app, ev.wheel)
		case .TEXT_INPUT:
			dirty.term = true
			dirty.chrome = true
			cursor_reset_blink(&app.cursor, u64(time.duration_nanoseconds(time.since(app.start_time))))
			app_handle_text_input(app, string(ev.text.text))
		case .KEY_DOWN:
			dirty.term = true
			dirty.chrome = true
			cursor_reset_blink(&app.cursor, u64(time.duration_nanoseconds(time.since(app.start_time))))
			app_handle_key_down(app, ev.key)
			if app_update_hyperlink_hover(app) do dirty.term = true
		case .KEY_UP:
			app_handle_key_up(app, ev.key)
			if app_update_hyperlink_hover(app) do dirty.term = true
		case .DROP_BEGIN:
			dirty.chrome = true
			drop_effect_on_drag_begin(&app.drop_effect)
			if app.drop_effect.enabled {
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
			}
		case .DROP_POSITION:
			dirty.chrome = true
			app_handle_drop_position(app, ev.drop)
		case .DROP_FILE:
			dirty.chrome = true
			dirty.term = true
			app_handle_drop_file(app, ev.drop, false)
		case .DROP_TEXT:
			dirty.chrome = true
			dirty.term = true
			app_handle_drop_file(app, ev.drop, true)
		case .DROP_COMPLETE:
			dirty.chrome = true
			drop_effect_on_drag_complete(&app.drop_effect)
			if app.drop_effect.enabled {
				chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
			}
		}

		if !sdl3.PollEvent(&ev) do break
	}
	return dirty
}

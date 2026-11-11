package term

// Keyboard dispatch, modal management, and action execution for `term studio`.

studio_open_modal :: proc(s: ^Studio_State, kind: Studio_Modal_Kind) {
	s.modal = kind
	switch kind {
	case .Palette:
		s.palette_query_len = 0
		s.palette_sel = 1
		studio_osc_popup(10, 48, 12, .Center, 0, 0, 100, .Modal, true, "Developer Actions (OSC 8400)")
		studio_paint_palette(s)
	case .Inspect:
		studio_osc_popup(11, 56, 13, .Center, 0, 0, 100, .Modal, true, "Process Inspector")
		studio_paint_inspector(s)
	case .Help:
		studio_osc_popup(12, 58, 14, .Center, 0, 0, 100, .Modal, true, "Studio Shortcuts & Cheatsheet")
		studio_paint_help(s)
	case .None:
	}
}

studio_close_modal :: proc(s: ^Studio_State) {
	if s.modal == .None do return
	id := u16(s.modal)
	s.modal = .None
	studio_osc_close(id)
	studio_osc_focus(0)
	s.focused_surface = 0
	studio_paint_root(s)
}

studio_exec_action :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	switch key {
	case "sigint-session":
		_ = studio_session_sigint(s)
		studio_session_update_tail(s, false)
		studio_close_modal(s)
	case "kill-session":
		_ = studio_session_kill(s)
		studio_session_refresh(s, false)
		studio_close_modal(s)
	case "new-session":
		studio_close_modal(s)
	case "refresh-list":
		studio_session_refresh(s, false)
		studio_session_update_tail(s, false)
		studio_close_modal(s)
	case "toggle-scope":
		s.scope = .Global if s.scope == .Session else .Session
		studio_session_refresh(s, false)
		studio_session_update_tail(s, false)
		studio_close_modal(s)
	case "toggle-stream":
		s.stream_paused = !s.stream_paused
		studio_close_modal(s)
	case "show-help":
		studio_close_modal(s)
		studio_open_modal(s, .Help)
	case "quit-app":
		return true
	}
	return false
}

studio_handle_key :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	if s.modal == .Palette {
		return _studio_handle_palette_key(s, key)
	} else if s.modal == .Inspect || s.modal == .Help {
		if key == "\x1b" || key == "q" || key == "i" || key == "?" || key == "\r" {
			studio_close_modal(s)
		}
		return false
	}
	return _studio_handle_root_key(s, key)
}

@(private = "file")
_studio_handle_palette_key :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	if key == "\x1b" || key == "\x03" {
		studio_close_modal(s)
	} else if key == "\r" || key == "\n" {
		idx := clamp(s.palette_sel - 1, 0, len(s.palette_actions) - 1)
		return studio_exec_action(s, s.palette_actions[idx].key)
	} else if key == "\x1b[A" || key == "k" {
		s.palette_sel = max(1, s.palette_sel - 1)
		studio_paint_palette(s)
	} else if key == "\x1b[B" || key == "j" {
		s.palette_sel = min(len(s.palette_actions), s.palette_sel + 1)
		studio_paint_palette(s)
	} else if key == "\x7f" || key == "\b" {
		if s.palette_query_len > 0 {
			s.palette_query_len -= 1
			s.palette_sel = 1
			studio_paint_palette(s)
		}
	} else if len(key) == 1 && key[0] >= 32 && key[0] <= 126 {
		if s.palette_query_len < len(s.palette_query_buf) {
			s.palette_query_buf[s.palette_query_len] = key[0]
			s.palette_query_len += 1
			s.palette_sel = 1
			studio_paint_palette(s)
		}
	}
	return false
}

@(private = "file")
_studio_step_row :: proc(s: ^Studio_State, delta: int) {
	s.selected_row = clamp(s.selected_row + delta, 1, max(1, s.session_count))
	studio_session_update_tail(s, false)
	studio_paint_root(s)
}

@(private = "file")
_studio_handle_root_key :: proc(s: ^Studio_State, key: string) -> (should_quit: bool) {
	switch key {
	case "q", "\x03": return true
	case "j", "\x1b[B": _studio_step_row(s, 1)
	case "k", "\x1b[A": _studio_step_row(s, -1)
	case "x":
		_ = studio_session_sigint(s)
		studio_session_update_tail(s, false)
		studio_paint_root(s)
	case "r", "o":
		if key == "o" do s.scope = .Global if s.scope == .Session else .Session
		studio_session_refresh(s, false)
		studio_session_update_tail(s, false)
		studio_paint_root(s)
	case "\t":
		s.focused_surface = (s.focused_surface + 1) % 3
		studio_osc_focus(s.focused_surface)
		studio_paint_root(s)
	case "p", ":": studio_open_modal(s, .Palette)
	case "i", "\r", "\n": studio_open_modal(s, .Inspect)
	case "?": studio_open_modal(s, .Help)
	case "s", " ":
		s.stream_paused = !s.stream_paused
		studio_paint_root(s)
	case "1", "2", "3":
		s.active_tab = int(key[0] - '0')
		studio_paint_root(s)
	}
	return false
}

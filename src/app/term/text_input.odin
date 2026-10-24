package term

// Composable, zero-allocation text field editing primitive.
// Part of Tier 3 Application Shell (src/app/term/*).
// Supports cursor positioning, text selection, UTF-8 editing, and macOS shortcuts.

import "vendor:sdl3"

MAX_TEXT_INPUT :: 256

Text_Input :: struct {
	buf:        [MAX_TEXT_INPUT]u8,
	len:        int,
	cursor:     int,
	sel_anchor: int,
	sel_active: bool,
}

text_input_init :: proc(ti: ^Text_Input) {
	if ti == nil do return
	ti.len = 0
	ti.cursor = 0
	ti.sel_anchor = 0
	ti.sel_active = false
}

text_input_clear :: proc(ti: ^Text_Input) {
	if ti == nil do return
	ti.len = 0
	ti.cursor = 0
	ti.sel_anchor = 0
	ti.sel_active = false
}

text_input_as_string :: proc(ti: ^Text_Input) -> string {
	if ti == nil || ti.len <= 0 do return ""
	return string(ti.buf[:ti.len])
}

text_input_selection_range :: proc(ti: ^Text_Input) -> (start: int, end: int, active: bool) {
	if ti == nil || !ti.sel_active || ti.sel_anchor == ti.cursor do return 0, 0, false
	s := min(ti.sel_anchor, ti.cursor)
	e := max(ti.sel_anchor, ti.cursor)
	return s, e, true
}

text_input_clear_selection :: proc(ti: ^Text_Input) {
	if ti == nil do return
	ti.sel_active = false
	ti.sel_anchor = ti.cursor
}

text_input_select_all :: proc(ti: ^Text_Input) {
	if ti == nil || ti.len == 0 do return
	ti.sel_anchor = 0
	ti.cursor = ti.len
	ti.sel_active = true
}

text_input_delete_selection :: proc(ti: ^Text_Input) -> bool {
	s, e, active := text_input_selection_range(ti)
	if !active do return false
	copy(ti.buf[s:], ti.buf[e:ti.len])
	ti.len -= (e - s)
	ti.cursor = s
	ti.sel_active = false
	ti.sel_anchor = s
	return true
}

text_input_insert :: proc(ti: ^Text_Input, text: string) -> bool {
	if ti == nil || len(text) == 0 do return false
	text_input_delete_selection(ti)
	space := MAX_TEXT_INPUT - ti.len
	to_copy := min(len(text), space)
	if to_copy <= 0 do return false
	// Shift bytes to right
	copy(ti.buf[ti.cursor + to_copy:], ti.buf[ti.cursor:ti.len])
	copy(ti.buf[ti.cursor:ti.cursor + to_copy], text[:to_copy])
	ti.len += to_copy
	ti.cursor += to_copy
	ti.sel_active = false
	ti.sel_anchor = ti.cursor
	return true
}

text_input_delete_back :: proc(ti: ^Text_Input) -> bool {
	if ti == nil do return false
	if text_input_delete_selection(ti) do return true
	if ti.cursor <= 0 do return false
	prev := ti.cursor - 1
	for prev > 0 && (ti.buf[prev] & 0xC0) == 0x80 do prev -= 1
	codepoint_len := ti.cursor - prev
	copy(ti.buf[prev:], ti.buf[ti.cursor:ti.len])
	ti.len -= codepoint_len
	ti.cursor = prev
	return true
}

text_input_delete_word_back :: proc(ti: ^Text_Input) -> bool {
	if ti == nil do return false
	if text_input_delete_selection(ti) do return true
	if ti.cursor <= 0 do return false
	idx := ti.cursor
	for idx > 0 && (ti.buf[idx - 1] == ' ' || ti.buf[idx - 1] == '\t') do idx -= 1
	for idx > 0 && ti.buf[idx - 1] != ' ' && ti.buf[idx - 1] != '\t' do idx -= 1
	del_len := ti.cursor - idx
	copy(ti.buf[idx:], ti.buf[ti.cursor:ti.len])
	ti.len -= del_len
	ti.cursor = idx
	return true
}

text_input_delete_to_start :: proc(ti: ^Text_Input) -> bool {
	if ti == nil do return false
	if text_input_delete_selection(ti) do return true
	if ti.cursor <= 0 do return false
	copy(ti.buf[0:], ti.buf[ti.cursor:ti.len])
	ti.len -= ti.cursor
	ti.cursor = 0
	return true
}

text_input_move_cursor :: proc(ti: ^Text_Input, forward: bool, word_jump: bool, select: bool) {
	if ti == nil do return
	if select {
		if !ti.sel_active {
			ti.sel_anchor = ti.cursor
			ti.sel_active = true
		}
	} else if ti.sel_active {
		s, e, _ := text_input_selection_range(ti)
		ti.sel_active = false
		ti.cursor = e if forward else s
		return
	}

	if forward {
		if word_jump {
			for ti.cursor < ti.len && ti.buf[ti.cursor] != ' ' && ti.buf[ti.cursor] != '\t' do ti.cursor += 1
			for ti.cursor < ti.len && (ti.buf[ti.cursor] == ' ' || ti.buf[ti.cursor] == '\t') do ti.cursor += 1
		} else if ti.cursor < ti.len {
			ti.cursor += 1
			for ti.cursor < ti.len && (ti.buf[ti.cursor] & 0xC0) == 0x80 do ti.cursor += 1
		}
	} else {
		if word_jump {
			for ti.cursor > 0 && (ti.buf[ti.cursor - 1] == ' ' || ti.buf[ti.cursor - 1] == '\t') do ti.cursor -= 1
			for ti.cursor > 0 && ti.buf[ti.cursor - 1] != ' ' && ti.buf[ti.cursor - 1] != '\t' do ti.cursor -= 1
		} else if ti.cursor > 0 {
			ti.cursor -= 1
			for ti.cursor > 0 && (ti.buf[ti.cursor] & 0xC0) == 0x80 do ti.cursor -= 1
		}
	}
}

text_input_move_boundary :: proc(ti: ^Text_Input, to_end: bool, select: bool) {
	if ti == nil do return
	if select {
		if !ti.sel_active {
			ti.sel_anchor = ti.cursor
			ti.sel_active = true
		}
	} else {
		ti.sel_active = false
	}
	ti.cursor = ti.len if to_end else 0
}

@(private = "file")
_text_input_handle_cmd_key :: proc(ti: ^Text_Input, key: sdl3.Keycode, is_shift: bool) -> (changed: bool, handled: bool) {
	if !is_shift {
		switch key {
		case sdl3.K_A:
			text_input_select_all(ti); return false, true
		case sdl3.K_BACKSPACE, sdl3.K_DELETE:
			if ti.len == 0 do return false, true
			text_input_clear(ti)
			return true, true
		case sdl3.K_LEFT:
			text_input_move_boundary(ti, to_end = false, select = false); return false, true
		case sdl3.K_RIGHT:
			text_input_move_boundary(ti, to_end = true, select = false); return false, true
		}
	} else {
		switch key {
		case sdl3.K_LEFT:  text_input_move_boundary(ti, to_end = false, select = true); return false, true
		case sdl3.K_RIGHT: text_input_move_boundary(ti, to_end = true, select = true); return false, true
		}
	}
	return false, false
}

text_input_handle_key :: proc(ti: ^Text_Input, key: sdl3.Keycode, mod: sdl3.Keymod) -> (changed: bool, handled: bool) {
	if ti == nil do return false, false
	is_cmd := (mod & sdl3.KMOD_GUI) != sdl3.KMOD_NONE
	is_alt := (mod & sdl3.KMOD_ALT) != sdl3.KMOD_NONE
	is_ctrl := (mod & sdl3.KMOD_CTRL) != sdl3.KMOD_NONE
	is_shift := (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE

	if is_cmd && !is_alt && !is_ctrl {
		return _text_input_handle_cmd_key(ti, key, is_shift)
	}
	if (is_alt || is_ctrl) && (key == sdl3.K_BACKSPACE || key == sdl3.K_DELETE) {
		return text_input_delete_word_back(ti), true
	}
	switch key {
	case sdl3.K_BACKSPACE: return text_input_delete_back(ti), true
	case sdl3.K_LEFT:
		word := is_alt || is_ctrl
		text_input_move_cursor(ti, forward = false, word_jump = word, select = is_shift)
		return false, true
	case sdl3.K_RIGHT:
		word := is_alt || is_ctrl
		text_input_move_cursor(ti, forward = true, word_jump = word, select = is_shift)
		return false, true
	case sdl3.K_HOME:
		text_input_move_boundary(ti, to_end = false, select = is_shift); return false, true
	case sdl3.K_END:
		text_input_move_boundary(ti, to_end = true, select = is_shift); return false, true
	}
	return false, false
}

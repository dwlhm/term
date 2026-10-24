package term

// Pure Stateless SDL3 Key/Event -> VT Byte Sequence Encoder
// Part of Tier 3 Application Shell (src/app/term/*).
// Invariant: Zero memory allocation in steady-state typing.

import "core:fmt"
import "vendor:sdl3"

INPUT_BUFFER_MAX :: 32

Input_Encode_Result :: struct {
	bytes: [INPUT_BUFFER_MAX]u8,
	len:   int,
}

@(private = "file")
_input_encode_cmd :: proc(key: sdl3.Keycode, is_shift: bool) -> (res: Input_Encode_Result, ok: bool) {
	switch key {
	case sdl3.K_BACKSPACE, sdl3.K_DELETE:
		res.bytes[0] = 0x15 // ^U unix-line-discard / kill-whole-line
		res.len = 1
		return res, true
	case sdl3.K_LEFT:
		if !is_shift {
			res.bytes[0] = 0x01 // ^A start of line
			res.len = 1
			return res, true
		}
	case sdl3.K_RIGHT:
		if !is_shift {
			res.bytes[0] = 0x05 // ^E end of line
			res.len = 1
			return res, true
		}
	}
	return {}, false
}

@(private = "file")
_input_encode_alt :: proc(key: sdl3.Keycode, is_shift: bool) -> (res: Input_Encode_Result, ok: bool) {
	r: rune = 0
	if key >= sdl3.K_A && key <= sdl3.K_Z {
		r = rune(u32(key) - u32(sdl3.K_A) + (u32('A') if is_shift else u32('a')))
	} else if key >= sdl3.K_0 && key <= sdl3.K_9 {
		r = rune(u32(key) - u32(sdl3.K_0) + u32('0'))
	} else if key == sdl3.K_BACKSPACE || key == sdl3.K_DELETE {
		res.bytes[0] = 0x1b; res.bytes[1] = 0x7f; res.len = 2; return res, true
	} else if key == sdl3.K_RETURN || key == sdl3.K_KP_ENTER {
		res.bytes[0] = 0x1b; res.bytes[1] = '\r'; res.len = 2; return res, true
	}

	if r != 0 {
		res.bytes[0] = 0x1b; res.bytes[1] = u8(r); res.len = 2; return res, true
	}
	return {}, false
}

@(private = "file")
_input_encode_ctrl :: proc(key: sdl3.Keycode) -> (res: Input_Encode_Result, ok: bool) {
	if key >= sdl3.K_A && key <= sdl3.K_Z {
		res.bytes[0] = u8(key - sdl3.K_A + 1); res.len = 1; return res, true
	}
	switch key {
	case sdl3.K_BACKSPACE, sdl3.K_DELETE:
		res.bytes[0] = 0x17; res.len = 1; return res, true // ^W unix-word-rubout
	case sdl3.K_SPACE:
		res.bytes[0] = 0x00; res.len = 1; return res, true
	case sdl3.K_LEFTBRACKET:
		res.bytes[0] = 0x1b; res.len = 1; return res, true
	case sdl3.K_BACKSLASH:
		res.bytes[0] = 0x1c; res.len = 1; return res, true
	case sdl3.K_RIGHTBRACKET:
		res.bytes[0] = 0x1d; res.len = 1; return res, true
	}
	return {}, false
}

@(private = "file")
_input_encode_arrows :: proc(key: sdl3.Keycode, xterm_mod: int, app_cursor: bool) -> (res: Input_Encode_Result, ok: bool) {
	arrow_suffix: u8 = 0
	switch key {
	case sdl3.K_UP:    arrow_suffix = 'A'
	case sdl3.K_DOWN:  arrow_suffix = 'B'
	case sdl3.K_RIGHT: arrow_suffix = 'C'
	case sdl3.K_LEFT:  arrow_suffix = 'D'
	}
	if arrow_suffix == 0 do return {}, false

	if xterm_mod > 1 {
		s := fmt.bprintf(res.bytes[:], "\x1b[1;%d%c", xterm_mod, arrow_suffix)
		res.len = len(s)
	} else if app_cursor {
		res.bytes[0] = 0x1b; res.bytes[1] = 'O'; res.bytes[2] = arrow_suffix; res.len = 3
	} else {
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = arrow_suffix; res.len = 3
	}
	return res, true
}

@(private = "file")
_input_encode_special_edit :: proc(key: sdl3.Keycode, xterm_mod: int, is_shift: bool) -> (res: Input_Encode_Result, ok: bool) {
	switch key {
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		res.bytes[0] = '\r'; res.len = 1; return res, true
	case sdl3.K_BACKSPACE:
		res.bytes[0] = 0x7f; res.len = 1; return res, true
	case sdl3.K_TAB:
		if is_shift {
			res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = 'Z'; res.len = 3
		} else {
			res.bytes[0] = '\t'; res.len = 1
		}
		return res, true
	case sdl3.K_ESCAPE:
		res.bytes[0] = 0x1b; res.len = 1; return res, true
	case sdl3.K_INSERT:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[2;%d~", xterm_mod); res.len = len(s)
		} else {
			copy(res.bytes[:], "\x1b[2~"); res.len = 4
		}
		return res, true
	case sdl3.K_DELETE:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[3;%d~", xterm_mod); res.len = len(s)
		} else {
			copy(res.bytes[:], "\x1b[3~"); res.len = 4
		}
		return res, true
	}
	return {}, false
}

@(private = "file")
_input_encode_special_nav :: proc(key: sdl3.Keycode, xterm_mod: int) -> (res: Input_Encode_Result, ok: bool) {
	switch key {
	case sdl3.K_HOME:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[1;%dH", xterm_mod); res.len = len(s)
		} else {
			res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = 'H'; res.len = 3
		}
		return res, true
	case sdl3.K_END:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[1;%dF", xterm_mod); res.len = len(s)
		} else {
			res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = 'F'; res.len = 3
		}
		return res, true
	case sdl3.K_PAGEUP:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[5;%d~", xterm_mod); res.len = len(s)
		} else {
			copy(res.bytes[:], "\x1b[5~"); res.len = 4
		}
		return res, true
	case sdl3.K_PAGEDOWN:
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[6;%d~", xterm_mod); res.len = len(s)
		} else {
			copy(res.bytes[:], "\x1b[6~"); res.len = 4
		}
		return res, true
	}
	return {}, false
}

@(private = "file")
_input_encode_fn :: proc(key: sdl3.Keycode) -> (res: Input_Encode_Result, ok: bool) {
	switch key {
	case sdl3.K_F1:  copy(res.bytes[:], "\x1bOP");  res.len = 3; return res, true
	case sdl3.K_F2:  copy(res.bytes[:], "\x1bOQ");  res.len = 3; return res, true
	case sdl3.K_F3:  copy(res.bytes[:], "\x1bOR");  res.len = 3; return res, true
	case sdl3.K_F4:  copy(res.bytes[:], "\x1bOS");  res.len = 3; return res, true
	case sdl3.K_F5:  copy(res.bytes[:], "\x1b[15~"); res.len = 5; return res, true
	case sdl3.K_F6:  copy(res.bytes[:], "\x1b[17~"); res.len = 5; return res, true
	case sdl3.K_F7:  copy(res.bytes[:], "\x1b[18~"); res.len = 5; return res, true
	case sdl3.K_F8:  copy(res.bytes[:], "\x1b[19~"); res.len = 5; return res, true
	case sdl3.K_F9:  copy(res.bytes[:], "\x1b[20~"); res.len = 5; return res, true
	case sdl3.K_F10: copy(res.bytes[:], "\x1b[21~"); res.len = 5; return res, true
	case sdl3.K_F11: copy(res.bytes[:], "\x1b[23~"); res.len = 5; return res, true
	case sdl3.K_F12: copy(res.bytes[:], "\x1b[24~"); res.len = 5; return res, true
	}
	return {}, false
}

input_encode_key :: proc(
	key: sdl3.Keycode,
	mod: sdl3.Keymod,
	app_cursor: bool = false,
	kitty_flags: u8 = 0,
	kitty_event: u8 = INPUT_EVENT_PRESS,
) -> (res: Input_Encode_Result, ok: bool) {
	if kitty_event == INPUT_EVENT_RELEASE && !_kitty_should_encode(key, mod, kitty_flags) do return {}, false
	if kitty_flags != 0 && _kitty_should_encode(key, mod, kitty_flags) {
		if encoded, encoded_ok := input_encode_key_kitty(key, mod, kitty_flags, kitty_event); encoded_ok {
			return encoded, true
		}
	}

	is_shift := (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
	is_alt   := (mod & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
	is_ctrl  := (mod & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE
	is_cmd   := (mod & sdl3.KMOD_GUI)   != sdl3.KMOD_NONE

	if is_cmd && !is_ctrl && !is_alt {
		if r, cmd_ok := _input_encode_cmd(key, is_shift); cmd_ok do return r, true
	}
	if is_cmd do return {}, false

	if is_alt && !is_ctrl {
		if r, alt_ok := _input_encode_alt(key, is_shift); alt_ok do return r, true
	}
	if is_ctrl && !is_alt {
		if r, ctrl_ok := _input_encode_ctrl(key); ctrl_ok do return r, true
	}

	xterm_mod := 1 + (1 if is_shift else 0) + (2 if is_alt else 0) + (4 if is_ctrl else 0)
	if r, arrow_ok := _input_encode_arrows(key, xterm_mod, app_cursor); arrow_ok do return r, true
	if r, edit_ok := _input_encode_special_edit(key, xterm_mod, is_shift); edit_ok do return r, true
	if r, nav_ok := _input_encode_special_nav(key, xterm_mod); nav_ok do return r, true
	if r, fn_ok := _input_encode_fn(key); fn_ok do return r, true

	return {}, false
}

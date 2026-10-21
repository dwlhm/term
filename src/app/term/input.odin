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

input_encode_key :: proc(key: sdl3.Keycode, mod: sdl3.Keymod, app_cursor: bool = false) -> (res: Input_Encode_Result, ok: bool) {
	is_shift := (mod & sdl3.KMOD_SHIFT) != sdl3.KMOD_NONE
	is_alt   := (mod & sdl3.KMOD_ALT)   != sdl3.KMOD_NONE
	is_ctrl  := (mod & sdl3.KMOD_CTRL)  != sdl3.KMOD_NONE
	is_cmd   := (mod & sdl3.KMOD_GUI)   != sdl3.KMOD_NONE

	// Don't send bytes if GUI/Cmd key is pressed (handled by OS or keymap)
	if is_cmd do return {}, false

	// 1. Alt / Option word navigation and meta prefixes
	if is_alt && !is_ctrl {
		r: rune = 0
		if key >= sdl3.K_A && key <= sdl3.K_Z {
			r = rune(u32(key) - u32(sdl3.K_A) + (u32('A') if is_shift else u32('a')))
		} else if key >= sdl3.K_0 && key <= sdl3.K_9 {
			r = rune(u32(key) - u32(sdl3.K_0) + u32('0'))
		} else if key == sdl3.K_BACKSPACE {
			res.bytes[0] = 0x1b
			res.bytes[1] = 0x7f
			res.len = 2
			return res, true
		} else if key == sdl3.K_RETURN || key == sdl3.K_KP_ENTER {
			res.bytes[0] = 0x1b
			res.bytes[1] = '\r'
			res.len = 2
			return res, true
		}

		if r != 0 {
			res.bytes[0] = 0x1b
			res.bytes[1] = u8(r)
			res.len = 2
			return res, true
		}
	}

	// 2. Control Combinations (C0 codes: 0x01 - 0x1A)
	if is_ctrl && !is_alt {
		if key >= sdl3.K_A && key <= sdl3.K_Z {
			res.bytes[0] = u8(key - sdl3.K_A + 1)
			res.len = 1
			return res, true
		}
		switch key {
		case sdl3.K_SPACE:
			res.bytes[0] = 0x00 // NUL
			res.len = 1
			return res, true
		case sdl3.K_LEFTBRACKET:
			res.bytes[0] = 0x1b // ESC
			res.len = 1
			return res, true
		case sdl3.K_BACKSLASH:
			res.bytes[0] = 0x1c // FS
			res.len = 1
			return res, true
		case sdl3.K_RIGHTBRACKET:
			res.bytes[0] = 0x1d // GS
			res.len = 1
			return res, true
		}
	}

	// 3. Arrow Keys with xterm modifiers
	// Mod parameter: 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0)
	xterm_mod := 1 + (1 if is_shift else 0) + (2 if is_alt else 0) + (4 if is_ctrl else 0)
	arrow_suffix: u8 = 0
	switch key {
	case sdl3.K_UP:    arrow_suffix = 'A'
	case sdl3.K_DOWN:  arrow_suffix = 'B'
	case sdl3.K_RIGHT: arrow_suffix = 'C'
	case sdl3.K_LEFT:  arrow_suffix = 'D'
	}

	if arrow_suffix != 0 {
		if xterm_mod > 1 {
			s := fmt.bprintf(res.bytes[:], "\x1b[1;%d%c", xterm_mod, arrow_suffix)
			res.len = len(s)
		} else if app_cursor {
			res.bytes[0] = 0x1b
			res.bytes[1] = 'O'
			res.bytes[2] = arrow_suffix
			res.len = 3
		} else {
			res.bytes[0] = 0x1b
			res.bytes[1] = '['
			res.bytes[2] = arrow_suffix
			res.len = 3
		}
		return res, true
	}

	// 4. Standard Special Keys
	switch key {
	case sdl3.K_RETURN, sdl3.K_KP_ENTER:
		res.bytes[0] = '\r'
		res.len = 1
		return res, true
	case sdl3.K_BACKSPACE:
		res.bytes[0] = 0x7f
		res.len = 1
		return res, true
	case sdl3.K_TAB:
		if is_shift {
			// Back-tab
			res.bytes[0] = 0x1b
			res.bytes[1] = '['
			res.bytes[2] = 'Z'
			res.len = 3
		} else {
			res.bytes[0] = '\t'
			res.len = 1
		}
		return res, true
	case sdl3.K_ESCAPE:
		res.bytes[0] = 0x1b
		res.len = 1
		return res, true
	case sdl3.K_HOME:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = 'H'; res.len = 3
		return res, true
	case sdl3.K_END:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = 'F'; res.len = 3
		return res, true
	case sdl3.K_INSERT:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = '2'; res.bytes[3] = '~'; res.len = 4
		return res, true
	case sdl3.K_DELETE:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = '3'; res.bytes[3] = '~'; res.len = 4
		return res, true
	case sdl3.K_PAGEUP:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = '5'; res.bytes[3] = '~'; res.len = 4
		return res, true
	case sdl3.K_PAGEDOWN:
		res.bytes[0] = 0x1b; res.bytes[1] = '['; res.bytes[2] = '6'; res.bytes[3] = '~'; res.len = 4
		return res, true
	}

	// 5. Function Keys F1 - F12
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

package terminal_parser

import "core:fmt"
import grid "../grid"

// ISO-2022 character set designation and the DEC Special Graphics (ACS) table.
//
// ncurses/dialog/tmux draw boxes by switching G0 to `ESC ( 0` and emitting ASCII
// letters (`lqqqk` -> "┌───┐"). Ignoring the designator rendered those boxes as
// literal text, so the mapping lives here and is applied only while a graphics
// set is actually mapped onto GL.

// DEC Special Graphics for 0x5F..0x7E (unmapped bytes pass through unchanged).
@(rodata)
DEC_SPECIAL_GRAPHICS := [32]rune{
	0x00A0, // _ blank
	0x25C6, // ` diamond
	0x2592, // a checker board
	0x2409, // b HT
	0x240C, // c FF
	0x240D, // d CR
	0x240A, // e LF
	0x00B0, // f degree
	0x00B1, // g plus/minus
	0x2424, // h NL
	0x240B, // i VT
	0x2518, // j lower right corner
	0x2510, // k upper right corner
	0x250C, // l upper left corner
	0x2514, // m lower left corner
	0x253C, // n crossing lines
	0x23BA, // o horizontal line scan 1
	0x23BB, // p horizontal line scan 3
	0x2500, // q horizontal line scan 5
	0x23BC, // r horizontal line scan 7
	0x23BD, // s horizontal line scan 9
	0x251C, // t left tee
	0x2524, // u right tee
	0x2534, // v bottom tee
	0x252C, // w top tee
	0x2502, // x vertical line
	0x2264, // y less than or equal
	0x2265, // z greater than or equal
	0x03C0, // { pi
	0x2260, // | not equal
	0x00A3, // } pound sterling
	0x00B7, // ~ middle dot
}

// ISO-2022 designator bytes we model. 'B' is US-ASCII, '0' DEC Special
// Graphics, 'A' UK, 'U' Null (swallowed).
CHARSET_ASCII    :: u8('B')
CHARSET_DEC_ACS  :: u8('0')
CHARSET_UK       :: u8('A')
CHARSET_NULL     :: u8('U')

// _charset_map_byte translates a GL byte through the given ISO-2022 designator.
_charset_map_byte :: proc(designator: u8, b: u8) -> (rune, bool) {
	switch designator {
	case CHARSET_DEC_ACS:
		if b >= 0x5F && b <= 0x7E do return DEC_SPECIAL_GRAPHICS[b - 0x5F], true
		return rune(b), false
	case CHARSET_UK:
		if b == 0x23 do return 0x00A3, true // '#' -> pound sterling
		return rune(b), false
	case CHARSET_NULL:
		return 0, true
	}
	return rune(b), false
}

// _parser_map_gl_byte applies the currently mapped G-set (and any one-shot
// SS2/SS3 override) to an ASCII printable byte.
_parser_map_gl_byte :: proc(p: ^Parser, b: u8) -> (rune, bool) {
	if p == nil do return rune(b), false
	slot := int(p.gl)
	one_shot := p.gl_single
	if one_shot > 0 {
		slot = int(one_shot)
		p.gl_single = 0
	}
	if slot < 0 || slot > 3 do return rune(b), false
	return _charset_map_byte(p.charsets[slot], b)
}

// _parser_graphics_active reports whether GL currently needs translation at all.
_parser_graphics_active :: proc(p: ^Parser) -> bool {
	if p == nil do return false
	if p.gl_single > 0 do return true
	return p.charsets[int(p.gl)] != CHARSET_ASCII
}

// _parser_next_tab_stop returns the next programmed tab stop after `from`,
// falling back to the last column when none is set.
_parser_next_tab_stop :: proc(p: ^Parser, cols: int, from: int) -> int {
	if p == nil || cols <= 0 do return 0
	limit := min(cols, len(p.tab_stops))
	for c in (from + 1)..<limit {
		if p.tab_stops[c] do return c
	}
	return cols - 1
}

// _parser_soft_reset implements DECSTR (CSI ! p): return to the power-on state
// without touching the screen buffers or the alternate screen.
_parser_soft_reset :: proc(p: ^Parser, g: ^grid.Grid) {
	if p == nil do return
	p.cursor.row = 0
	p.cursor.col = 0
	p.cursor.pending_wrap = false
	p.cursor.visible = true
	p.cursor.shape = .Block
	p.cursor.blinking = true
	p.cursor.active_fg = 7
	p.cursor.active_bg = 0
	p.cursor.active_style = {}
	p.cursor.active_flags = {}
	p.cursor.direct_color = {}
	p.scroll_top = 0
	if g != nil do p.scroll_bottom = max(0, g.row_count - 1)
	p.cursor_key_mode = false
	p.keypad_app = false
	p.origin_mode = false
	p.autowrap = true
	p.bracketed_paste = false
	p.alternate_scroll_mode = false
	p.mouse_mode = .None
	p.mouse_format = .X10
	p.report_focus = false
	p.cursor.saved_row = 0
	p.cursor.saved_col = 0
}

// _parser_report_mode answers DECRQM/DECRQM-ANSI with the current mode state:
// 1 = set, 2 = reset, 0 = not recognised.
_parser_report_mode :: proc(p: ^Parser, mode: int) {
	if p == nil do return
	state := -1
	if p.csi_prefix == '?' {
		switch mode {
		case 1: state = p.cursor_key_mode ? 1 : 2
		case 6: state = p.origin_mode ? 1 : 2
		case 7: state = p.autowrap ? 1 : 2
		case 25: state = p.cursor.visible ? 1 : 2
		case 47, 1047, 1049: state = p.in_alt_screen ? 1 : 2
		case 1000, 1002, 1003:
			enabled := p.mouse_mode != .None
			if mode == 1002 do enabled = p.mouse_mode == .Button_Event
			if mode == 1003 do enabled = p.mouse_mode == .Any_Event
			if mode == 1000 do enabled = p.mouse_mode == .Normal || p.mouse_mode == .X10
			state = enabled ? 1 : 2
		case 1004: state = p.report_focus ? 1 : 2
		case 1006: state = p.mouse_format == .Sgr ? 1 : 2
		case 1007: state = p.alternate_scroll_mode ? 1 : 2
		case 1016: state = p.mouse_format == .Sgr_Pixel ? 1 : 2
		case 2004: state = p.bracketed_paste ? 1 : 2
		case 2026: state = p.sync_output ? 1 : 2
		}
	} else {
		switch mode {
		case 4: state = 1 // IRM is not modelled; report permanently reset
		case 20: state = 2
		}
	}
	if state < 0 do state = 0

	prefix := p.csi_prefix
	buf: [32]u8
	resp := fmt.bprintf(
		buf[:],
		"\x1b[%s%d;%d$y",
		prefix == '?' ? "?" : "",
		mode,
		state,
	)
	parser_emit_response(p, transmute([]u8)resp)
}

// --- Kitty keyboard protocol flag stack -------------------------------------
//
// Clients progressively enable enhancements with CSI > flags u, then unwind with
// CSI < n u when an application exits, so a nested editor never leaves the shell
// with keyboard flags it never asked for.

parser_kitty_keyboard_push :: proc(p: ^Parser, flags: u8) {
	if p == nil do return
	if int(p.kbd_depth) < len(p.kbd_flags) {
		p.kbd_flags[p.kbd_depth] = flags
		p.kbd_depth += 1
	} else {
		p.kbd_flags[len(p.kbd_flags) - 1] = flags
	}
}

parser_kitty_keyboard_pop :: proc(p: ^Parser, count: int) {
	if p == nil do return
	for _ in 0..<count {
		if p.kbd_depth == 0 do break
		p.kbd_depth -= 1
	}
	if p.kbd_depth == 0 do p.kbd_flags[0] = 0
}

parser_kitty_keyboard_set :: proc(p: ^Parser, flags: u8, mode: int) {
	if p == nil do return
	current := parser_kitty_keyboard_flags(p)
	switch mode {
	case 2: current |= flags
	case 3: current &= ~flags
	case:   current = flags
	}
	if p.kbd_depth == 0 {
		p.kbd_flags[0] = current
		p.kbd_depth = 1
	} else {
		p.kbd_flags[p.kbd_depth - 1] = current
	}
}

parser_kitty_keyboard_flags :: proc(p: ^Parser) -> u8 {
	if p == nil || p.kbd_depth == 0 do return 0
	return p.kbd_flags[p.kbd_depth - 1]
}

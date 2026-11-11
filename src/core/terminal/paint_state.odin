package core_terminal

import parser "parser"

// _paint_state restores everything but the cells, after the cells are written
// (painting needs autowrap on, no margins and ASCII charsets). Order matters:
// DECSTBM and DECOM home the cursor, so the cursor goes last but one; charsets
// come after the last printed glyph.
_paint_state :: proc(t: ^Terminal, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	p := &t.parser
	_paint_tab_stops(t, out)
	_paint_surface_vt(t, &t.grid, p, out, pen)
	if !p.in_alt_screen && p.prompt_state == .Prompt {
		_paint_str(out, "\x1b]133;P\x07")
	}
	_paint_set_pen(t, out, pen, _paint_vt_pen(t, p))
	_paint_input_modes(p, out)
	_paint_cursor_style(p, out)
	_paint_charsets(p, out)
	if t.title_len > 0 {
		_paint_str(out, "\x1b]2;")
		append(out, ..t.title_buf[:t.title_len])
		_paint_str(out, "\x1b\\")
	}
}

_paint_tab_stops :: proc(t: ^Terminal, out: ^[dynamic]u8) {
	p := &t.parser
	is_default := true
	for stop, i in p.tab_stops {
		if stop != (i % 8 == 0) {
			is_default = false
			break
		}
	}
	if is_default do return
	_paint_str(out, "\x1b[3g")
	for stop, i in p.tab_stops {
		if !stop || i >= t.cols do continue
		_paint_cup(out, 1, i + 1)
		_paint_str(out, "\x1bH")
	}
}

@(rodata)
MOUSE_MODE_NUMBERS := [parser.Mouse_Tracking_Mode]int {
	.None         = 0,
	.X10          = 9,
	.Normal       = 1000,
	.Button_Event = 1002,
	.Any_Event    = 1003,
}

@(rodata)
MOUSE_FORMAT_NUMBERS := [parser.Mouse_Format]int {
	.X10       = 0,
	.Sgr       = 1006,
	.Sgr_Pixel = 1016,
}

// _paint_input_modes restores the modes that change what the viewer sends back.
// The preamble switched all of them off, so only the active ones are written.
_paint_input_modes :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	if p.cursor_key_mode do _paint_dec_mode(out, 1, true)
	if p.keypad_app do _paint_str(out, "\x1b=")
	if p.bracketed_paste do _paint_dec_mode(out, 2004, true)
	if p.report_focus do _paint_dec_mode(out, 1004, true)
	if p.alternate_scroll_mode do _paint_dec_mode(out, 1007, true)
	if p.mouse_mode != .None do _paint_dec_mode(out, MOUSE_MODE_NUMBERS[p.mouse_mode], true)
	if p.mouse_format != .X10 do _paint_dec_mode(out, MOUSE_FORMAT_NUMBERS[p.mouse_format], true)
	for i in 0 ..< int(p.kbd_depth) do _paint_csi_int(out, ">", int(p.kbd_flags[i]), "u")
}

_paint_cursor_style :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	code: int
	switch p.cursor.shape {
	case .Block:     code = 1
	case .Underline: code = 3
	case .Beam:      code = 5
	}
	if !p.cursor.blinking do code += 1
	_paint_csi_int(out, "", code, " q")
	if !p.cursor.visible do _paint_dec_mode(out, 25, false)
}

@(rodata)
CHARSET_SLOT_INTRODUCERS := [4]u8{'(', ')', '*', '+'}

_paint_charsets :: proc(p: ^parser.Parser, out: ^[dynamic]u8) {
	for set, slot in p.charsets {
		if set == parser.CHARSET_ASCII do continue
		append(out, u8(0x1b), CHARSET_SLOT_INTRODUCERS[slot], set)
	}
	switch p.gl {
	case 1: _paint_str(out, "\x0e")
	case 2: _paint_str(out, "\x1bn")
	case 3: _paint_str(out, "\x1bo")
	}
	switch p.gl_single {
	case 2: _paint_str(out, "\x1bN")
	case 3: _paint_str(out, "\x1bO")
	}
}

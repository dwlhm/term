package core_terminal

import cell "cell"
import egc "egc"
import grid "grid"

// PAINT_PREAMBLE resets whatever state the receiving terminal is in: CAN aborts
// a half-received sequence, DECSTR resets the pen/margins/modes, and the rest
// switches off what DECSTR leaves alone (mouse, focus, paste, sync, keyboard
// flags, alternate screen, charsets, hyperlink, kitty images, keypad).
PAINT_PREAMBLE ::
	"\x18\x1b[!p" +
	"\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1016l\x1b[?1007l" +
	"\x1b[?1004l\x1b[?2004l\x1b[?2026l\x1b[<16u\x1b[?1049l\x1b>" +
	"\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b]8;;\x1b\\\x1b_Ga=d,d=A,q=2\x1b\\" +
	"\x1b[H\x1b[2J"

// terminal_paint serializes `t` as VT bytes that rebuild it in a fresh
// Terminal of the same size: up to `history` scrollback lines (main screen
// only), the main screen, the alternate screen when active, kitty images
// visible on the active screen, then modes, cursor and title. `out` is cleared
// and only grows; the caller reuses it across paints.
terminal_paint :: proc(t: ^Terminal, out: ^[dynamic]u8, history: int) {
	if t == nil || out == nil do return
	clear(out)
	_paint_str(out, PAINT_PREAMBLE)

	pen := PAINT_PEN_DEFAULT
	alt := t.parser.in_alt_screen
	main_grid := &t.alt_grid if alt else &t.grid
	h := clamp(history, 0, main_grid.history_count)
	_paint_lines(t, main_grid, -h, main_grid.row_count, out, &pen)
	if alt {
		_paint_set_pen(t, out, &pen, PAINT_PEN_DEFAULT)
		_paint_str(out, "\x1b[?1049h\x1b[H")
		_paint_lines(t, &t.grid, 0, t.grid.row_count, out, &pen)
	}
	_paint_kitty(t, out)
	_paint_state(t, out, &pen)
}

// _paint_lines writes logical rows [from, to) as one continuous text stream so
// that rows above the screen scroll into the receiver's history and soft-wrapped
// rows are rebuilt by autowrap (keeping their wrap flag for reflow).
_paint_lines :: proc(t: ^Terminal, g: ^grid.Grid, from, to: int, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	prev_wrapped := false
	for r in from ..< to {
		row := grid.grid_get_row(g, r)
		if row == nil do continue
		last := r == to - 1
		wrapped := row.wrap && !last
		end := len(row.cells) if wrapped else _paint_row_end(row)
		// A wrapped predecessor only records its wrap flag once a cell follows.
		if prev_wrapped do end = max(end, 1)
		for c in 0 ..< end do _paint_cell(t, row, c, out, pen)
		prev_wrapped = wrapped
		if last || wrapped do continue
		// LF erases with the current background (BCE): reset the pen first.
		if pen.bg != 0 || pen.dc.has_bg do _paint_set_pen(t, out, pen, Paint_Pen{fg = 7, link = pen.link})
		_paint_str(out, "\r\n")
	}
}

// _paint_row_end returns the column after the last cell that differs from a
// cleared cell; trailing blanks need not be sent.
_paint_row_end :: proc(row: ^grid.Row) -> int {
	end := len(row.cells)
	for end > 0 {
		c := row.cells[end - 1]
		if c != cell.CELL_DEFAULT do break
		if end - 1 < len(row.direct_colors) && row.direct_colors[end - 1] != {} do break
		end -= 1
	}
	return end
}

_paint_cell :: proc(t: ^Terminal, row: ^grid.Row, c: int, out: ^[dynamic]u8, pen: ^Paint_Pen) {
	sc := row.cells[c]
	if .Wide_Continuation in sc.flags do return
	dc := row.direct_colors[c] if c < len(row.direct_colors) else cell.Direct_Color{}
	_paint_set_pen(t, out, pen, _paint_pen_of_cell(sc, dc))
	_paint_glyph(t, sc, out)
}

_paint_glyph :: proc(t: ^Terminal, sc: cell.Semantic_Cell, out: ^[dynamic]u8) {
	if .Has_Egc in sc.flags {
		runes := egc.egc_pool_get(&t.egc_pool, int(sc.char - egc.EGC_INDEX_BASE))
		if len(runes) > 0 {
			for r in runes do _paint_rune(out, r)
			return
		}
	}
	_paint_rune(out, sc.char if sc.char >= 0x20 && sc.char < egc.EGC_INDEX_BASE else ' ')
}

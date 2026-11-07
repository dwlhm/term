package feature_automation

// Panels and dialogs: rectangles drawn with box-drawing characters. A title
// sits on the top edge, a footer on the bottom one. A rectangle may be partly
// covered by a dialog drawn over it (lazygit's popups); a dialog is a panel
// drawn over others, or a box whose background differs from what surrounds it.

import "core:strings"

@(private = "file")
_TL :: "┌╭╔┏┍┎╒╓"
@(private = "file")
_TR :: "┐╮╗┓┑┒╕╖"
@(private = "file")
_BL :: "└╰╚┗┕┖╘╙"
@(private = "file")
_BR :: "┘╯╝┛┙┚╛╜"
@(private = "file")
_H :: "─━═╌╍┄┅┈┉╴╶╸╺┬┴┳┻╤╧┼"
@(private = "file")
_V :: "│┃║╎╏┆┇┊┋├┤┠┨╟╢┣┫╞╡┼"

is_box_char :: proc(ch: rune) -> bool {
	return ch >= 0x2500 && ch <= 0x257F
}

@(private = "file")
_in :: proc(set: string, ch: rune) -> bool { return strings.contains_rune(set, ch) }

// infer_panels appends panels and dialogs; complete ones first.
infer_panels :: proc(s: ^Screen, out: ^[dynamic]Element) {
	start := len(out)
	for r in 0 ..< s.rows do for c in 0 ..< s.cols {
		if _in(_TL, screen_ch(s, r, c)) {
			if e, ok := _panel_at(s, r, c, nil); ok do append(out, e)
		}
	}
	complete := len(out)
	for r in 0 ..< s.rows do for c in 0 ..< s.cols {
		if !_in(_TL, screen_ch(s, r, c)) do continue
		if e, ok := _panel_at(s, r, c, out[start:complete]); ok && !_has_box(out[start:], e.box) {
			// it is covered: whatever covers it is a dialog
			for &d in out[start:complete] do if _covers(d.box, e.box) do d.role = .Dialog
			append(out, e)
		}
	}
	for &e in out[start:complete] do if e.role == .Panel && _stands_out(s, e.box) do e.role = .Dialog
	_columns(s, out, start)
	for &e, i in out[start:] do e.parent = _innermost(out[start:], i, start)
}

// _panel_at reads the rectangle whose top-left corner is (r, c). Border cells
// may be anything inside one of covers (nil: the border must be whole).
@(private = "file")
_panel_at :: proc(s: ^Screen, r, c: int, covers: []Element) -> (e: Element, ok: bool) {
	right, lines := -1, 0
	for x in c + 1 ..< s.cols {
		ch := screen_ch(s, r, x)
		if _in(_TR, ch) {
			right = x
			break
		}
		if _in(_H, ch) do lines += 1
		else if _in(_V, ch) || _in(_TL, ch) || _in(_BL, ch) || _in(_BR, ch) do return
	}
	if right < 0 || lines < 2 do return
	bottom := -1
	for y in r + 1 ..< s.rows {
		ch := screen_ch(s, y, c)
		if _in(_BL, ch) {
			bottom = y
			break
		}
		if !_in(_V, ch) do return
	}
	if bottom < 0 do return
	for y in r + 1 ..< bottom do if !_border(s, y, right, _V, covers) do return
	if !_border(s, bottom, right, _BR, covers) do return
	for x in c + 1 ..< right {
		ch := screen_ch(s, bottom, x)
		if !_in(_H, ch) && is_box_char(ch) && !_covered(covers, bottom, x) do return
	}
	box := Box{r, c, right - c + 1, bottom - r + 1}
	return {role = .Panel, name = _edge_label(s, r, c, right, covers), text = _edge_label(s, bottom, c, right, covers), box = box, parent = -1}, true
}

@(private = "file")
_border :: proc(s: ^Screen, row, col: int, set: string, covers: []Element) -> bool {
	return _in(set, screen_ch(s, row, col)) || _covered(covers, row, col)
}

@(private = "file")
_covered :: proc(covers: []Element, row, col: int) -> bool {
	for d in covers do if box_has(d.box, row, col) do return true
	return false
}

// _edge_label: the text on an edge between its corners, line runs as spaces.
@(private = "file")
_edge_label :: proc(s: ^Screen, row, c0, c1: int, covers: []Element) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x in c0 + 1 ..< c1 {
		cell := screen_cell(s, row, x)
		if cell.cont || _covered(covers, row, x) do continue
		strings.write_rune(&b, ' ' if _in(_H, cell.ch) else cell.ch)
	}
	return strings.clone(_squash(strings.to_string(b)))
}

// _squash trims and collapses runs of spaces.
_squash :: proc(text: string) -> string {
	fields := strings.fields(text, context.temp_allocator)
	return strings.join(fields, " ", context.temp_allocator)
}

@(private = "file")
_has_box :: proc(es: []Element, b: Box) -> bool {
	for e in es do if e.box == b do return true
	return false
}

// _covers: d is drawn over part of b's border (it overlaps without containing it).
@(private = "file")
_covers :: proc(d, b: Box) -> bool {
	overlap := d.row < b.row + b.height && b.row < d.row + d.height && d.col < b.col + b.width && b.col < d.col + d.width
	return overlap && !box_contains(d, b) && !box_contains(b, d)
}

// _stands_out: a box away from the screen edges whose background differs from
// the background around it (a dialog over a coloured screen).
@(private = "file")
_stands_out :: proc(s: ^Screen, b: Box) -> bool {
	if b.row == 0 || b.col == 0 || b.row + b.height >= s.rows || b.col + b.width >= s.cols do return false
	inner := dominant_bg(s, {b.row + 1, b.col + 1, max(1, b.width - 2), max(1, b.height - 2)})
	outer := dominant_bg(s, {b.row - 1, b.col, b.width, 1})
	return inner != outer
}

// _innermost: the smallest other panel or dialog that contains es[i].
@(private = "file")
_innermost :: proc(es: []Element, i, base: int) -> int {
	best, area := -1, max(int)
	for e, j in es {
		if j == i || !box_contains(e.box, es[i].box) || e.box == es[i].box do continue
		if a := e.box.width * e.box.height; a < area do best, area = base + j, a
	}
	return best
}

// _columns: panes split by full-height vertical lines without corners (file
// managers). Each pane between two lines, or a line and the screen edge, is a
// panel; only lines outside every box count.
@(private = "file")
_columns :: proc(s: ^Screen, out: ^[dynamic]Element, start: int) {
	if s.rows < 6 do return
	lines: [dynamic]int
	lines.allocator = context.temp_allocator
	for c in 1 ..< s.cols - 1 {
		top, bottom, ok := _vertical_line(s, out[start:], c)
		if ok && (len(lines) == 0 || lines[len(lines) - 1] != c - 1) do append(&lines, c)
		_ = top
		_ = bottom
	}
	if len(lines) == 0 do return
	top, bottom, _ := _vertical_line(s, out[start:], lines[0])
	edges := make([dynamic]int, 0, len(lines) + 2, context.temp_allocator)
	append(&edges, -1)
	append(&edges, ..lines[:])
	append(&edges, s.cols)
	for i in 0 ..< len(edges) - 1 {
		left, right := edges[i] + 1, edges[i + 1]
		if right - left < 3 do continue
		// a pane is its inner area: the box pads it by one on each side
		// a pane's box pads its cells by one on each side, inside the screen
		l, t := max(left - 1, 0), max(top - 1, 0)
		append(out, Element{role = .Panel, box = {t, l, min(right + 1, s.cols) - l, min(bottom + 2, s.rows) - t}, parent = -1})
	}
}

// _vertical_line: column c holds vertical line characters on at least 80% of
// the rows between the first and the last, in one run, outside every box.
@(private = "file")
_vertical_line :: proc(s: ^Screen, boxes: []Element, c: int) -> (top, bottom: int, ok: bool) {
	top, bottom = -1, -1
	for r in 0 ..< s.rows {
		if !_in(_V, screen_ch(s, r, c)) || _covered(boxes, r, c) do continue
		if top < 0 do top = r
		bottom = r
	}
	if top < 0 do return
	run := 0
	for r in top ..= bottom do if _in(_V, screen_ch(s, r, c)) do run += 1
	ok = run == bottom - top + 1 && run * 10 >= (s.rows - 2) * 8
	return
}

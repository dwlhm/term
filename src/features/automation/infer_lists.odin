package feature_automation

// Lists: a highlighted row (its background differs from its container's over
// at least half the width) is the selected item; the rows aligned with it are
// its siblings. A pointer column (> apple / ❯ item) marks the selected item of
// rows that otherwise start at the same column.

import "core:strings"

@(private = "file")
_POINTERS :: ">❯▶➜→▸●*"

infer_lists :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int) {
	found: [dynamic]Lit_Row
	found.allocator = context.temp_allocator
	for r in 0 ..< s.rows {
		if lit, ok := _highlighted_row(s, out, panels, r); ok do append(&found, lit)
	}
	// One selection per list: rows sharing a highlight in one container are a
	// styled region (a header, a card), not a selected item.
	for e in found {
		same := 0
		for f in found do if f.item.parent == e.item.parent && f.bg == e.bg do same += 1
		if same == 1 && e.item_ok do _list_around(s, out, panels, e.item)
	}
	_pointer_lists(s, out, panels)
}

// Lit_Row: a row highlighted over half its container; item_ok when its text
// can be a list item (no box drawing: a box's own row is no item).
@(private = "file")
Lit_Row :: struct {
	item:    Element,
	bg:      u32,
	item_ok: bool,
}

@(private = "file")
_highlighted_row :: proc(s: ^Screen, out: ^[dynamic]Element, panels, r: int) -> (lit_row: Lit_Row, ok: bool) {
	idx, inner := container(s, out[:panels], r, s.cols / 2)
	if r < inner.row || r >= inner.row + inner.height || inner.width < 6 do return
	if idx < 0 && (r == 0 || r == s.rows - 1) do return // a status bar's
	around := dominant_bg(s, inner)
	lit := 0
	first, last := -1, -1
	for c in inner.col ..< inner.col + inner.width {
		// cells of a panel inside the container are that panel's, not a highlight
		if bg_key(screen_cell(s, r, c).style) == around || _in_child(out[:panels], idx, r, c) do continue
		lit += 1
		if first < 0 do first = c
		last = c
	}
	if lit * 2 < inner.width || _row_taken(out[panels:], r) do return
	text := screen_text(s, r, first, last + 1)
	name := _item_name(text)
	item := Element{role = .Listitem, name = name, box = {r, first, last - first + 1, 1}, parent = idx, selected = true}
	return {item, dominant_bg(s, item.box), len(name) > 0 && !_has_box_char(text)}, true
}

// _list_around adds sel and the aligned non-empty rows above and below it in
// the same container.
@(private = "file")
_list_around :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int, sel: Element) {
	_, inner := container(s, out[:panels], sel.box.row, sel.box.col)
	indent := _indent(s, sel.box.row, inner)
	for dir in ([2]int{-1, 1}) {
		for r := sel.box.row + dir; r >= inner.row && r < inner.row + inner.height; r += dir {
			if abs(_indent(s, r, inner) - indent) > 1 || _row_taken(out[panels:], r) do break // a selection may shift by one
			text := screen_text(s, r, inner.col, inner.col + inner.width)
			name := _item_name(text)
			if len(name) == 0 || _has_box_char(text) do break
			append(out, Element{role = .Listitem, name = name, box = {r, sel.box.col, sel.box.width, 1}, parent = sel.parent})
		}
	}
	append(out, sel)
}

// _pointer_lists: runs of rows in a container where exactly one starts with a
// pointer and the rest are blank in its place.
@(private = "file")
_pointer_lists :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int) {
	for r in 0 ..< s.rows {
		_, inner := container(s, out[:panels], r, 0)
		c := inner.col + _indent(s, r, inner)
		if !strings.contains_rune(_POINTERS, screen_ch(s, r, c)) || screen_ch(s, r, c + 1) != ' ' || screen_ch(s, r, c + 2) == ' ' || _row_taken(out[panels:], r) do continue
		top, bottom := r, r
		for top - 1 >= inner.row && _aligned_blank(s, top - 1, c) do top -= 1
		for bottom + 1 < inner.row + inner.height && _aligned_blank(s, bottom + 1, c) do bottom += 1
		if top == bottom do continue
		idx, _ := container(s, out[:panels], r, c)
		for y in top ..= bottom {
			name := _item_name(screen_text(s, y, c, inner.col + inner.width))
			append(out, Element{role = .Listitem, name = name, box = {y, c, inner.col + inner.width - c, 1}, parent = idx, selected = y == r})
		}
	}
}

// _aligned_blank: a sibling row of a pointer list: blank at the pointer and
// its space, text right after.
@(private = "file")
_aligned_blank :: proc(s: ^Screen, r, c: int) -> bool {
	return screen_ch(s, r, c) == ' ' && screen_ch(s, r, c + 1) == ' ' && screen_ch(s, r, c + 2) != ' '
}

@(private = "file")
_indent :: proc(s: ^Screen, r: int, inner: Box) -> int {
	for c in inner.col ..< inner.col + inner.width do if screen_ch(s, r, c) != ' ' do return c - inner.col
	return -1
}

// _item_name: a row's text without the gutter or pointer it starts with.
@(private = "file")
_item_name :: proc(text: string) -> string {
	t := strings.trim_space(text)
	t = strings.trim_left(t, "▌▐│┃>❯▶➜→▸● ")
	return strings.clone(_squash(t))
}

@(private = "file")
_row_taken :: proc(es: []Element, r: int) -> bool {
	for e in es do if e.box.height == 1 && e.box.row == r && e.role != .Button do return true
	return false
}

// _in_child: (r, c) lies in a panel other than the container idx.
@(private = "file")
_in_child :: proc(panels: []Element, idx, r, c: int) -> bool {
	for e, i in panels do if i != idx && box_has(e.box, r, c) && (idx < 0 || box_contains(panels[idx].box, e.box)) do return true
	return false
}

@(private = "file")
_has_box_char :: proc(text: string) -> bool {
	for ch in text do if is_box_char(ch) || (ch >= 0x2580 && ch <= 0x259F) do return true
	return false
}

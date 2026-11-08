package feature_screen_model

// Bars and the field being typed in: a status bar is a top or bottom row on
// its own background; a scrollbar is a right-hand column of block characters;
// the cursor marks the input of a one-line box or of an inline prompt.

import "core:strings"

@(private = "file")
_SCROLL_CHARS :: "█▇▆▅▄▃▂▁▐▌┃║░▒▓▕▏"

infer_bars :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int) {
	screen_bg := dominant_bg(s, {0, 0, s.cols, s.rows})
	for r in ([2]int{0, s.rows - 1}) {
		lit := 0
		for c in 0 ..< s.cols do if bg_key(screen_cell(s, r, c).style) != screen_bg do lit += 1
		name := _squash(screen_text(s, r, 0, s.cols))
		if lit * 10 >= s.cols * 6 && strings.contains_any(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") {
			append(out, Element{role = .Statusbar, name = strings.clone(name), box = {r, 0, s.cols, 1}, parent = -1})
		}
	}
	_scrollbar(s, out, -1, {0, 0, s.cols, s.rows})
	for i in 0 ..< panels {
		b := out[i].box
		_scrollbar(s, out, i, {b.row + 1, b.col + 1, b.width - 2, b.height - 2})
	}
}

// _scrollbar: the inner right column holds at least two block characters and
// nothing else but blanks.
@(private = "file")
_scrollbar :: proc(s: ^Screen, out: ^[dynamic]Element, parent: int, inner: Box) {
	if inner.width < 4 || inner.height < 3 do return
	c := inner.col + inner.width - 1
	blocks := 0
	for r in inner.row ..< inner.row + inner.height {
		ch := screen_ch(s, r, c)
		if strings.contains_rune(_SCROLL_CHARS, ch) do blocks += 1
		else if ch != ' ' do return
	}
	if blocks >= 2 do append(out, Element{role = .Scrollbar, box = {inner.row, c, 1, inner.height}, parent = parent})
}

// infer_cursor_input: a visible cursor in a one-line box makes that box an
// input; on a main-screen prompt that is not a shell's, its row is one.
infer_cursor_input :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int) {
	snap := &s.snap
	if !snap.cursor_visible || snap.prompt_state == .Prompt || snap.prompt_state == .Input do return
	r, c := int(snap.cursor_row), int(snap.cursor_col)
	for &e in out[:] {
		if !box_has(e.box, r, c) || e.role == .Dialog || (e.role == .Panel && e.box.height != 3) do continue
		if e.role == .Panel {
			e.role, e.text = .Input, strings.clone(strings.trim_space(screen_text(s, r, e.box.col + 1, e.box.col + e.box.width - 1)))
		}
		e.focused = true
		return
	}
	if snap.alt_screen do return
	idx, inner := container(s, out[:panels], r, c)
	append(out, Element{role = .Input, text = strings.clone(strings.trim_space(screen_text(s, r, c, inner.col + inner.width))), box = {r, inner.col, inner.width, 1}, parent = idx, focused = true})
}

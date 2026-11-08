package feature_screen_model

// Controls drawn as text: [x] / ( ) toggles, [____] fields, <OK> and [ OK ]
// buttons, and "pill" buttons (padded text on its own background, two or more
// in a row). Key hints like <enter> or <ctrl+o> are not buttons. A control is
// focused when its background differs from its container's.

import "core:strings"
import "core:unicode"

@(private = "file")
_CHECK_MARKS :: " xX*✓✔•"
@(private = "file")
_RADIO_MARKS :: " *•oO●xX"

infer_controls :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int) {
	for r in 0 ..< s.rows {
		c := 0
		for c < s.cols {
			if n := _control_at(s, out, panels, r, c); n > 0 do c += n
			else do c += 1
		}
		if r > 0 && r < s.rows - 1 do _pills(s, out, panels, r) // not a status line's segments
	}
}

// _control_at reads a bracketed control starting at (r, c); returns its width.
@(private = "file")
_control_at :: proc(s: ^Screen, out: ^[dynamic]Element, panels, r, c: int) -> int {
	open := screen_ch(s, r, c)
	if open != '[' && open != '(' && open != '<' do return 0
	close := ']' if open == '[' else (')' if open == '(' else '>')
	end := -1
	for x in c + 1 ..< min(s.cols, c + 26) {
		ch := screen_ch(s, r, x)
		if ch == close {
			end = x
			break
		}
		if ch == open || is_box_char(ch) do return 0
	}
	if end < 0 do return 0
	inner := screen_text(s, r, c + 1, end)
	e := Element{box = {r, c, end - c + 1, 1}, parent = -1}
	switch {
	case end == c + 2 && open == '[' && strings.contains_rune(_CHECK_MARKS, screen_ch(s, r, c + 1)):
		e.role, e.checked, e.name = .Checkbox, inner != " ", _label_after(s, out, panels, r, end + 1)
	case end == c + 2 && open == '(' && strings.contains_rune(_RADIO_MARKS, screen_ch(s, r, c + 1)):
		e.role, e.checked, e.name = .Radio, inner != " ", _label_after(s, out, panels, r, end + 1)
	case open == '[' && end - c >= 4 && strings.trim_right(inner, "_ ") == "" && strings.count(inner, "_") >= 3:
		e.role = .Input
	case open != '(' && _button_label(inner, open == '['):
		e.role, e.name = .Button, strings.clone(_squash(inner))
	case:
		return 0
	}
	idx, _ := container(s, out[:panels], r, c)
	e.parent = idx
	e.focused = _stands_out_in(s, out, panels, e.box)
	append(out, e)
	return end - c + 1
}

// _button_label: a short label that starts with a capital or is padded (a key
// hint like <enter>, <ctrl+o> or a number like [1] is not a button).
@(private = "file")
_button_label :: proc(inner: string, square: bool) -> bool {
	label := strings.trim_space(inner)
	if len(label) == 0 || strings.count(label, " ") > (1 if square else 2) do return false
	has_letter := false
	for ch in label do has_letter ||= unicode.is_letter(ch)
	if !has_letter do return false
	padded := strings.has_prefix(inner, " ") && strings.has_suffix(inner, " ")
	first := rune(label[0])
	return padded || (unicode.is_upper(first) && !strings.contains_any(label, "+:/"))
}

// _label_after: the text after a toggle, up to a wide gap, a border or the
// end of its container.
@(private = "file")
_label_after :: proc(s: ^Screen, out: ^[dynamic]Element, panels, r, from: int) -> string {
	_, inner := container(s, out[:panels], r, from)
	end := inner.col + inner.width
	start := from
	for start < end && screen_ch(s, r, start) == ' ' do start += 1
	stop := start
	for stop < end && !is_box_char(screen_ch(s, r, stop)) {
		if screen_ch(s, r, stop) == ' ' && screen_ch(s, r, stop + 1) == ' ' do break
		stop += 1
	}
	return strings.clone(_squash(screen_text(s, r, start, stop)))
}

// _stands_out_in: b's background differs from its container's.
@(private = "file")
_stands_out_in :: proc(s: ^Screen, out: ^[dynamic]Element, panels: int, b: Box) -> bool {
	_, inner := container(s, out[:panels], b.row, b.col)
	return dominant_bg(s, b) != dominant_bg(s, inner)
}

// _pills: two or more padded labels on their own backgrounds in one row are
// buttons; the one that stands out most is focused.
@(private = "file")
_pills :: proc(s: ^Screen, out: ^[dynamic]Element, panels, r: int) {
	start := len(out)
	c := 0
	for c < s.cols {
		_, inner := container(s, out[:panels], r, c)
		around := dominant_bg(s, inner)
		k := bg_key(screen_cell(s, r, c).style)
		end := c + 1
		for end < s.cols && bg_key(screen_cell(s, r, end).style) == k do end += 1
		text := screen_text(s, r, c, end)
		label := strings.trim_space(text)
		if k != around && end - c <= 24 && len(label) > 0 && strings.count(label, " ") <= 2 &&
		   strings.has_prefix(text, " ") && strings.has_suffix(text, " ") && !_taken(out[:], r, c, end) {
			idx, _ := container(s, out[:panels], r, c)
			append(out, Element{role = .Button, name = strings.clone(label), box = {r, c, end - c, 1}, parent = idx})
		}
		c = end
	}
	if len(out) - start < 2 {
		resize(out, start)
		return
	}
	best, contrast := -1, -1
	for e, i in out[start:] {
		_, inner := container(s, out[:panels], r, e.box.col)
		d := abs(luminance(dominant_bg(s, e.box)) - luminance(dominant_bg(s, inner)))
		if d > contrast do best, contrast = start + i, d
	}
	out[best].focused = true
}

@(private = "file")
_taken :: proc(es: []Element, r, c0, c1: int) -> bool {
	for e in es {
		if e.role == .Panel || e.role == .Dialog || e.box.height != 1 || e.box.row != r do continue
		if e.box.col < c1 && c0 < e.box.col + e.box.width do return true
	}
	return false
}

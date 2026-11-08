package feature_screen_model

// Marked elements: what programs say themselves. OSC 133 shell integration
// gives the prompt rows, the line being typed and the last command's output;
// OSC 8 gives links. Inference never overrides them.

import "core:strings"

marked :: proc(s: ^Screen, out: ^[dynamic]Element) {
	snap := &s.snap
	_prompt_rows(s, out)
	if snap.prompt_state == .Input || snap.prompt_state == .Prompt {
		r := int(snap.cursor_row)
		append(out, Element{role = .Input, text = strings.clone(strings.trim_space(screen_text(s, r, 0, s.cols))), box = {r, 0, s.cols, 1}, parent = -1, focused = snap.prompt_state == .Input, source = .Osc133})
	}
	if snap.output_start >= 0 {
		first := int(snap.output_start - snap.top_line)
		last := s.rows if snap.output_end < 0 else int(snap.output_end - snap.top_line)
		first, last = max(first, 0), min(last, s.rows)
		if last > first do append(out, Element{role = .Output, box = {first, 0, s.cols, last - first}, parent = -1, source = .Osc133})
	}
	_links(s, out)
}

// _prompt_rows: each run of rows drawn while the shell printed its prompt.
@(private = "file")
_prompt_rows :: proc(s: ^Screen, out: ^[dynamic]Element) {
	r := 0
	for r < s.rows {
		if r >= len(s.snap.screen) || !s.snap.screen[r].prompt {
			r += 1
			continue
		}
		top := r
		for r < s.rows && r < len(s.snap.screen) && s.snap.screen[r].prompt do r += 1
		parts := make([]string, r - top, context.temp_allocator)
		for y in top ..< r do parts[y - top] = screen_text(s, y, 0, s.cols)
		name := _squash(strings.join(parts, " ", context.temp_allocator))
		append(out, Element{role = .Prompt, name = strings.clone(name), box = {top, 0, s.cols, r - top}, parent = -1, source = .Osc133})
	}
}

// _links: each run of cells that carries one OSC 8 link.
@(private = "file")
_links :: proc(s: ^Screen, out: ^[dynamic]Element) {
	for r in 0 ..< s.rows {
		c := 0
		for c < s.cols {
			id := screen_cell(s, r, c).style.link
			if id == 0 {
				c += 1
				continue
			}
			end := c + 1
			for end < s.cols && screen_cell(s, r, end).style.link == id do end += 1
			uri := ""
			for l in s.snap.links do if l.id == id do uri = l.uri
			append(out, Element{role = .Link, name = strings.clone(strings.trim_space(screen_text(s, r, c, end))), text = strings.clone(uri), box = {r, c, end - c, 1}, parent = -1, source = .Osc8})
			c = end
		}
	}
}

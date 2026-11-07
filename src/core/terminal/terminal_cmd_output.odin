package core_terminal

// The output of the last shell command (OSC 133;C to 133;D) as plain text.
// Its start is a grid line (grid.scrolled + row), which scrolling keeps; a
// resize reflows rows, so the start is found again by the number of logical
// lines between it and the cursor, which reflow does not change.

import "core:strings"
import grid "grid"

// terminal_cmd_output appends the last command's output; while it still runs
// (or to_cursor), up to the cursor. head_lost: its first lines are gone.
terminal_cmd_output :: proc(t: ^Terminal, b: ^strings.Builder, to_cursor := false) -> (ok, head_lost: bool) {
	o := &t.parser.cmd_out
	if !o.started do return false, false
	g, cur_row, cur_col := _main_screen(t)
	from := int(o.start - g.scrolled)
	to := cur_row + (1 if cur_col > 0 else 0)
	if o.ended && !to_cursor do to = int(o.end - g.scrolled) + (1 if o.end_col > 0 else 0)
	head_lost = o.head_lost
	if from < -g.history_count {
		from, head_lost = -g.history_count, true
	}
	terminal_text_rows(t, g, b, from, clamp(to, from, g.row_count))
	return true, head_lost
}

// _main_screen is the main screen and its cursor; behind a full-screen
// program that is the hidden buffer and the cursor ?1049h saved.
@(private = "file")
_main_screen :: proc(t: ^Terminal) -> (g: ^grid.Grid, row, col: int) {
	if t.parser.in_alt_screen do return &t.alt_grid, t.parser.cursor.saved_row, t.parser.cursor.saved_col
	return &t.grid, t.parser.cursor.row, t.parser.cursor.col
}

// _cmd_output_lines counts the logical line ends between a running command's
// start and the cursor (-1: its start already left the scrollback).
@(private)
_cmd_output_lines :: proc(t: ^Terminal) -> int {
	o := &t.parser.cmd_out
	if !o.started || o.ended do return 0
	g, cur_row, _ := _main_screen(t)
	from := int(o.start - g.scrolled)
	if from < -g.history_count do return -1
	n := 0
	for r in from ..< cur_row {
		if row := grid.grid_get_row(g, r); row != nil && !row.wrap do n += 1
	}
	return n
}

// _cmd_output_relocate puts a running command's start back on its line after
// a reflow: `lines` logical lines above the cursor's line.
@(private)
_cmd_output_relocate :: proc(t: ^Terminal, lines: int) {
	o := &t.parser.cmd_out
	if !o.started || o.ended do return
	g, r, _ := _main_screen(t)
	top := g.scrolled - i64(g.history_count)
	if lines < 0 {
		o.start, o.head_lost = top, true
		return
	}
	for seen := 0; seen < lines; {
		r -= 1
		if r < -g.history_count {
			o.start, o.head_lost = top, true
			return
		}
		if row := grid.grid_get_row(g, r); row != nil && !row.wrap do seen += 1
	}
	for r > -g.history_count {
		prev := grid.grid_get_row(g, r - 1)
		if prev == nil || !prev.wrap do break
		r -= 1
	}
	o.start = g.scrolled + i64(r)
}

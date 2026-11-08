package feature_screen_model

// Screen: a snapshot laid out as cells (what inference reads) and row text
// with a byte offset per cell (what element names are cut from). Built once
// per snapshot, all in one allocator.

import "core:strings"
import "core:unicode/utf8"
import uw "../../core/unicode_width"
import proto "../session_proto"

Screen_Cell :: struct {
	ch:    rune, // first rune of the cell's cluster; ' ' for an empty cell
	cont:  bool, // the right half of a wide character
	style: proto.Snap_Style,
}

Screen :: struct {
	snap:  proto.Snapshot,
	cols:  int,
	rows:  int,
	cells: []Screen_Cell,  // rows × cols
	text:  []string,       // per row: its text, every cell padded with spaces
	off:   [][]int,        // per row: byte offset of each cell in text, and its end
}

screen_cell :: proc(s: ^Screen, row, col: int) -> ^Screen_Cell {
	if row < 0 || row >= s.rows || col < 0 || col >= s.cols do return nil
	return &s.cells[row * s.cols + col]
}

screen_ch :: proc(s: ^Screen, row, col: int) -> rune {
	c := screen_cell(s, row, col)
	return c.ch if c != nil else 0
}

// screen_text: the text of cells [c0, c1) of a row.
screen_text :: proc(s: ^Screen, row, c0, c1: int) -> string {
	if row < 0 || row >= s.rows do return ""
	a, b := clamp(c0, 0, s.cols), clamp(c1, 0, s.cols)
	if a >= b do return ""
	return s.text[row][s.off[row][a]:s.off[row][b]]
}

screen_build :: proc(snap: proto.Snapshot, allocator := context.allocator) -> (s: Screen) {
	context.allocator = allocator
	s.snap = snap
	s.cols, s.rows = int(snap.cols), int(snap.rows)
	s.cells = make([]Screen_Cell, s.cols * s.rows)
	for &c in s.cells do c = {ch = ' ', style = {fg = 7}}
	s.text = make([]string, s.rows)
	s.off = make([][]int, s.rows)
	for r in 0 ..< s.rows {
		row := snap.screen[r] if r < len(snap.screen) else {}
		s.text[r], s.off[r] = _layout_row(&s, r, row)
	}
	return
}

// _layout_row places a row's runs on cells, cluster by cluster, and builds its
// padded text.
@(private = "file")
_layout_row :: proc(s: ^Screen, r: int, row: proto.Snap_Row) -> (text: string, off: []int) {
	b := strings.builder_make()
	off = make([]int, s.cols + 1)
	col := 0
	for run in row.runs {
		end := min(col + int(run.cells), s.cols)
		rest := run.text
		for col < end && len(rest) > 0 {
			first, size, w := _next_cluster(rest)
			off[col] = len(b.buf)
			s.cells[r * s.cols + col] = {ch = first, style = run.style}
			strings.write_string(&b, rest[:size])
			if w == 2 && col + 1 < end {
				off[col + 1] = len(b.buf)
				s.cells[r * s.cols + col + 1] = {ch = first, cont = true, style = run.style}
			}
			col += w
			rest = rest[size:]
		}
		// cells the text did not fill (a mismatch) stay blank in the run's style
		for ; col < end; col += 1 {
			off[col] = len(b.buf)
			s.cells[r * s.cols + col] = {ch = ' ', style = run.style}
			strings.write_byte(&b, ' ')
		}
	}
	for ; col < s.cols; col += 1 {
		off[col] = len(b.buf)
		strings.write_byte(&b, ' ')
	}
	off[s.cols] = len(b.buf)
	return strings.to_string(b), off
}

// _next_cluster: the grapheme cluster text starts with, its byte size and
// cell width (1 or 2).
@(private = "file")
_next_cluster :: proc(text: string) -> (first: rune, size, width: int) {
	cluster: [dynamic]rune
	cluster.allocator = context.temp_allocator
	n: int
	first, n = utf8.decode_rune_in_string(text)
	append(&cluster, first)
	size = n
	for size < len(text) {
		next, m := utf8.decode_rune_in_string(text[size:])
		if !uw.should_extend(cluster[:], next) do break
		append(&cluster, next)
		size += m
	}
	return first, size, clamp(uw.cluster_width(cluster[:]), 1, 2)
}

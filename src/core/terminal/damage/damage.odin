package terminal_damage

import "base:runtime"

DIRTY_ROW_MAX_SPANS :: 4

Span :: struct {
	col_start: u16,
	col_end:   u16, // exclusive
}

Dirty_Row :: struct {
	generation: u32,
	span_count: u8,
	spans:      [DIRTY_ROW_MAX_SPANS]Span,
	full:       bool,
}

Damage_Journal :: struct {
	has_damage: bool,
	full_damage: bool,
	min_row:    int,
	max_row:    int,
	min_col:    int,
	max_col:    int,
	dirty_rows: []Dirty_Row,
}

Damage_Tracker :: struct {
	dirty_rows: []Dirty_Row,
	row_count:  int,
	col_count:  int,
	has_damage: bool,
	allocator:  runtime.Allocator,
}

damage_init :: proc(d: ^Damage_Tracker, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	if d == nil do return
	d.row_count = rows
	d.col_count = cols
	d.allocator = allocator
	d.has_damage = false
	d.dirty_rows = make([]Dirty_Row, rows, allocator)
	damage_mark_all(d, 1)
}

damage_destroy :: proc(d: ^Damage_Tracker) {
	if d == nil do return
	if len(d.dirty_rows) > 0 {
		delete(d.dirty_rows, d.allocator)
		d.dirty_rows = nil
	}
	d.row_count = 0
	d.col_count = 0
	d.has_damage = false
}

damage_reset :: proc(d: ^Damage_Tracker) {
	if d == nil do return
	for i in 0..<len(d.dirty_rows) {
		d.dirty_rows[i] = Dirty_Row{}
	}
	d.has_damage = false
}

damage_mark_cell :: proc(d: ^Damage_Tracker, row, col: int, generation: u32 = 0) {
	damage_mark_span(d, row, col, col + 1, generation)
}

damage_mark_span :: proc(d: ^Damage_Tracker, row, col_start, col_end: int, generation: u32 = 0) {
	if d == nil || row < 0 || row >= d.row_count do return
	c_start := max(0, col_start)
	c_end := min(d.col_count, col_end)
	if c_start >= c_end do return

	d.has_damage = true
	dr := &d.dirty_rows[row]
	dr.generation = generation

	if dr.full do return

	// If entire row covered
	if c_start == 0 && c_end == d.col_count {
		dr.full = true
		dr.span_count = 0
		return
	}

	// Try to merge with an existing adjacent/overlapping span
	for i in 0..<int(dr.span_count) {
		s := &dr.spans[i]
		if int(s.col_start) <= c_end && c_start <= int(s.col_end) {
			s.col_start = u16(min(int(s.col_start), c_start))
			s.col_end = u16(max(int(s.col_end), c_end))
			if s.col_start == 0 && int(s.col_end) == d.col_count {
				dr.full = true
				dr.span_count = 0
			}
			return
		}
	}

	// Add new span if under capacity
	if dr.span_count < DIRTY_ROW_MAX_SPANS {
		dr.spans[dr.span_count] = Span{
			col_start = u16(c_start),
			col_end   = u16(c_end),
		}
		dr.span_count += 1
	} else {
		// Degradation to full row on overflow
		dr.full = true
		dr.span_count = 0
	}
}

damage_mark_row :: proc(d: ^Damage_Tracker, row: int, generation: u32 = 0) {
	if d == nil || row < 0 || row >= d.row_count do return
	d.has_damage = true
	dr := &d.dirty_rows[row]
	dr.generation = generation
	dr.full = true
	dr.span_count = 0
}

damage_mark_all :: proc(d: ^Damage_Tracker, generation: u32 = 0) {
	if d == nil do return
	d.has_damage = true
	for i in 0..<len(d.dirty_rows) {
		d.dirty_rows[i] = Dirty_Row{
			generation = generation,
			full       = true,
			span_count = 0,
		}
	}
}

damage_consume :: proc(d: ^Damage_Tracker) -> Damage_Journal {
	if d == nil || !d.has_damage {
		return Damage_Journal{has_damage = false}
	}

	journal := Damage_Journal{
		has_damage = true,
		min_row    = d.row_count,
		max_row    = -1,
		min_col    = d.col_count,
		max_col    = -1,
		dirty_rows = d.dirty_rows,
	}

	for r in 0..<d.row_count {
		dr := d.dirty_rows[r]
		if dr.full {
			journal.min_row = min(journal.min_row, r)
			journal.max_row = max(journal.max_row, r)
			journal.min_col = 0
			journal.max_col = d.col_count
		} else if dr.span_count > 0 {
			journal.min_row = min(journal.min_row, r)
			journal.max_row = max(journal.max_row, r)
			for i in 0..<int(dr.span_count) {
				journal.min_col = min(journal.min_col, int(dr.spans[i].col_start))
				journal.max_col = max(journal.max_col, int(dr.spans[i].col_end))
			}
		}
	}

	// Reset dirty tracker for next frame
	damage_reset(d)

	return journal
}

package termgrid

import "base:runtime"

// Span represents a contiguous range of dirty cells in a row.
Span :: struct {
	col_start: u16,
	col_end:   u16, // exclusive
}

// DIRTY_ROW_MAX_SPANS is the maximum number of spans per dirty row before degradation.
DIRTY_ROW_MAX_SPANS :: 4

// Dirty_Row represents the dirty state of a single row.
// Uses a fixed-size array of spans (max 4). If overflow, degrades to full row.
Dirty_Row :: struct {
	generation: u32,                  // matches row.generation for validation
	span_count: u8,                   // number of spans (0-4)
	spans:      [DIRTY_ROW_MAX_SPANS]Span, // fixed array
	full:       bool,                 // true if entire row is dirty
}

// Scroll_Op represents a structural scroll operation.
Scroll_Op :: struct {
	top:    u16, // top of scroll region (inclusive)
	bottom: u16, // bottom of scroll region (inclusive)
	rows:   i16, // positive = scroll up, negative = scroll down
}

// Damage tracks all mutations since last clear.
Damage :: struct {
	dirty_rows: []Dirty_Row,        // length = grid.row_count
	scroll_ops: [dynamic]Scroll_Op, // dynamic array (rarely used)
	row_count:  int,
	col_count:  int,                // for col bounds checking in mark operations
}

// Damage_Journal is a snapshot of all damage for the renderer.
Damage_Journal :: struct {
	dirty_rows: []Dirty_Row,
	scroll_ops: []Scroll_Op,
}

// damage_init initializes damage tracking for the specified number of rows.
damage_init :: proc(d: ^Damage, rows, cols: int, allocator: runtime.Allocator = context.allocator) {
	d.dirty_rows = make([]Dirty_Row, rows, allocator)
	d.scroll_ops = make([dynamic]Scroll_Op, 0, allocator)
	d.row_count = rows
	d.col_count = cols
}

// damage_destroy frees all damage tracking state.
damage_destroy :: proc(d: ^Damage, allocator: runtime.Allocator = context.allocator) {
	if d.dirty_rows != nil {
		delete(d.dirty_rows)
		d.dirty_rows = nil
	}
	if d.scroll_ops != nil {
		delete(d.scroll_ops)
		d.scroll_ops = nil
	}
	d.row_count = 0
	d.col_count = 0
}

// _clamp_col clamps a column index to [0, col_count-1].
_clamp_col :: proc(d: ^Damage, col: int) -> int {
	if col < 0 {
		return 0
	}
	if col >= d.col_count {
		return d.col_count - 1
	}
	return col
}

// damage_mark_cell marks a single cell as dirty.
damage_mark_cell :: proc(d: ^Damage, row, col: int, generation: u32) {
	if row < 0 || row >= d.row_count {
		return
	}
	c := _clamp_col(d, col)

	dr := &d.dirty_rows[row]
	if dr.full {
		return // already fully dirty
	}

	dr.generation = generation

	if dr.span_count < DIRTY_ROW_MAX_SPANS {
		idx := int(dr.span_count)
		dr.spans[idx] = Span{col_start = u16(c), col_end = u16(c + 1)}
		dr.span_count += 1
	} else {
		// Span overflow — degrade to full row
		dr.full = true
		dr.span_count = 0
	}
}

// damage_mark_span marks a range of cells as dirty.
damage_mark_span :: proc(d: ^Damage, row, col_start, col_end: int, generation: u32) {
	if row < 0 || row >= d.row_count {
		return
	}

	cs := col_start
	ce := col_end

	// Swap if inverted
	if cs > ce {
		cs, ce = ce, cs
	}

	cs = _clamp_col(d, cs)
	ce = _clamp_col(d, ce)

	dr := &d.dirty_rows[row]
	if dr.full {
		return
	}

	dr.generation = generation

	if dr.span_count < DIRTY_ROW_MAX_SPANS {
		idx := int(dr.span_count)
		dr.spans[idx] = Span{col_start = u16(cs), col_end = u16(ce + 1)}
		dr.span_count += 1
	} else {
		// Span overflow — degrade to full row
		dr.full = true
		dr.span_count = 0
	}
}

// damage_mark_row marks an entire row as dirty.
damage_mark_row :: proc(d: ^Damage, row: int, generation: u32) {
	if row < 0 || row >= d.row_count {
		return
	}
	dr := &d.dirty_rows[row]
	dr.full = true
	dr.span_count = 0
	dr.generation = generation
}

// damage_mark_all marks all rows as dirty.
damage_mark_all :: proc(d: ^Damage, generations: []u32) {
	for i in 0..<d.row_count {
		dr := &d.dirty_rows[i]
		dr.full = true
		dr.span_count = 0
		if i < len(generations) {
			dr.generation = generations[i]
		}
	}
}

// damage_record_scroll records a structural scroll operation.
damage_record_scroll :: proc(d: ^Damage, top, bottom: int, rows: int) {
	op := Scroll_Op{
		top    = u16(top),
		bottom = u16(bottom),
		rows   = i16(rows),
	}
	append(&d.scroll_ops, op)
}

// damage_take_journal returns a snapshot of all damage and clears it.
// The caller owns the returned journal and must call damage_journal_destroy.
damage_take_journal :: proc(d: ^Damage, allocator: runtime.Allocator = context.allocator) -> Damage_Journal {
	// Copy dirty_rows
	journal_rows := make([]Dirty_Row, len(d.dirty_rows), allocator)
	copy(journal_rows, d.dirty_rows)

	// Copy scroll_ops from dynamic array to regular slice
	ops_slice := d.scroll_ops[:]
	journal_ops := make([]Scroll_Op, len(ops_slice), allocator)
	copy(journal_ops, ops_slice)

	// Clear damage state
	damage_clear(d)

	return Damage_Journal{
		dirty_rows = journal_rows,
		scroll_ops = journal_ops,
	}
}

// damage_journal_destroy frees the journal.
damage_journal_destroy :: proc(j: ^Damage_Journal, allocator: runtime.Allocator = context.allocator) {
	if j.dirty_rows != nil {
		delete(j.dirty_rows)
		j.dirty_rows = nil
	}
	if j.scroll_ops != nil {
		delete(j.scroll_ops)
		j.scroll_ops = nil
	}
}

// damage_clear clears all damage without returning a journal.
damage_clear :: proc(d: ^Damage) {
	for i in 0..<len(d.dirty_rows) {
		d.dirty_rows[i] = Dirty_Row{}
	}
	if len(d.scroll_ops) > 0 {
		delete(d.scroll_ops)
		d.scroll_ops = make([dynamic]Scroll_Op, 0, context.allocator)
	}
}

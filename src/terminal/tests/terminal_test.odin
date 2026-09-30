package termgrid_test

import "core:testing"
import "core:unicode/utf8"
import tg "../"

// --- Style Table Tests ---

@(test)
test_style_table_init :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st)

	testing.expect(t, st.count == 1, "Style table should have 1 entry after init")
	def := tg.style_table_get(&st, 0)
	testing.expect(t, def.fg == tg.CATPPUCCIN_MOCHA_TEXT, "Default style fg should use Catppuccin text")
	testing.expect(t, def.bg == tg.CATPPUCCIN_MOCHA_BASE, "Default style bg should use Catppuccin base")
}

@(test)
test_style_table_catppuccin_theme :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st, tg.THEME_CATPPUCCIN_MOCHA)

	testing.expect(t, st.theme.name == "Catppuccin Mocha", "Default theme should be Catppuccin Mocha")
	testing.expect(t, st.theme.selection_foreground == tg.CATPPUCCIN_MOCHA_BASE, "Selection foreground should use base")
	testing.expect(t, st.theme.selection_background == tg.CATPPUCCIN_MOCHA_SURFACE2, "Selection background should use surface2")
	testing.expect(t, tg.style_table_default(&st).fg == st.theme.foreground, "Theme default fg should be active")
	testing.expect(t, tg.style_table_default(&st).bg == st.theme.background, "Theme default bg should be active")
}

@(test)
test_theme_palette_ansi16 :: proc(t: ^testing.T) {
	theme := tg.THEME_CATPPUCCIN_MOCHA
	for i in 0..<tg.THEME_ANSI16_COUNT {
		testing.expect(t, tg.theme_palette_256(theme, i) == theme.ansi16[i], "ANSI16 palette should use theme mapping")
	}
}

@(test)
test_theme_palette_xterm_cube_and_grayscale :: proc(t: ^testing.T) {
	theme := tg.THEME_CATPPUCCIN_MOCHA

	testing.expect(t, tg.theme_palette_256(theme, tg.THEME_256_CUBE_START) == 0xFF000000, "Cube origin should be black")
	testing.expect(t, tg.theme_palette_256(theme, 196) == 0xFFFF0000, "Cube index 196 should be canonical red")
	testing.expect(t, tg.theme_palette_256(theme, tg.THEME_256_GRAYSCALE_START) == 0xFF080808, "Grayscale origin should be 8")
	testing.expect(t, tg.theme_palette_256(theme, 255) == 0xFFEEEEEE, "Grayscale end should be 238")
}

@(test)
test_theme_palette_invalid_index :: proc(t: ^testing.T) {
	theme := tg.THEME_CATPPUCCIN_MOCHA
	testing.expect(t, tg.theme_palette_256(theme, -1) == theme.foreground, "Negative palette index should use theme fg")
	testing.expect(t, tg.theme_palette_256(theme, tg.THEME_256_COUNT) == theme.foreground, "Large palette index should use theme fg")
}

@(test)
test_style_table_insert_dedup :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st)

	s1 := tg.Style{fg = 0xFF0000, bg = 0x000000, underline = 0, flags = 0}
	id1 := tg.style_table_insert(&st, s1)
	testing.expect(t, id1 == 1, "First insert should return id 1")

	// Insert same style again — should return same id
	id2 := tg.style_table_insert(&st, s1)
	testing.expect(t, id2 == 1, "Duplicate insert should return same id")

	// Insert different style
	s2 := tg.Style{fg = 0x00FF00, bg = 0x000000, underline = 0, flags = 0}
	id3 := tg.style_table_insert(&st, s2)
	testing.expect(t, id3 == 2, "Different style should get new id")

	testing.expect(t, st.count == 3, "Style table should have 3 entries")
}

@(test)
test_style_table_get_roundtrip :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st)

	s := tg.Style{fg = 0x123456, bg = 0x789ABC, underline = 0xDEF012, flags = 42}
	id := tg.style_table_insert(&st, s)

	retrieved := tg.style_table_get(&st, id)
	testing.expect(t, retrieved.fg == s.fg, "fg should match")
	testing.expect(t, retrieved.bg == s.bg, "bg should match")
	testing.expect(t, retrieved.underline == s.underline, "underline should match")
	testing.expect(t, retrieved.flags == s.flags, "flags should match")
}

@(test)
test_style_table_capacity_overflow :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st)

	// Fill the table
	for i in 1..<tg.STYLE_TABLE_CAPACITY {
		s := tg.Style{fg = u32(i), bg = 0, underline = 0, flags = 0}
		tg.style_table_insert(&st, s)
	}

	testing.expect(t, int(st.count) == tg.STYLE_TABLE_CAPACITY, "Table should be full")

	// Try to insert one more — should return 0 (default)
	s := tg.Style{fg = 0xFFFFFF, bg = 0xFFFFFF, underline = 0, flags = 0}
	id := tg.style_table_insert(&st, s)
	testing.expect(t, id == 0, "Overflow should return default style id 0")
}

@(test)
test_style_table_get_invalid_id :: proc(t: ^testing.T) {
	st: tg.Style_Table
	tg.style_table_init(&st)

	s := tg.style_table_get(&st, 999)
	testing.expect(t, s.fg == st.theme.foreground, "Invalid id should return active theme fg")
	testing.expect(t, s.bg == st.theme.background, "Invalid id should return active theme bg")
}

@(test)
test_style_table_invalid_id_custom_theme :: proc(t: ^testing.T) {
	theme := tg.THEME_CATPPUCCIN_MOCHA
	theme.foreground = 0xFF123456
	theme.background = 0xFF654321

	st: tg.Style_Table
	tg.style_table_init(&st, theme)
	invalid := tg.style_table_get(&st, tg.Style_Id(tg.STYLE_TABLE_CAPACITY))
	testing.expect(t, invalid.fg == theme.foreground, "Invalid id should use custom theme fg")
	testing.expect(t, invalid.bg == theme.background, "Invalid id should use custom theme bg")
}

@(test)
test_terminal_init_custom_theme :: proc(t: ^testing.T) {
	theme := tg.THEME_CATPPUCCIN_MOCHA
	theme.foreground = 0xFF112233
	theme.background = 0xFF445566

	term: tg.Terminal
	tg.terminal_init(&term, 1, 1, theme = theme)
	defer tg.terminal_destroy(&term)

	def := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, def.fg == theme.foreground, "Terminal current style should use custom theme fg")
	testing.expect(t, def.bg == theme.background, "Terminal current style should use custom theme bg")
}

// --- Row Tests ---

@(test)
test_row_init :: proc(t: ^testing.T) {
	r: tg.Row
	r.cells = make([]tg.Semantic_Cell, 10)
	tg.row_init(&r, 10)
	defer delete(r.cells)

	testing.expect(t, len(r.cells) == 10, "Row should have 10 cells")
	testing.expect(t, r.generation == 0, "Initial generation should be 0")

	// All cells should be CELL_DEFAULT
	for i in 0..<10 {
		testing.expect(t, r.cells[i].content == 0, "Cell content should be 0")
		testing.expect(t, r.cells[i].width == 1, "Cell width should be 1")
	}
}

@(test)
test_row_set_cell :: proc(t: ^testing.T) {
	r: tg.Row
	r.cells = make([]tg.Semantic_Cell, 10)
	tg.row_init(&r, 10)
	defer delete(r.cells)

	cell := tg.Semantic_Cell{content = 'A', style = 0, width = 1, flags = .None}
	ok := tg.row_set_cell(&r, 5, cell)
	testing.expect(t, ok, "set_cell should succeed")
	testing.expect(t, r.generation == 1, "Generation should increment")
	testing.expect(t, r.cells[5].content == 'A', "Cell content should be set")
}

@(test)
test_row_set_cell_out_of_bounds :: proc(t: ^testing.T) {
	r: tg.Row
	r.cells = make([]tg.Semantic_Cell, 10)
	tg.row_init(&r, 10)
	defer delete(r.cells)

	cell := tg.Semantic_Cell{content = 'A', style = 0, width = 1, flags = .None}
	ok := tg.row_set_cell(&r, -1, cell)
	testing.expect(t, !ok, "set_cell with negative col should fail")

	ok = tg.row_set_cell(&r, 10, cell)
	testing.expect(t, !ok, "set_cell with col >= len should fail")
}

@(test)
test_row_clear :: proc(t: ^testing.T) {
	r: tg.Row
	r.cells = make([]tg.Semantic_Cell, 10)
	tg.row_init(&r, 10)
	defer delete(r.cells)

	cell := tg.Semantic_Cell{content = 'X', style = 0, width = 1, flags = .None}
	tg.row_set_cell(&r, 5, cell)
	testing.expect(t, r.generation == 1, "Generation should be 1 after set")

	tg.row_clear(&r)
	testing.expect(t, r.generation == 2, "Generation should increment on clear")
	testing.expect(t, r.cells[5].content == 0, "Cell should be cleared")
}

// --- Grid Tests ---

@(test)
test_grid_init :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	testing.expect(t, g.row_count == 24, "row_count should be 24")
	testing.expect(t, g.col_count == 80, "col_count should be 80")
	testing.expect(t, g.capacity == 32, "capacity should be 32 (next power of 2)")
	testing.expect(t, g.mask == 31, "mask should be 31")
	testing.expect(t, g.origin == 0, "origin should be 0")
}

@(test)
test_grid_set_get_cell :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	cell := tg.Semantic_Cell{content = 'H', style = 0, width = 1, flags = .None}
	ok := tg.grid_set_cell(&g, 5, 10, cell)
	testing.expect(t, ok, "set_cell should succeed")

	retrieved := tg.grid_get_cell(&g, 5, 10)
	testing.expect(t, retrieved.content == 'H', "Cell content should match")
}

@(test)
test_grid_bounds :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	cell := tg.Semantic_Cell{content = 'X', style = 0, width = 1, flags = .None}

	// Out of bounds set
	ok := tg.grid_set_cell(&g, -1, 0, cell)
	testing.expect(t, !ok, "set_cell with negative row should fail")

	ok = tg.grid_set_cell(&g, 24, 0, cell)
	testing.expect(t, !ok, "set_cell with row >= row_count should fail")

	ok = tg.grid_set_cell(&g, 0, -1, cell)
	testing.expect(t, !ok, "set_cell with negative col should fail")

	ok = tg.grid_set_cell(&g, 0, 80, cell)
	testing.expect(t, !ok, "set_cell with col >= col_count should fail")

	// Out of bounds get
	retrieved := tg.grid_get_cell(&g, -1, 0)
	testing.expect(t, retrieved.content == 0, "Out of bounds get should return CELL_DEFAULT")
}

@(test)
test_grid_scroll_up :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	// Write to row 0
	cell := tg.Semantic_Cell{content = 'A', style = 0, width = 1, flags = .None}
	tg.grid_set_cell(&g, 0, 0, cell)

	// Scroll up by 1
	actual := tg.grid_scroll_up(&g, 1)
	testing.expect(t, actual == 1, "Should scroll 1 row")
	testing.expect(t, g.origin == 1, "Origin should be 1")

	// Row 0 should now be empty (it was cleared)
	retrieved := tg.grid_get_cell(&g, 0, 0)
	testing.expect(t, retrieved.content == 0, "Row 0 should be cleared after scroll")

	// The old row 0 data is now at row 23 (wrapped around)
	// But we can't access it directly because row 23 is the last visible row
}

@(test)
test_grid_scroll_down :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	cell := tg.Semantic_Cell{content = 'B', style = 0, width = 1, flags = .None}
	tg.grid_set_cell(&g, 23, 0, cell)

	actual := tg.grid_scroll_down(&g, 1)
	testing.expect(t, actual == 1, "Should scroll 1 row")

	// Row 0 should be cleared
	retrieved := tg.grid_get_cell(&g, 0, 0)
	testing.expect(t, retrieved.content == 0, "Row 0 should be cleared after scroll down")
}

@(test)
test_grid_scroll_clamp :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	actual := tg.grid_scroll_up(&g, 100)
	testing.expect(t, actual == 24, "Scroll should be clamped to row_count")
}

// --- Damage Tests ---

@(test)
test_damage_init :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	testing.expect(t, d.row_count == 24, "row_count should be 24")
	testing.expect(t, d.col_count == 80, "col_count should be 80")
	testing.expect(t, len(d.dirty_rows) == 24, "dirty_rows length should be 24")
	testing.expect(t, len(d.journal_rows) == 24, "journal_rows length should be 24")
}

@(test)
test_damage_mark_cell :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	tg.damage_mark_cell(&d, 5, 10, 1)

	testing.expect(t, d.dirty_rows[5].span_count == 1, "Should have 1 span")
	testing.expect(t, d.dirty_rows[5].spans[0].col_start == 10, "Span start should be 10")
	testing.expect(t, d.dirty_rows[5].spans[0].col_end == 11, "Span end should be 11")
	testing.expect(t, d.dirty_rows[5].generation == 1, "Generation should match")
}

@(test)
test_damage_mark_span :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	tg.damage_mark_span(&d, 5, 10, 20, 1)

	testing.expect(t, d.dirty_rows[5].span_count == 1, "Should have 1 span")
	testing.expect(t, d.dirty_rows[5].spans[0].col_start == 10, "Span start should be 10")
	testing.expect(t, d.dirty_rows[5].spans[0].col_end == 21, "Span end should be 21 (exclusive)")
}

@(test)
test_damage_mark_span_inverted :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	// col_start > col_end — should swap
	tg.damage_mark_span(&d, 5, 20, 10, 1)

	testing.expect(t, d.dirty_rows[5].spans[0].col_start == 10, "Should swap to normal order")
	testing.expect(t, d.dirty_rows[5].spans[0].col_end == 21, "Should swap to normal order")
}

@(test)
test_damage_overflow_to_full :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	// Add 4 spans
	for i in 0..<4 {
		tg.damage_mark_cell(&d, 5, i * 10, 1)
	}
	testing.expect(t, d.dirty_rows[5].span_count == 4, "Should have 4 spans")
	testing.expect(t, !d.dirty_rows[5].full, "Should not be full yet")

	// Add 5th span — should overflow to full
	tg.damage_mark_cell(&d, 5, 50, 1)
	testing.expect(t, d.dirty_rows[5].full, "Should be marked full after overflow")
	testing.expect(t, d.dirty_rows[5].span_count == 0, "Spans should be cleared")
}

@(test)
test_damage_mark_row :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	tg.damage_mark_row(&d, 5, 1)

	testing.expect(t, d.dirty_rows[5].full, "Row should be marked full")
	testing.expect(t, d.dirty_rows[5].generation == 1, "Generation should match")
}

@(test)
test_damage_take_journal :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	tg.damage_mark_cell(&d, 5, 10, 1)
	tg.damage_mark_row(&d, 10, 2)

	journal := tg.damage_take_journal(&d)
	defer tg.damage_journal_destroy(&journal)

	testing.expect(t, len(journal.dirty_rows) == 24, "Journal should have 24 rows")
	testing.expect(t, journal.dirty_rows[5].span_count == 1, "Row 5 should have damage")
	testing.expect(t, journal.dirty_rows[10].full, "Row 10 should be full")

	// Damage should be cleared
	testing.expect(t, d.dirty_rows[5].span_count == 0, "Damage should be cleared")
	testing.expect(t, !d.dirty_rows[10].full, "Damage should be cleared")
}

@(test)
test_damage_journal_reuse_and_empty :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 8, 40)
	defer tg.damage_destroy(&d)

	empty := tg.damage_take_journal(&d)
	testing.expect(t, len(empty.dirty_rows) == 8, "Empty journal should retain row shape")
	testing.expect(t, len(empty.scroll_ops) == 0, "Empty journal should have no scroll ops")
	tg.damage_journal_destroy(&empty)

	tg.damage_mark_span(&d, 2, 4, 7, 11)
	tg.damage_record_scroll(&d, 1, 6, 2)
	tg.damage_record_scroll(&d, 1, 6, -1)
	journal := tg.damage_take_journal(&d)
	rows_ptr := rawptr(&journal.dirty_rows[0])
	ops_ptr := rawptr(&journal.scroll_ops[0])
	testing.expect(t, journal.borrowed, "Taken journal should be marked borrowed")
	testing.expect(t, d.journal_active, "Damage should mark its journal active")
	testing.expect(t, journal.dirty_rows[2].generation == 11, "Span generation should survive take")
	testing.expect(t, journal.dirty_rows[2].spans[0].col_start == 4, "Span start should survive take")
	testing.expect(t, journal.dirty_rows[2].spans[0].col_end == 8, "Span end should survive take")
	testing.expect(t, journal.scroll_ops[0].rows == 2, "First scroll op should preserve order")
	testing.expect(t, journal.scroll_ops[1].rows == -1, "Second scroll op should preserve order")
	tg.damage_journal_destroy(&journal)

	tg.damage_mark_cell(&d, 1, 3, 12)
	tg.damage_record_scroll(&d, 1, 6, 3)
	journal2 := tg.damage_take_journal(&d)
	testing.expect(t, rawptr(&journal2.dirty_rows[0]) == rows_ptr, "Rows should use reusable storage")
	testing.expect(t, rawptr(&journal2.scroll_ops[0]) == ops_ptr, "Ops should use reusable storage")
	testing.expect(t, len(journal2.scroll_ops) == 1, "Reuse after destroy should retain new ops")
	tg.damage_journal_destroy(&journal2)
	testing.expect(t, !d.journal_active, "Destroy should release the journal borrow")
}

@(test)
test_damage_requeue_journal_preserves_snapshot :: proc(t: ^testing.T) {
	d: tg.Damage
	tg.damage_init(&d, 6, 20)
	defer tg.damage_destroy(&d)

	tg.damage_mark_span(&d, 2, 3, 5, 21)
	tg.damage_mark_row(&d, 4, 22)
	tg.damage_record_scroll(&d, 1, 5, 2)
	tg.damage_record_scroll(&d, 1, 5, -1)

	journal := tg.damage_take_journal(&d)
	tg.damage_requeue_journal(&d, &journal)

	testing.expect(t, d.dirty_rows[2].generation == 21, "Requeue should preserve span generation")
	testing.expect(t, d.dirty_rows[2].span_count == 1, "Requeue should preserve spans")
	testing.expect(t, d.dirty_rows[4].full && d.dirty_rows[4].generation == 22, "Requeue should preserve full row generation")
	testing.expect(t, len(d.scroll_ops) == 2, "Requeue should preserve scroll count")
	testing.expect(t, d.scroll_ops[0].rows == 2 && d.scroll_ops[1].rows == -1, "Requeue should preserve scroll order")
	tg.damage_journal_destroy(&journal)
}

@(test)
test_damage_owned_manual_journal_destroy :: proc(t: ^testing.T) {
	journal := tg.Damage_Journal{
		dirty_rows = make([]tg.Dirty_Row, 1),
		scroll_ops = make([]tg.Scroll_Op, 1),
	}
	tg.damage_journal_destroy(&journal)

	testing.expect(t, journal.dirty_rows == nil, "Owned journal rows should be released")
	testing.expect(t, journal.scroll_ops == nil, "Owned journal ops should be released")
}

// --- Cursor Tests ---

@(test)
test_cursor_init :: proc(t: ^testing.T) {
	c: tg.Cursor
	tg.cursor_init(&c)

	testing.expect(t, c.row == 0, "Initial row should be 0")
	testing.expect(t, c.col == 0, "Initial col should be 0")
	testing.expect(t, c.visible, "Cursor should be visible")
}

@(test)
test_cursor_move :: proc(t: ^testing.T) {
	c: tg.Cursor
	tg.cursor_init(&c)

	tg.cursor_move(&c, 10, 20, 24, 80)
	testing.expect(t, c.row == 10, "Row should be 10")
	testing.expect(t, c.col == 20, "Col should be 20")

	// Clamp to bounds
	tg.cursor_move(&c, -5, -5, 24, 80)
	testing.expect(t, c.row == 0, "Row should be clamped to 0")
	testing.expect(t, c.col == 0, "Col should be clamped to 0")

	tg.cursor_move(&c, 100, 100, 24, 80)
	testing.expect(t, c.row == 23, "Row should be clamped to 23")
	testing.expect(t, c.col == 79, "Col should be clamped to 79")
}

@(test)
test_cursor_advance :: proc(t: ^testing.T) {
	c: tg.Cursor
	tg.cursor_init(&c)

	scroll_needed: bool
	tg.cursor_advance(&c, 1, 24, 80, &scroll_needed)
	testing.expect(t, c.col == 1, "Col should advance to 1")
	testing.expect(t, !scroll_needed, "No scroll needed")

	// Advance to right edge: xenl defers wrap, stays at last col with pending_wrap
	tg.cursor_move(&c, 0, 79, 24, 80)
	tg.cursor_advance(&c, 1, 24, 80, &scroll_needed)
	testing.expect(t, c.col == 79, "xenl: col stays at last column")
	testing.expect(t, c.pending_wrap, "xenl: pending_wrap should be set")
	testing.expect(t, !scroll_needed, "No scroll needed yet")

	// Apply pending wrap: now cursor moves to next line
	scroll_needed = tg.cursor_apply_pending_wrap(&c, 24)
	testing.expect(t, c.col == 0, "After apply: col wraps to 0")
	testing.expect(t, c.row == 1, "After apply: row advances to 1")
	testing.expect(t, !c.pending_wrap, "After apply: pending_wrap cleared")
	testing.expect(t, !scroll_needed, "No scroll needed")

	// Advance at bottom-right corner with pending wrap
	tg.cursor_move(&c, 23, 79, 24, 80)
	tg.cursor_advance(&c, 1, 24, 80, &scroll_needed)
	testing.expect(t, c.pending_wrap, "pending_wrap set at bottom-right")
	scroll_needed = tg.cursor_apply_pending_wrap(&c, 24)
	testing.expect(t, c.row == 23, "Row stays at 23 (clamped)")
	testing.expect(t, scroll_needed, "Scroll needed at bottom")
}

// --- Terminal Tests ---

@(test)
test_terminal_init :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.grid.row_count == 24, "Grid row_count should be 24")
	testing.expect(t, term.grid.col_count == 80, "Grid col_count should be 80")
	testing.expect(t, term.cursor.row == 0, "Cursor row should be 0")
	testing.expect(t, term.cursor.col == 0, "Cursor col should be 0")
	testing.expect(t, term.current_style == 0, "Current style should be 0")
}

@(test)
test_terminal_put_char :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 'A')

	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'A', "Cell should contain 'A'")

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "Cursor should advance to col 1")
}

@(test)
test_termgrid_put_string :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_string(&term, "Hello")

	s := "Hello"
	for i in 0..<len(s) {
		cell := tg.terminal_get_cell(&term, 0, i)
		r, _ := utf8.decode_rune_in_string(s[i:])
		testing.expect(t, cell.content == tg.Content_Handle(r), "Cell should match string character")
	}

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 5, "Cursor should be at col 5")
}

@(test)
test_terminal_newline :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_string(&term, "Hello")
	tg.terminal_newline(&term)

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 1, "Row should be 1 after newline")
	testing.expect(t, cursor.col == 0, "Col should be 0 after newline")
}

@(test)
test_terminal_scroll :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_string(&term, "Line 1")
	tg.terminal_newline(&term)
	tg.terminal_put_string(&term, "Line 2")

	tg.terminal_scroll_up(&term, 1)

	// Row 0 should now contain "Line 2" (which was on row 1)
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'L', "Row 0 should contain 'L' from 'Line 2'")
	cell = tg.terminal_get_cell(&term, 0, 5)
	testing.expect(t, cell.content == '2', "Row 0 should contain '2' from 'Line 2'")

	// Row 1 should be cleared (it's the new bottom row after scroll)
	cell = tg.terminal_get_cell(&term, 1, 0)
	testing.expect(t, cell.content == 0, "Row 1 should be cleared after scroll")
}

@(test)
test_terminal_damage_target_validation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)
	defer tg.terminal_destroy(&term)

	target := tg.terminal_damage_target(&term, 1, 2)
	testing.expect(t, tg.terminal_apply_damage_target(&term, target), "matching target must apply")
	tg.damage_clear(&term.damage)

	stale_generation := tg.terminal_damage_target(&term, 1, 2)
	_ = tg.grid_set_cell(&term.grid, 1, 0, tg.Semantic_Cell{content = 'x', width = 1})
	testing.expect(t, !tg.terminal_apply_damage_target(&term, stale_generation), "stale generation must reject")

	stale_epoch := tg.terminal_damage_target(&term, 0, 0)
	tg.terminal_scroll_up(&term, 1)
	testing.expect(t, !tg.terminal_apply_damage_target(&term, stale_epoch), "stale epoch must reject")
	testing.expect(t, !tg.terminal_apply_damage_target(&term, tg.Damage_Target{row = -1, col = 0, epoch = term.render_epoch}), "negative row must reject")
	testing.expect(t, !tg.terminal_apply_damage_target(&term, tg.Damage_Target{row = 0, col = 4, epoch = term.render_epoch}), "out of bounds col must reject")
}

@(test)
test_terminal_damage_epoch_structural_changes :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 3, 4)
	defer tg.terminal_destroy(&term)
	initial := term.render_epoch
	tg.terminal_resize(&term, 4, 4)
	testing.expect(t, term.render_epoch != initial, "resize must advance epoch")
	before_scroll := term.render_epoch
	tg.terminal_scroll_down(&term, 1)
	testing.expect(t, term.render_epoch != before_scroll, "scroll must advance epoch")
}

@(test)
test_terminal_cursor_movement :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 10, 20)
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 10, "Row should be 10")
	testing.expect(t, cursor.col == 20, "Col should be 20")

	tg.terminal_cursor_up(&term, 3)
	cursor = tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 7, "Row should be 7 after up 3")

	tg.terminal_cursor_down(&term, 5)
	cursor = tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 12, "Row should be 12 after down 5")

	tg.terminal_cursor_left(&term, 10)
	cursor = tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 10, "Col should be 10 after left 10")

	tg.terminal_cursor_right(&term, 15)
	cursor = tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 25, "Col should be 25 after right 15")
}

@(test)
test_terminal_erase_line :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_string(&term, "Hello, World!")
	tg.terminal_move_cursor(&term, 0, 7)

	tg.terminal_erase_line(&term, .To_End)

	// Characters before cursor should remain
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'H', "H should remain")

	// Characters at and after cursor should be erased
	cell = tg.terminal_get_cell(&term, 0, 7)
	testing.expect(t, cell.content == 0, "Position 7 should be erased")
}

// --- Integration Test ---

@(test)
test_integration_hello_world :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_string(&term, "hello\nworld")

	// Verify grid state
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'h', "Row 0, col 0 should be 'h'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 'e', "Row 0, col 1 should be 'e'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 'l', "Row 0, col 2 should be 'l'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 3).content == 'l', "Row 0, col 3 should be 'l'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 4).content == 'o', "Row 0, col 4 should be 'o'")

	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 0).content == 'w', "Row 1, col 0 should be 'w'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 1).content == 'o', "Row 1, col 1 should be 'o'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 2).content == 'r', "Row 1, col 2 should be 'r'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 3).content == 'l', "Row 1, col 3 should be 'l'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 4).content == 'd', "Row 1, col 4 should be 'd'")

	// Verify cursor position
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 1, "Cursor row should be 1")
	testing.expect(t, cursor.col == 5, "Cursor col should be 5")

	// Verify damage
	journal := tg.terminal_take_damage(&term)
	defer tg.damage_journal_destroy(&journal)

	testing.expect(t, journal.dirty_rows[0].span_count > 0 || journal.dirty_rows[0].full, "Row 0 should be marked dirty")
	testing.expect(t, journal.dirty_rows[1].span_count > 0 || journal.dirty_rows[1].full, "Row 1 should be marked dirty")
}

// --- Notification and Bell Tests ---

@(test)
test_terminal_bell :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, !term.bell_event, "bell_event must start false")
	tg.terminal_bell(&term)
	testing.expect(t, term.bell_event, "bell_event must be true after terminal_bell")
}

@(test)
test_terminal_osc_9_notify :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	msg := "Build succeeded"
	tg.terminal_osc_9_notify(&term, transmute([]u8)msg)

	notif, ok := tg.terminal_pop_notification(&term)
	testing.expect(t, ok, "notification pop should succeed")
	testing.expect(t, string(notif.title[:notif.title_len]) == "Terminal", "OSC 9 default title should be 'Terminal'")
	testing.expect(t, string(notif.message[:notif.message_len]) == msg, "OSC 9 message should match payload")

	_, ok2 := tg.terminal_pop_notification(&term)
	testing.expect(t, !ok2, "queue should be empty after pop")
}

@(test)
test_terminal_osc_777_notify :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Happy path
	payload := "notify;Alert;Service online"
	tg.terminal_osc_777_notify(&term, transmute([]u8)payload)

	notif, ok := tg.terminal_pop_notification(&term)
	testing.expect(t, ok, "notification pop should succeed")
	testing.expect(t, string(notif.title[:notif.title_len]) == "Alert", "OSC 777 title should match")
	testing.expect(t, string(notif.message[:notif.message_len]) == "Service online", "OSC 777 message should match")

	// Missing semicolon (no message separator) -> dropped safely
	invalid_payload := "notify;AlertOnly"
	tg.terminal_osc_777_notify(&term, transmute([]u8)invalid_payload)
	testing.expect(t, term.notification_count == 0, "malformed OSC 777 payload without semicolon must be dropped safely")

	// Missing notify; prefix -> dropped safely
	invalid_prefix := "alert;Alert;Message"
	tg.terminal_osc_777_notify(&term, transmute([]u8)invalid_prefix)
	testing.expect(t, term.notification_count == 0, "OSC 777 payload without notify; prefix must be dropped safely")
}

@(test)
test_terminal_notification_queue_cap_and_drop_oldest :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Push 18 notifications (capacity is 16)
	for i in 0..<18 {
		msg_buf: [16]u8
		msg_buf[0] = 'm'
		msg_buf[1] = u8('0' + (i % 10))
		tg.terminal_osc_9_notify(&term, msg_buf[:2])
	}

	testing.expect(t, term.notification_count == 16, "notification count should cap at 16")

	// First popped should be item index 2 ('m2') because items 0 and 1 were dropped
	notif, ok := tg.terminal_pop_notification(&term)
	testing.expect(t, ok, "pop should succeed")
	testing.expect(t, string(notif.message[:notif.message_len]) == "m2", "oldest items should be dropped on queue overflow")
}

@(test)
test_terminal_notification_clamping :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	long_msg: [300]u8
	for i in 0..<len(long_msg) {
		long_msg[i] = 'A'
	}

	tg.terminal_osc_9_notify(&term, long_msg[:])

	notif, ok := tg.terminal_pop_notification(&term)
	testing.expect(t, ok, "pop should succeed")
	testing.expect(t, notif.message_len == 255, "message length should clamp to 255 bytes")
}

@(test)
test_terminal_dec_line_drawing_translation :: proc(t: ^testing.T) {
	expected_mappings := [32]struct {
		input:    u8,
		expected: rune,
	}{
		{0x5F, ' '},
		{0x60, '◆'},
		{0x61, '▒'},
		{0x62, '␉'},
		{0x63, '␌'},
		{0x64, '␍'},
		{0x65, '␊'},
		{0x66, '°'},
		{0x67, '±'},
		{0x68, '␤'},
		{0x69, '␋'},
		{0x6A, '┘'},
		{0x6B, '┐'},
		{0x6C, '┌'},
		{0x6D, '└'},
		{0x6E, '┼'},
		{0x6F, '⎺'},
		{0x70, '⎻'},
		{0x71, '─'},
		{0x72, '⎼'},
		{0x73, '⎽'},
		{0x74, '├'},
		{0x75, '┤'},
		{0x76, '┴'},
		{0x77, '┬'},
		{0x78, '│'},
		{0x79, '≤'},
		{0x7A, '≥'},
		{0x7B, 'π'},
		{0x7C, '≠'},
		{0x7D, '£'},
		{0x7E, '·'},
	}

	for m in expected_mappings {
		actual := tg.terminal_translate_dec_line(m.input)
		testing.expect(t, actual == m.expected, "DEC translation mapping mismatch")
	}

	// Any other byte must return rune(b) unchanged
	testing.expect(t, tg.terminal_translate_dec_line('A') == 'A', "'A' should remain unchanged")
	testing.expect(t, tg.terminal_translate_dec_line('1') == '1', "'1' should remain unchanged")
	testing.expect(t, tg.terminal_translate_dec_line(' ') == ' ', "' ' should remain unchanged")
	testing.expect(t, tg.terminal_translate_dec_line(0x7F) == 0x7F, "DEL should remain unchanged")
}

@(test)
test_terminal_dec_charset_state_machine :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.charset_g0 == .US_ASCII, "initial G0 must be US_ASCII")
	testing.expect(t, term.charset_g1 == .US_ASCII, "initial G1 must be US_ASCII")
	testing.expect(t, !term.active_charset_is_g1, "initial active charset must be G0")
	testing.expect(t, !term.active_charset_is_dec, "initial active charset must not be DEC")

	// Designate G0 to DEC_Line_Drawing -> active_charset_is_dec becomes true
	tg.terminal_designate_g0(&term, .DEC_Line_Drawing)
	testing.expect(t, term.charset_g0 == .DEC_Line_Drawing, "G0 must be DEC_Line_Drawing")
	testing.expect(t, term.active_charset_is_dec, "active_charset_is_dec must be true when G0 active")

	// Designate G0 back to US_ASCII
	tg.terminal_designate_g0(&term, .US_ASCII)
	testing.expect(t, term.charset_g0 == .US_ASCII, "G0 must be US_ASCII")
	testing.expect(t, !term.active_charset_is_dec, "active_charset_is_dec must be false")

	// Designate G1 to DEC_Line_Drawing; G0 is still active, so active_charset_is_dec remains false
	tg.terminal_designate_g1(&term, .DEC_Line_Drawing)
	testing.expect(t, term.charset_g1 == .DEC_Line_Drawing, "G1 must be DEC_Line_Drawing")
	testing.expect(t, !term.active_charset_is_dec, "active_charset_is_dec must remain false while G0 active")

	// Shift out -> G1 active
	tg.terminal_shift_out(&term)
	testing.expect(t, term.active_charset_is_g1, "active_charset_is_g1 must be true after shift out")
	testing.expect(t, term.active_charset_is_dec, "active_charset_is_dec must be true after shift out to DEC G1")

	// Shift in -> G0 active (US_ASCII)
	tg.terminal_shift_in(&term)
	testing.expect(t, !term.active_charset_is_g1, "active_charset_is_g1 must be false after shift in")
	testing.expect(t, !term.active_charset_is_dec, "active_charset_is_dec must be false after shift in to US_ASCII G0")

	// Reset terminal
	tg.terminal_shift_out(&term)
	tg.terminal_reset(&term)
	testing.expect(t, term.charset_g0 == .US_ASCII, "reset must restore G0 to US_ASCII")
	testing.expect(t, term.charset_g1 == .US_ASCII, "reset must restore G1 to US_ASCII")
	testing.expect(t, !term.active_charset_is_g1, "reset must restore active to G0")
	testing.expect(t, !term.active_charset_is_dec, "reset must clear active DEC flag")
}

@(test)
test_terminal_dec_put_char_and_print_span :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Activate DEC Line Drawing on G0
	tg.terminal_designate_g0(&term, .DEC_Line_Drawing)

	// Single char write via terminal_put_char
	tg.terminal_put_char(&term, 'q')
	cell0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, cell0.content == tg.Content_Handle('─'), "put_char 'q' should translate to '─'")

	// Non-drawing ASCII char remains raw
	tg.terminal_put_char(&term, 'A')
	cell1 := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, cell1.content == tg.Content_Handle('A'), "put_char 'A' should remain 'A'")

	// Batch write via terminal_print_span
	tg.terminal_move_cursor(&term, 1, 0)
	box_run := []u8{'l', 'q', 'k', 'x', 'm', 'j'}
	tg.terminal_print_span(&term, box_run, 0)

	expected_run := []rune{'┌', '─', '┐', '│', '└', '┘'}
	for exp, i in expected_run {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle(exp), "print_span box drawing rune must match")
	}

	// Switch back to US_ASCII and write again
	tg.terminal_designate_g0(&term, .US_ASCII)
	tg.terminal_move_cursor(&term, 2, 0)
	tg.terminal_print_span(&term, box_run, 0)

	for b, i in box_run {
		cell := tg.grid_get_cell(&term.grid, 2, i)
		testing.expect(t, cell.content == tg.Content_Handle(b), "plain ASCII print_span must match byte exactly")
	}
}

@(test)
test_terminal_prompt_zone_propagation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_osc_133_prompt_start(&term)
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is prompt on start")

	// terminal_linefeed propagates prompt mark
	tg.terminal_linefeed(&term)
	testing.expect(t, term.cursor.row == 1, "cursor row is 1 after linefeed")
	testing.expect(t, term.grid.rows[1].is_prompt, "row 1 is prompt via linefeed propagation")

	// terminal_index propagates prompt mark
	tg.terminal_index(&term)
	testing.expect(t, term.cursor.row == 2, "cursor row is 2 after index")
	testing.expect(t, term.grid.rows[2].is_prompt, "row 2 is prompt via index propagation")

	// terminal_next_line propagates prompt mark
	tg.terminal_next_line(&term)
	testing.expect(t, term.cursor.row == 3, "cursor row is 3 after next_line")
	testing.expect(t, term.grid.rows[3].is_prompt, "row 3 is prompt via next_line propagation")

	// End prompt zone
	tg.terminal_osc_133_prompt_end(&term)
	testing.expect(t, !term.in_prompt_zone, "in_prompt_zone is false after prompt_end")

	// Next linefeed does not mark row 4 as prompt
	tg.terminal_linefeed(&term)
	testing.expect(t, term.cursor.row == 4, "cursor row is 4 after exit")
	testing.expect(t, !term.grid.rows[4].is_prompt, "row 4 is not prompt after prompt_end")
}


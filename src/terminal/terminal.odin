package termgrid

import "base:runtime"
import "core:unicode/utf8"

// Terminal is the top-level terminal emulator state.
Terminal :: struct {
	grid:               Grid,
	alt_grid:           Grid,
	is_alt_screen:      bool,
	cursor:             Cursor,
	saved_cursor:       Cursor,
	saved_cursor_valid: bool,
	current_style:      Style_Id,
	damage:             Damage,
	scroll_top:         int,
	scroll_bottom:      int,
	grapheme_store:     Grapheme_Store,
	scrollback:         Scrollback,
	render_epoch:       u64,
}

// Erase_Mode specifies how to erase content.
Erase_Mode :: enum {
	To_End,        // erase from cursor to end
	To_Beginning,  // erase from beginning to cursor
	Entire,        // erase entire line/display
}

// terminal_init initializes a terminal with the specified dimensions and theme.
terminal_init :: proc(
	t: ^Terminal,
	rows, cols: int,
	allocator: runtime.Allocator = context.allocator,
	theme: Theme = THEME_CATPPUCCIN_MOCHA,
) {
	grid_init(&t.grid, rows, cols, allocator, theme)
	grid_init(&t.alt_grid, rows, cols, allocator, theme)
	t.is_alt_screen = false
	cursor_init(&t.cursor)
	t.saved_cursor = t.cursor
	t.saved_cursor_valid = false
	t.current_style = 0
	damage_init(&t.damage, rows, cols, allocator)
	t.scroll_top = 0
	t.scroll_bottom = rows - 1
	t.render_epoch = 1
	grapheme_store_init(&t.grapheme_store)
	scrollback_init(&t.scrollback, cols, allocator = allocator)
}

// terminal_destroy frees all terminal state.
terminal_destroy :: proc(t: ^Terminal, allocator: runtime.Allocator = context.allocator) {
	scrollback_destroy(&t.scrollback, &t.grapheme_store, allocator)
	grid_destroy(&t.grid, allocator)
	grid_destroy(&t.alt_grid, allocator)
	damage_destroy(&t.damage, allocator)
}

// terminal_put_char writes a character at the cursor position and advances the cursor.
// ASCII (c < 0x80) takes the fast path verbatim (width 1, no width lookup);
// all other runes delegate to terminal_put_char_slow. Signature unchanged.
terminal_put_char :: proc(t: ^Terminal, c: rune) {
	if c < 0x80 {
		cell := Semantic_Cell{
			content = Content_Handle(c),
			style   = t.current_style,
			width   = 1,
			flags   = .None,
		}

		row := t.cursor.row
		col := t.cursor.col

		// Write the cell
		ok := grid_set_cell(&t.grid, row, col, cell)
		if ok {
			// Mark damage
			gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
			damage_mark_cell(&t.damage, row, col, gen)
		}

		// Advance cursor
		scroll_needed: bool
		cursor_advance(&t.cursor, 1, t.grid.row_count, t.grid.col_count, &scroll_needed)

		if t.cursor.row != row || scroll_needed {
			t.grid.rows[_grid_physical_row(&t.grid, row)].wrapped = true
		}
		if scroll_needed {
			terminal_scroll_up(t, 1)
		}
		return
	}
	terminal_put_char_slow(t, c)
}

// terminal_put_char_slow writes a non-ASCII rune: extend appends to the base
// cluster (no advance), wide writes a lead+continuation pair (+2), else a
// narrow cell (+1).
terminal_put_char_slow :: proc(t: ^Terminal, c: rune) {
	if is_zero_width_extend(c) {
		terminal_put_combining(t, c)
		return
	}
	if wcwidth(c) == 2 {
		terminal_put_wide(t, c)
		return
	}

	row := t.cursor.row
	col := t.cursor.col
	_wide_overwrite_repair(t, row, col, 1)
	grapheme_store_release(&t.grapheme_store, grid_get_cell(&t.grid, row, col).content)

	cell := Semantic_Cell{
		content = Content_Handle(c),
		style   = t.current_style,
		width   = 1,
		flags   = .None,
	}

	ok := grid_set_cell(&t.grid, row, col, cell)
	if ok {
		gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
		damage_mark_cell(&t.damage, row, col, gen)
	}

	scroll_needed: bool
	cursor_advance(&t.cursor, 1, t.grid.row_count, t.grid.col_count, &scroll_needed)

	if t.cursor.row != row || scroll_needed {
		t.grid.rows[_grid_physical_row(&t.grid, row)].wrapped = true
	}
	if scroll_needed {
		terminal_scroll_up(t, 1)
	}
}

// terminal_put_wide writes a wide rune as lead + Wide_Continuation pair and
// advances +2. At the right edge (col == cols-1) the pair cannot split:
// pad the edge cell blank, newline-advance, and write the pair on the next
// row at cols 0..1.
terminal_put_wide :: proc(t: ^Terminal, c: rune) {
	row := t.cursor.row
	col := t.cursor.col

	if col == t.grid.col_count - 1 {
		grapheme_store_release(&t.grapheme_store, grid_get_cell(&t.grid, row, col).content)
		if grid_set_cell(&t.grid, row, col, CELL_DEFAULT) {
			gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
			damage_mark_cell(&t.damage, row, col, gen)
		}
		scroll_needed: bool
		cursor_advance(&t.cursor, 1, t.grid.row_count, t.grid.col_count, &scroll_needed)
		if t.cursor.row != row || scroll_needed {
			t.grid.rows[_grid_physical_row(&t.grid, row)].wrapped = true
		}
		if scroll_needed {
			terminal_scroll_up(t, 1)
		}
		row = t.cursor.row
		col = t.cursor.col
	}

	if t.grid.col_count < 2 {
		return
	}

	_wide_overwrite_repair(t, row, col, 2)
	grapheme_store_release(&t.grapheme_store, grid_get_cell(&t.grid, row, col).content)
	grapheme_store_release(&t.grapheme_store, grid_get_cell(&t.grid, row, col + 1).content)

	lead := Semantic_Cell{
		content = Content_Handle(c),
		style   = t.current_style,
		width   = 2,
		flags   = .None,
	}
	cont := Semantic_Cell{
		content = 0,
		style   = t.current_style,
		width   = 1,
		flags   = .Wide_Continuation,
	}

	if grid_set_cell(&t.grid, row, col, lead) {
		gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
		damage_mark_cell(&t.damage, row, col, gen)
	}
	if grid_set_cell(&t.grid, row, col + 1, cont) {
		gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
		damage_mark_cell(&t.damage, row, col + 1, gen)
	}

	scroll_needed: bool
	cursor_advance(&t.cursor, 2, t.grid.row_count, t.grid.col_count, &scroll_needed)

	if t.cursor.row != row || scroll_needed {
		t.grid.rows[_grid_physical_row(&t.grid, row)].wrapped = true
	}
	if scroll_needed {
		terminal_scroll_up(t, 1)
	}
}

// terminal_put_combining appends a combining mark to the base cluster at
// (row, col-1). Dropped when col == 0 or the anchor cell is empty
// (content == 0, which also covers Wide_Continuation anchors). Cursor unmoved.
terminal_put_combining :: proc(t: ^Terminal, c: rune) {
	row := t.cursor.row
	col := t.cursor.col

	if col == 0 {
		return
	}

	base_cell := grid_get_cell(&t.grid, row, col - 1)
	if base_cell.content == 0 {
		return
	}

	new_handle := grapheme_store_add_mark(&t.grapheme_store, base_cell.content, c)
	new_cell := Semantic_Cell{
		content = new_handle,
		style   = t.current_style,
		width   = base_cell.width,
		flags   = base_cell.flags,
	}

	if grid_set_cell(&t.grid, row, col - 1, new_cell) {
		gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
		damage_mark_cell(&t.damage, row, col - 1, gen)
	}
}

// _cell_is_lead reports whether cell is a wide lead (width 2, not continuation).
_cell_is_lead :: proc(cell: Semantic_Cell) -> bool {
	return cell.width == 2 && u8(cell.flags) & u8(Cell_Flags.Wide_Continuation) == 0
}

// _cell_is_continuation reports whether cell is a wide continuation (right half).
_cell_is_continuation :: proc(cell: Semantic_Cell) -> bool {
	return u8(cell.flags) & u8(Cell_Flags.Wide_Continuation) != 0
}

// _terminal_blank_cell resets a cell to CELL_DEFAULT, releasing any pool
// handle it held, and marks damage.
_terminal_blank_cell :: proc(t: ^Terminal, row, col: int) {
	grapheme_store_release(&t.grapheme_store, grid_get_cell(&t.grid, row, col).content)
	if grid_set_cell(&t.grid, row, col, CELL_DEFAULT) {
		gen := t.grid.rows[_grid_physical_row(&t.grid, row)].generation
		damage_mark_cell(&t.damage, row, col, gen)
	}
}

// _wide_overwrite_repair blanks orphaned wide halves before a write of the
// given width at (row, col) and releases their handles:
// target is continuation -> blank col-1; target is lead -> blank col+1;
// narrow write with continuation at col+1 -> blank it; wide write with a
// lead at col+1 (continuation at col+2) -> blank col+2 (col+1 itself is
// overwritten by our continuation).
_wide_overwrite_repair :: proc(t: ^Terminal, row: int, col: int, width: u8) {
	cols := t.grid.col_count

	target := grid_get_cell(&t.grid, row, col)
	if _cell_is_continuation(target) {
		if col >= 1 {
			_terminal_blank_cell(t, row, col - 1)
		}
	} else if _cell_is_lead(target) {
		if col + 1 < cols {
			_terminal_blank_cell(t, row, col + 1)
		}
	}

	if width == 1 {
		if col + 1 < cols && _cell_is_continuation(grid_get_cell(&t.grid, row, col + 1)) {
			_terminal_blank_cell(t, row, col + 1)
		}
	} else {
		if col + 1 < cols && _cell_is_lead(grid_get_cell(&t.grid, row, col + 1)) {
			if col + 2 < cols && _cell_is_continuation(grid_get_cell(&t.grid, row, col + 2)) {
				_terminal_blank_cell(t, row, col + 2)
			}
		}
	}
}

// terminal_backspace moves the cursor left over one cell: -2 when col-1 is a
// wide continuation (landing on the lead), else -1. Col 0 is a no-op.
// Never touches the grid or the grapheme store.
terminal_backspace :: proc(t: ^Terminal) {
	if t.cursor.col == 0 {
		return
	}
	if t.cursor.col >= 2 {
		prev := grid_get_cell(&t.grid, t.cursor.row, t.cursor.col - 1)
		if _cell_is_continuation(prev) {
			t.cursor.col -= 2
			return
		}
	}
	t.cursor.col -= 1
}

// terminal_put_string writes a string at the cursor position.
// Handles newlines (\n) by calling terminal_newline.
terminal_put_string :: proc(t: ^Terminal, s: string) {
	i := 0
	for i < len(s) {
		r, size := utf8.decode_rune_in_string(s[i:])
		if size <= 0 {
			break
		}
		if r == '\n' {
			terminal_newline(t)
		} else {
			terminal_put_char(t, r)
		}
		i += size
	}
}

// terminal_move_cursor moves the cursor to the specified position.
// Clamps to grid bounds.
terminal_move_cursor :: proc(t: ^Terminal, row, col: int) {
	cursor_move(&t.cursor, row, col, t.grid.row_count, t.grid.col_count)
}

// terminal_cursor_up moves the cursor up by n rows.
terminal_cursor_up :: proc(t: ^Terminal, n: int) {
	new_row := t.cursor.row - n
	if new_row < 0 {
		new_row = 0
	}
	t.cursor.row = new_row
}

// terminal_cursor_down moves the cursor down by n rows.
terminal_cursor_down :: proc(t: ^Terminal, n: int) {
	new_row := t.cursor.row + n
	if new_row >= t.grid.row_count {
		new_row = t.grid.row_count - 1
	}
	t.cursor.row = new_row
}

// terminal_cursor_left moves the cursor left by n columns.
terminal_cursor_left :: proc(t: ^Terminal, n: int) {
	new_col := t.cursor.col - n
	if new_col < 0 {
		new_col = 0
	}
	t.cursor.col = new_col
}

// terminal_cursor_right moves the cursor right by n columns.
terminal_cursor_right :: proc(t: ^Terminal, n: int) {
	new_col := t.cursor.col + n
	if new_col >= t.grid.col_count {
		new_col = t.grid.col_count - 1
	}
	t.cursor.col = new_col
}

// terminal_set_cursor_visible sets the DECTCEM cursor visibility state.
// Called by the parser for CSI ? 25 h (show) / CSI ? 25 l (hide).
// Persists until the next DECTCEM sequence; plain output never changes it.
terminal_set_cursor_visible :: proc(t: ^Terminal, visible: bool) {
	t.cursor.visible = visible
}

// _wide_erase_repair blanks orphaned wide halves after clearing the
// inclusive range [start, end] on row: a lead at start-1 whose continuation
// was cleared, and a continuation at end+1 whose lead was cleared.
_wide_erase_repair :: proc(t: ^Terminal, row, start, end: int) {
	if start > 0 && _cell_is_lead(grid_get_cell(&t.grid, row, start - 1)) {
		_terminal_blank_cell(t, row, start - 1)
	}
	if end + 1 < t.grid.col_count && _cell_is_continuation(grid_get_cell(&t.grid, row, end + 1)) {
		_terminal_blank_cell(t, row, end + 1)
	}
}

// _terminal_release_row_handles releases every pool handle in a physical row.
// Called before row_clear-style discards so the bounded pool never leaks.
// Empty store short-circuits to O(1): pure-ASCII workloads never pay the scan.
_terminal_release_row_handles :: proc(t: ^Terminal, phys: int) {
	if t.grapheme_store.live_count == 0 {
		return
	}
	for c in 0..<len(t.grid.rows[phys].cells) {
		grapheme_store_release(&t.grapheme_store, t.grid.rows[phys].cells[c].content)
	}
}

// terminal_erase_line erases content on the current line.
// Handles of cleared cells are released; a pair split by the range edge has
// its orphan half blanked to CELL_DEFAULT. Cursor unmoved.
terminal_erase_line :: proc(t: ^Terminal, mode: Erase_Mode) {
	row := t.cursor.row
	col := t.cursor.col
	phys := _grid_physical_row(&t.grid, row)

	start, end: int
	switch mode {
	case .To_End:
		start, end = col, t.grid.col_count - 1
	case .To_Beginning:
		start, end = 0, col
	case .Entire:
		start, end = 0, t.grid.col_count - 1
	}

	for c in start..=end {
		if t.grapheme_store.live_count == 0 {
			break
		}
		grapheme_store_release(&t.grapheme_store, t.grid.rows[phys].cells[c].content)
	}

	switch mode {
	case .To_End:
		for c in col..<t.grid.col_count {
			t.grid.rows[phys].cells[c] = CELL_DEFAULT
		}
	case .To_Beginning:
		for c in 0..<(col + 1) {
			t.grid.rows[phys].cells[c] = CELL_DEFAULT
		}
	case .Entire:
		row_clear(&t.grid.rows[phys])
	}

	_wide_erase_repair(t, row, start, end)

	t.grid.rows[phys].wrapped = false
	t.grid.rows[phys].generation += 1
	gen := t.grid.rows[phys].generation
	damage_mark_row(&t.damage, row, gen)
}

// terminal_erase_display erases content on the display.
terminal_erase_display :: proc(t: ^Terminal, mode: Erase_Mode) {
	row := t.cursor.row

	switch mode {
	case .To_End:
		// Erase from cursor to end of current line
		terminal_erase_line(t, .To_End)
		// Erase all lines below
		for r in (row + 1)..<t.grid.row_count {
			phys := _grid_physical_row(&t.grid, r)
			_terminal_release_row_handles(t, phys)
			row_clear(&t.grid.rows[phys])
			damage_mark_row(&t.damage, r, t.grid.rows[phys].generation)
		}
	case .To_Beginning:
		// Erase all lines above
		for r in 0..<row {
			phys := _grid_physical_row(&t.grid, r)
			_terminal_release_row_handles(t, phys)
			row_clear(&t.grid.rows[phys])
			damage_mark_row(&t.damage, r, t.grid.rows[phys].generation)
		}
		// Erase from beginning of current line to cursor
		terminal_erase_line(t, .To_Beginning)
	case .Entire:
		// Blank every row, releasing pool handles first (mirrors
		// .To_End/.To_Beginning discipline), then mark all rows dirty.
		for i in 0..<t.grid.row_count {
			phys := _grid_physical_row(&t.grid, i)
			_terminal_release_row_handles(t, phys)
			row_clear(&t.grid.rows[phys])
		}
		gens := make([]u32, t.grid.row_count)
		for i in 0..<t.grid.row_count {
			phys := _grid_physical_row(&t.grid, i)
			gens[i] = t.grid.rows[phys].generation
		}
		damage_mark_all(&t.damage, gens)
		delete(gens)
	}
}

// terminal_save_cursor stores the current cursor position for DECSC.
terminal_save_cursor :: proc(t: ^Terminal) {
	if t == nil { return }
	t.saved_cursor = t.cursor
	t.saved_cursor_valid = true
}

// terminal_restore_cursor restores the last DECSC position when available.
terminal_restore_cursor :: proc(t: ^Terminal) {
	if t == nil || !t.saved_cursor_valid { return }
	t.cursor.row = t.saved_cursor.row
	t.cursor.col = t.saved_cursor.col
	if t.grid.row_count > 0 && t.grid.col_count > 0 {
		cursor_move(&t.cursor, t.cursor.row, t.cursor.col, t.grid.row_count, t.grid.col_count)
	}
}

// terminal_clear_scrollback erases off-screen rows without changing the
// visible cursor or grid.
terminal_clear_scrollback :: proc(t: ^Terminal) {
	if t == nil { return }
	scrollback_clear(&t.scrollback, &t.grapheme_store)
}

// terminal_reset implements RIS for the terminal state owned by this model.
terminal_reset :: proc(t: ^Terminal) {
	if t == nil { return }
	terminal_erase_display(t, .Entire)
	terminal_clear_scrollback(t)
	if t.grid.row_count > 0 && t.grid.col_count > 0 {
		t.cursor = Cursor{row = 0, col = 0, visible = true}
	}
	t.current_style = 0
	t.scroll_top = 0
	t.scroll_bottom = t.grid.row_count - 1
	t.saved_cursor_valid = false
}

// terminal_set_scroll_region sets the scroll margins (0-indexed, inclusive).
// Returns false and leaves margins unchanged when top>=bottom or out of range.
terminal_set_scroll_region :: proc(t: ^Terminal, top: int, bottom: int) -> bool {
	if top < 0 || bottom < 0 {
		return false
	}
	if top >= t.grid.row_count || bottom >= t.grid.row_count {
		return false
	}
	if top >= bottom {
		return false
	}
	t.scroll_top = top
	t.scroll_bottom = bottom
	return true
}

// terminal_reset_scroll_region restores the scroll margins to the full grid.
terminal_reset_scroll_region :: proc(t: ^Terminal) {
	t.scroll_top = 0
	t.scroll_bottom = t.grid.row_count - 1
}

// _terminal_scroll_actual mirrors _scroll_region clamping for the terminal's
// scroll margins and returns the rows that will actually scroll.
_terminal_scroll_actual :: proc(t: ^Terminal, n: int) -> int {
	top := t.scroll_top
	bottom := t.scroll_bottom
	if top < 0 {
		top = 0
	}
	if bottom >= t.grid.row_count {
		bottom = t.grid.row_count - 1
	}
	if top > bottom {
		return 0
	}
	region_size := bottom - top + 1
	actual := n
	if actual > region_size {
		actual = region_size
	}
	if actual < 0 {
		actual = 0
	}
	return actual
}

// terminal_damage_target snapshots the current validation state for a cell.
terminal_damage_target :: proc(t: ^Terminal, row, col: int) -> Damage_Target {
	target := Damage_Target{row = row, col = col, epoch = t.render_epoch}
	if row >= 0 && row < t.grid.row_count {
		physical := _grid_physical_row(&t.grid, row)
		target.row_generation = t.grid.rows[physical].generation
	}
	return target
}

// terminal_apply_damage_target validates and publishes precise cell damage.
terminal_apply_damage_target :: proc(t: ^Terminal, target: Damage_Target) -> bool {
	if target.epoch != t.render_epoch || target.row < 0 || target.row >= t.grid.row_count || target.col < 0 || target.col >= t.grid.col_count {
		return false
	}
	physical := _grid_physical_row(&t.grid, target.row)
	if t.grid.rows[physical].generation != target.row_generation {
		return false
	}
	damage_mark_cell(&t.damage, target.row, target.col, target.row_generation)
	return true
}

// terminal_scroll_up scrolls the terminal up by n rows.
// Full-grid scroll pushes each discarded top row into the scrollback
// (handle ownership transfers to the scrollback copy, so no release here);
// partial region scroll releases discarded handles and never pushes.
terminal_scroll_up :: proc(t: ^Terminal, n: int) {
	actual := _terminal_scroll_actual(t, n)
	if actual <= 0 {
		return
	}
	top := t.scroll_top
	bottom := t.scroll_bottom
	if top < 0 {
		top = 0
	}
	if bottom >= t.grid.row_count {
		bottom = t.grid.row_count - 1
	}
	if !t.is_alt_screen && top == 0 && bottom == t.grid.row_count - 1 && t.scrollback.col_count == t.grid.col_count {
		for i in 0..<actual {
			phys := _grid_physical_row(&t.grid, top + i)
			scrollback_push(&t.scrollback, t.grid.rows[phys].cells, &t.grapheme_store)
		}
	} else {
		for i in 0..<actual {
			_terminal_release_row_handles(t, _grid_physical_row(&t.grid, top + i))
		}
	}
	scroll_up(&t.grid, &t.damage, t.scroll_top, t.scroll_bottom, n)
	t.render_epoch += 1
}

// terminal_scroll_down scrolls the terminal down by n rows.
// Pool handles of the discarded bottom rows are released before the scroll.
terminal_scroll_down :: proc(t: ^Terminal, n: int) {
	actual := _terminal_scroll_actual(t, n)
	for i in 0..<actual {
		_terminal_release_row_handles(t, _grid_physical_row(&t.grid, t.scroll_bottom - actual + 1 + i))
	}
	scroll_down(&t.grid, &t.damage, t.scroll_top, t.scroll_bottom, n)
	if actual > 0 {
		t.render_epoch += 1
	}
}

// terminal_newline moves the cursor to the beginning of the next line, scrolling if needed.
terminal_newline :: proc(t: ^Terminal) {
	if t == nil || t.grid.row_count == 0 { return }
	t.grid.rows[_grid_physical_row(&t.grid, t.cursor.row)].wrapped = false
	t.cursor.col = 0
	if t.cursor.row >= t.scroll_top && t.cursor.row <= t.scroll_bottom {
		// Inside the scroll region.
		if t.cursor.row == t.scroll_bottom {
			terminal_scroll_up(t, 1)
			t.cursor.row = t.scroll_bottom
		} else {
			t.cursor.row += 1
		}
	} else {
		// Outside the scroll region: advance without scrolling.
		t.cursor.row += 1
		if t.cursor.row >= t.grid.row_count {
			t.cursor.row = t.grid.row_count - 1
		}
	}
}

// terminal_linefeed advances vertically without changing the column.
terminal_linefeed :: proc(t: ^Terminal) {
	if t == nil || t.grid.row_count == 0 { return }
	t.grid.rows[_grid_physical_row(&t.grid, t.cursor.row)].wrapped = false
	if t.cursor.row >= t.scroll_top && t.cursor.row <= t.scroll_bottom {
		if t.cursor.row == t.scroll_bottom {
			terminal_scroll_up(t, 1)
			t.cursor.row = t.scroll_bottom
		} else {
			t.cursor.row += 1
		}
	} else {
		t.cursor.row += 1
		if t.cursor.row >= t.grid.row_count {
			t.cursor.row = t.grid.row_count - 1
		}
	}
}

// terminal_set_style sets the current style for subsequent character output.
terminal_set_style :: proc(t: ^Terminal, style: Style_Id) {
	t.current_style = style
}

// terminal_get_style returns the current style.
terminal_get_style :: proc(t: ^Terminal) -> Style_Id {
	return t.current_style
}

// terminal_get_cell retrieves a cell at the specified position.
terminal_get_cell :: proc(t: ^Terminal, row, col: int) -> Semantic_Cell {
	return grid_get_cell(&t.grid, row, col)
}

// terminal_get_cursor returns the current cursor state.
terminal_get_cursor :: proc(t: ^Terminal) -> Cursor {
	return t.cursor
}

// terminal_take_damage returns a damage journal and clears the damage.
terminal_take_damage :: proc(t: ^Terminal, allocator: runtime.Allocator = context.allocator) -> Damage_Journal {
	return damage_take_journal(&t.damage, allocator)
}

// terminal_clear_damage clears all damage without returning a journal.
terminal_clear_damage :: proc(t: ^Terminal) {
	damage_clear(&t.damage)
}

// terminal_enter_alt_screen switches to the alternate screen buffer.
// Saves cursor, swaps active grid with alt_grid, clears active grid,
// resets cursor to (0, 0), marks all damage, and bumps render_epoch.
terminal_enter_alt_screen :: proc(t: ^Terminal) {
	if t == nil || t.is_alt_screen {
		return
	}
	terminal_save_cursor(t)
	t.grid, t.alt_grid = t.alt_grid, t.grid
	for i in 0..<len(t.grid.rows) {
		_terminal_release_row_handles(t, i)
	}
	grid_clear(&t.grid)
	t.cursor = Cursor{row = 0, col = 0, visible = t.cursor.visible}
	t.scroll_top = 0
	t.scroll_bottom = t.grid.row_count - 1
	t.is_alt_screen = true

	gens := make([]u32, t.grid.row_count)
	for i in 0..<t.grid.row_count {
		phys := _grid_physical_row(&t.grid, i)
		gens[i] = t.grid.rows[phys].generation
	}
	damage_mark_all(&t.damage, gens)
	delete(gens)
	t.render_epoch += 1
}

// terminal_leave_alt_screen switches back to the primary screen buffer.
// Swaps active grid with alt_grid, restores cursor, resets scroll region,
// marks all damage, and bumps render_epoch.
terminal_leave_alt_screen :: proc(t: ^Terminal) {
	if t == nil || !t.is_alt_screen {
		return
	}
	t.grid, t.alt_grid = t.alt_grid, t.grid
	t.is_alt_screen = false
	terminal_restore_cursor(t)
	t.scroll_top = 0
	t.scroll_bottom = t.grid.row_count - 1

	gens := make([]u32, t.grid.row_count)
	for i in 0..<t.grid.row_count {
		phys := _grid_physical_row(&t.grid, i)
		gens[i] = t.grid.rows[phys].generation
	}
	damage_mark_all(&t.damage, gens)
	delete(gens)
	t.render_epoch += 1
}

// terminal_erase_chars erases n cells starting at the cursor column on the cursor row.
// Cells are reset to CELL_DEFAULT and any grapheme handles released. Cursor does not move.
terminal_erase_chars :: proc(t: ^Terminal, n: int) {
	if t == nil || n <= 0 || t.grid.row_count == 0 || t.grid.col_count == 0 {
		return
	}
	row := t.cursor.row
	col := t.cursor.col
	if row < 0 || row >= t.grid.row_count || col < 0 || col >= t.grid.col_count {
		return
	}
	actual := min(n, t.grid.col_count - col)
	if actual <= 0 {
		return
	}

	phys := _grid_physical_row(&t.grid, row)
	if t.grapheme_store.live_count > 0 {
		for c in col..<(col + actual) {
			grapheme_store_release(&t.grapheme_store, t.grid.rows[phys].cells[c].content)
		}
	}
	for c in col..<(col + actual) {
		t.grid.rows[phys].cells[c] = CELL_DEFAULT
	}
	_wide_erase_repair(t, row, col, col + actual - 1)

	t.grid.rows[phys].generation += 1
	gen := t.grid.rows[phys].generation
	damage_mark_span(&t.damage, row, col, col + actual - 1, gen)
}

// terminal_insert_lines inserts n blank lines at the cursor row within the scroll region.
terminal_insert_lines :: proc(t: ^Terminal, n: int) {
	if t == nil || n <= 0 { return }
	if t.cursor.row < t.scroll_top || t.cursor.row > t.scroll_bottom { return }
	region_size := t.scroll_bottom - t.cursor.row + 1
	actual := min(n, region_size)
	for i in 0..<actual {
		_terminal_release_row_handles(t, _grid_physical_row(&t.grid, t.scroll_bottom - actual + 1 + i))
	}
	scroll_down(&t.grid, &t.damage, t.cursor.row, t.scroll_bottom, n)
	t.cursor.col = 0
	t.render_epoch += 1
}

// terminal_delete_lines deletes n lines at the cursor row within the scroll region.
terminal_delete_lines :: proc(t: ^Terminal, n: int) {
	if t == nil || n <= 0 { return }
	if t.cursor.row < t.scroll_top || t.cursor.row > t.scroll_bottom { return }
	region_size := t.scroll_bottom - t.cursor.row + 1
	actual := min(n, region_size)
	for i in 0..<actual {
		_terminal_release_row_handles(t, _grid_physical_row(&t.grid, t.cursor.row + i))
	}
	scroll_up(&t.grid, &t.damage, t.cursor.row, t.scroll_bottom, n)
	t.cursor.col = 0
	t.render_epoch += 1
}

// terminal_reverse_index moves cursor up, or scrolls down if at the top scroll margin.
terminal_reverse_index :: proc(t: ^Terminal) {
	if t == nil { return }
	if t.cursor.row == t.scroll_top {
		terminal_scroll_down(t, 1)
	} else {
		terminal_cursor_up(t, 1)
	}
}

// terminal_index moves cursor down, or scrolls up if at the bottom scroll margin.
terminal_index :: proc(t: ^Terminal) {
	if t == nil { return }
	if t.cursor.row == t.scroll_bottom {
		terminal_scroll_up(t, 1)
	} else {
		terminal_cursor_down(t, 1)
	}
}

// terminal_next_line moves cursor to beginning of next line, scrolling if at bottom margin.
terminal_next_line :: proc(t: ^Terminal) {
	if t == nil { return }
	t.cursor.col = 0
	if t.cursor.row == t.scroll_bottom {
		terminal_scroll_up(t, 1)
	} else {
		terminal_cursor_down(t, 1)
	}
}

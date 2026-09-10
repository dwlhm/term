package termgrid

// Cursor represents the cursor position and state.
Cursor :: struct {
	row:     int,
	col:     int,
	visible: bool,
}

// cursor_init initializes the cursor at position (0, 0).
cursor_init :: proc(c: ^Cursor) {
	c.row = 0
	c.col = 0
	c.visible = true
}

// cursor_move moves the cursor to the specified position.
// Clamps to grid bounds.
cursor_move :: proc(c: ^Cursor, row, col, row_count, col_count: int) {
	r := row
	co := col
	if r < 0 {
		r = 0
	}
	if r >= row_count {
		r = row_count - 1
	}
	if co < 0 {
		co = 0
	}
	if co >= col_count {
		co = col_count - 1
	}
	c.row = r
	c.col = co
}

// cursor_advance advances the cursor after writing a character.
// Handles wrapping and scrolling.
// scroll_needed is set to true if the cursor needs to scroll the terminal.
cursor_advance :: proc(c: ^Cursor, width: int, row_count, col_count: int, scroll_needed: ^bool) {
	scroll_needed^ = false

	c.col += width
	if c.col >= col_count {
		c.col = 0
		c.row += 1
		if c.row >= row_count {
			c.row = row_count - 1
			scroll_needed^ = true
		}
	}
}

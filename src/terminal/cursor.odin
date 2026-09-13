package termgrid

// Cursor represents the cursor position and state.
Cursor :: struct {
	row:          int,
	col:          int,
	visible:      bool,
	pending_wrap: bool, // xenl: cursor at last col, wrap deferred until next char
	style:        u8,   // DECSCUSR: 0=default, 2=block, 4=underline, 6=bar (odd=blink)
}

// cursor_init initializes the cursor at position (0, 0).
cursor_init :: proc(c: ^Cursor) {
	c.row = 0
	c.col = 0
	c.visible = true
	c.pending_wrap = false
	c.style = 0 // default
}

// cursor_move moves the cursor to the specified position.
// Clamps to grid bounds. Clears pending_wrap (explicit movement cancels
// deferred wrap per xenl semantics).
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
	c.pending_wrap = false
}

// cursor_advance advances the cursor after writing a character.
// Implements xenl (extended newline / deferred wrap): when the cursor reaches
// the last column, it stays there with pending_wrap=true. The actual wrap to
// the next line happens when the next character is printed (checked by the
// caller in terminal_put_char). This matches xterm/ghostty/kitty behavior and
// is required for fish shell autosuggestion rendering.
// scroll_needed is set to true if the cursor needs to scroll the terminal.
cursor_advance :: proc(c: ^Cursor, width: int, row_count, col_count: int, scroll_needed: ^bool) {
	scroll_needed^ = false

	c.col += width
	if c.col >= col_count {
		// xenl: defer the wrap. Stay at last column, mark pending.
		// The actual line advance happens in terminal_put_char before
		// writing the next character.
		c.col = col_count - 1
		c.pending_wrap = true
	}
}

// cursor_apply_pending_wrap performs the deferred line advance if pending_wrap
// is set. Called by terminal_put_char before writing a character. Returns true
// if a scroll is needed (cursor was at bottom row). Clears pending_wrap.
cursor_apply_pending_wrap :: proc(c: ^Cursor, row_count: int) -> (scroll_needed: bool) {
	scroll_needed = false
	if !c.pending_wrap {
		return false
	}
	c.pending_wrap = false
	c.col = 0
	c.row += 1
	if c.row >= row_count {
		c.row = row_count - 1
		scroll_needed = true
	}
	return scroll_needed
}

// cursor_clear_pending_wrap clears the pending wrap flag without advancing.
// Called by cursor movement operations (CUU, CUD, CUF, CUB, CUP, etc.) and
// by terminal_restore_cursor, terminal_backspace, terminal_newline.
cursor_clear_pending_wrap :: proc(c: ^Cursor) {
	c.pending_wrap = false
}

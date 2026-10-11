package termgrid_test

import "core:testing"
import tg "../"

// --- DECTCEM terminal-level Tests ---

@(test)
test_terminal_set_cursor_visible :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.cursor.visible, "Cursor should start visible")

	tg.terminal_set_cursor_visible(&term, false)
	testing.expect(t, !term.cursor.visible, "set_cursor_visible(false) should hide")

	tg.terminal_set_cursor_visible(&term, true)
	testing.expect(t, term.cursor.visible, "set_cursor_visible(true) should show")
}

@(test)
test_terminal_set_cursor_visible_idempotent :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_set_cursor_visible(&term, false)
	tg.terminal_set_cursor_visible(&term, false)
	testing.expect(t, !term.cursor.visible, "Repeated hide should stay hidden")

	tg.terminal_set_cursor_visible(&term, true)
	tg.terminal_set_cursor_visible(&term, true)
	testing.expect(t, term.cursor.visible, "Repeated show should stay visible")
}

@(test)
test_terminal_cursor_visible_persists_across_output :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_set_cursor_visible(&term, false)
	tg.terminal_put_string(&term, "hello")
	testing.expect(t, !term.cursor.visible, "Visibility should survive plain output")

	tg.terminal_move_cursor(&term, 5, 5)
	tg.terminal_erase_line(&term, .To_End)
	testing.expect(t, !term.cursor.visible, "Visibility should survive cursor ops and erase")
}

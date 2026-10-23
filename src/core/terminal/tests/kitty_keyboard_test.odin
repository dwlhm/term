package terminal_tests

// Regression tests for the Kitty keyboard protocol flag stack (CSI > u / < u /
// = u / ? u), which the input encoder relies on.

import "core:testing"
import term "../"

@test
test_kitty_keyboard_flag_stack :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), 0)

	term.terminal_feed_string(&terminal, "\x1b[>1u")
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(1))

	// Nested application pushes a different set without losing the outer one.
	term.terminal_feed_string(&terminal, "\x1b[>27u")
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(27))

	term.terminal_feed_string(&terminal, "\x1b[<u") // pop one (default 1)
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(1))

	term.terminal_feed_string(&terminal, "\x1b[<u")
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(0))

	// Popping an empty stack is a no-op, never underflows.
	term.terminal_feed_string(&terminal, "\x1b[<3u")
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(0))
}

@test
test_kitty_keyboard_set_modes :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[=1u") // set
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(1))

	term.terminal_feed_string(&terminal, "\x1b[=2;2u") // or
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(3))

	term.terminal_feed_string(&terminal, "\x1b[=1;3u") // and-not
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(2))

	term.terminal_feed_string(&terminal, "\x1b[=8;1u") // replace
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(8))
}

@test
test_kitty_keyboard_query_response :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	buf: [32]u8
	term.terminal_feed_string(&terminal, "\x1b[?u")
	n := term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?0 u")

	term.terminal_feed_string(&terminal, "\x1b[>5u\x1b[?u")
	n = term.terminal_drain_response(&terminal, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b[?5 u")
}

@test
test_kitty_keyboard_does_not_break_cursor_restore :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	// Unprefixed CSI u must keep its legacy meaning (restore cursor position).
	term.terminal_feed_string(&terminal, "AB\x1b[1;2H\x1b[s\x1b[3;3H\x1b[u")
	row, col := term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 1)
	testing.expect_value(t, term.terminal_kitty_keyboard_flags(&terminal), u8(0))
}

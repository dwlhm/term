package feature_interaction_tests

// Regression tests for in-terminal search (Cmd+F): visible grid, scrollback,
// case-insensitive matching, wraparound and UTF-8 queries.

import "core:fmt"
import "core:testing"
import term "../../../core/terminal"
import feature "../"

// The Terminal stores self-referential pointers (parser.user_data), so it must be
// initialised at its final address and never returned by value.
_search_init :: proc(terminal: ^term.Terminal, rows, cols: int) {
	term.terminal_init(terminal, rows, cols)
}

@test
test_search_visible_grid :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "alpha\r\nbravo charlie\r\ndelta")
	match := feature.search_find(&terminal, "charlie", 0, 0, true)
	testing.expect(t, match.found, "visible text must be found")
	testing.expect_value(t, match.row, 1)
	testing.expect_value(t, match.col_start, 6)
	testing.expect_value(t, match.col_end, 12)
}

@test
test_search_is_case_insensitive :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "MiXeD CaSe")
	match := feature.search_find(&terminal, "mixed case", 0, 0, true)
	testing.expect(t, match.found)
	testing.expect_value(t, match.col_start, 0)
}

@test
test_search_wraps_around_buffer :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 4, 30)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "needle\r\nfiller\r\nfiller\r\nfiller")
	// Start searching from the last row; the match is on row 0, so it must wrap.
	match := feature.search_find(&terminal, "needle", 3, 0, true)
	testing.expect(t, match.found, "forward search must wrap to the top")
	testing.expect_value(t, match.row, 0)
}

@test
test_search_backward_direction :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 4, 30)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "first\r\nsecond\r\nthird")
	match := feature.search_find(&terminal, "second", 2, 0, false)
	testing.expect(t, match.found, "backward search must find earlier rows")
	testing.expect_value(t, match.row, 1)
}

@test
test_search_scrollback_rows :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 4, 30)
	defer term.terminal_destroy(&terminal)

	for i in 0..<12 {
		line := fmt.tprintf("log entry-%02d\r\n", i)
		term.terminal_feed_string(&terminal, line)
	}
	testing.expect(t, term.terminal_history_count(&terminal) > 0, "test setup needs scrollback")

	match := feature.search_find(&terminal, "entry-01", 0, 0, true)
	testing.expect(t, match.found, "history rows must be searchable")
	testing.expect(t, match.row < 0, "the hit must be reported as a scrollback row")
}

@test
test_search_missing_needle :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 4, 30)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "nothing to see")
	match := feature.search_find(&terminal, "absent", 0, 0, true)
	testing.expect(t, !match.found)
}

@test
test_search_utf8_needle :: proc(t: ^testing.T) {
	terminal: term.Terminal
	_search_init(&terminal, 4, 30)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "kotak ┌───┐ uji")
	match := feature.search_find(&terminal, "┌───┐", 0, 0, true)
	testing.expect(t, match.found, "multi-byte needles must match box drawing")
	testing.expect_value(t, match.col_start, 6)
	testing.expect_value(t, match.col_end, 10)
}

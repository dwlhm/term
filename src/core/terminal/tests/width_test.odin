package terminal_tests

import "core:testing"
import term "../"

@test
test_parser_text_default_symbol_cursor :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	// Same line Claude Code draws: every symbol occupies exactly one column.
	term.terminal_feed_string(&terminal, "⏺X|✔X|➡X|▶X|⏵X")
	testing.expect_value(t, terminal.parser.cursor.col, 14)

	// VS16 still upgrades a text-default symbol to a wide emoji cluster.
	term.terminal_feed_string(&terminal, "\r\n⏺️X")
	testing.expect_value(t, terminal.parser.cursor.col, 3)
}

@test
test_parser_grapheme_cluster_columns :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		cols: int,
	}
	cases := []Case{
		{"🖥️", 2},               // text-default pictograph + VS16
		{"🏳️‍🌈", 2},       // ZWJ joins after a text-default pictograph (GB11)
		{"🕵🏻", 2},                    // skin tone attaches to a text-default pictograph
		{"©️", 2},                // © is Extended_Pictographic
		{"→️", 1},                // arrows are not emoji: VS16 does not widen
		{"■️", 1},
		{"กั", 1},                // Thai nonspacing mark is zero-width
		{"का", 2},                // Devanagari spacing mark keeps its own column (glibc)
		{"a⁠b", 2},               // word joiner is invisible
	}
	for c in cases {
		terminal: term.Terminal
		term.terminal_init(&terminal, 2, 20)
		term.terminal_feed_string(&terminal, c.text)
		testing.expectf(t, terminal.parser.cursor.col == c.cols, "%q: expected %d cols, got %d", c.text, c.cols, terminal.parser.cursor.col)
		term.terminal_destroy(&terminal)
	}
}

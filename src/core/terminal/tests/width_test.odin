package terminal_tests

import "core:testing"
import term "../"
import cell "../cell"

// Emoji=Yes symbols without Emoji_Presentation (⏺ ✔ ➡ ▶ ⏵) are narrow text by
// default; only Emoji_Presentation=Yes codepoints are wide color emoji.
@test
test_wcwidth_emoji_presentation :: proc(t: ^testing.T) {
	narrow := []rune{0x23FA, 0x23F5, 0x2714, 0x27A1, 0x25B6, 0x2764, 0x1F321, 0x1F000, 0x1FBB2}
	for r in narrow {
		testing.expectf(t, cell.wcwidth(r) == 1, "U+%04X must be narrow", r)
		testing.expectf(t, !cell.is_emoji_codepoint(r), "U+%04X must default to text presentation", r)
	}
	wide := []rune{0x23E9, 0x23F0, 0x2705, 0x2728, 0x2B50, 0x1F004, 0x1F600, 0x1F44D, 0x1FAF8, 0x1F3FB, 0x1F1E6}
	for r in wide {
		testing.expectf(t, cell.wcwidth(r) == 2, "U+%04X must be wide", r)
		testing.expectf(t, cell.is_emoji_codepoint(r), "U+%04X must default to emoji presentation", r)
	}
	testing.expect_value(t, cell.wcwidth(0x1F210), 2) // EAW=Wide ideograph, not emoji
	testing.expect(t, !cell.is_emoji_codepoint(0x1F210), "U+1F210 is not emoji presentation")
}

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

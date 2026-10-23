package terminal_tests

// Regression tests for OSC 8 hyperlinks: URI table, per-cell link storage and
// the clearing semantics of an empty URI.

import "core:fmt"
import "core:testing"
import term "../"


@test
test_osc8_links_cells_until_cleared :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 60)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/a\x1b\\LINKED")
	linked := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Hyperlink in linked.flags, "cells written while a link is active must be tagged")

	link_id, uri := term.terminal_cell_hyperlink(&terminal, 0, 0)
	testing.expect(t, link_id != 0, "link id must be stored beside the cell")
	testing.expect_value(t, uri, "https://example.com/a")

	// An empty URI terminates the hyperlink.
	term.terminal_feed_string(&terminal, "\x1b]8;;\x1b\\plain")
	plain := term.terminal_get_cell(&terminal, 0, 6)
	testing.expect(t, .Has_Hyperlink not_in plain.flags, "cells after the terminator must be plain")
	_, no_uri := term.terminal_cell_hyperlink(&terminal, 0, 6)
	testing.expect_value(t, no_uri, "")
}

@test
test_osc8_keeps_distinct_links_and_reuses_ids :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 120)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/one\x1b\\AA")
	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/two\x1b\\BB")
	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/one\x1b\\CC")

	id_a, uri_a := term.terminal_cell_hyperlink(&terminal, 0, 0)
	id_b, uri_b := term.terminal_cell_hyperlink(&terminal, 0, 2)
	id_c, uri_c := term.terminal_cell_hyperlink(&terminal, 0, 4)
	testing.expect_value(t, uri_a, "https://example.com/one")
	testing.expect_value(t, uri_b, "https://example.com/two")
	testing.expect_value(t, uri_c, "https://example.com/one")
	testing.expect_value(t, id_c, id_a)
	testing.expect(t, id_a != id_b, "different URIs must not share an id")
}

@test
test_osc8_link_survives_sgr_reset :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 60)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com\x1b\\\x1b[0mX")
	c := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Hyperlink in c.flags, "SGR 0 must not clear the active hyperlink")
	_, uri := term.terminal_cell_hyperlink(&terminal, 0, 0)
	testing.expect_value(t, uri, "https://example.com")
}

@test
test_osc8_wide_glyph_carries_link_on_both_halves :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 60)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/wide\x1b\\\u4f60\x1b]8;;\x1b\\")
	lead := term.terminal_get_cell(&terminal, 0, 0)
	cont := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect(t, .Wide_Lead in lead.flags)
	testing.expect(t, .Wide_Continuation in cont.flags)
	testing.expect(t, .Has_Hyperlink in lead.flags)
	testing.expect(t, .Has_Hyperlink in cont.flags, "the continuation half must keep the link for hit testing")
}

_osc8_link_range_ok :: proc(uri: string) -> bool {
	return len(uri) > 0 && len(uri) < 512
}

@test
test_osc8_table_overflow_is_bounded :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 60)
	defer term.terminal_destroy(&terminal)

	// More distinct URIs than the table holds. Ids are never recycled, so links
	// already stored on cells must keep resolving to their original URI.
	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/first\x1b\\A")
	for i in 0..<80 {
		sequence := fmt.tprintf("\x1b]8;;https://example.com/%d\x1b\\", i)
		term.terminal_feed_string(&terminal, sequence)
	}
	term.terminal_feed_string(&terminal, "X")

	_, first_uri := term.terminal_cell_hyperlink(&terminal, 0, 0)
	testing.expect_value(t, first_uri, "https://example.com/first")

	_, overflow_uri := term.terminal_cell_hyperlink(&terminal, 0, 1)
	testing.expect_value(t, overflow_uri, "")
}

@test
test_osc8_hyperlink_span_crosses_spaces :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 2, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b]8;;https://example.com/x\x1b\\click here now\x1b]8;;\x1b\\")

	// Spaces inside the link keep the id (used for hit testing + underline).
	_, uri_space := term.terminal_cell_hyperlink(&terminal, 0, 5)
	testing.expect_value(t, uri_space, "https://example.com/x")

	// The span starting at an inner cell expands across the spaces to the run.
	col_start, col_end, ok := term.terminal_hyperlink_span(&terminal, 0, 7)
	testing.expect(t, ok, "span must resolve a link")
	testing.expect_value(t, col_start, 0)
	testing.expect_value(t, col_end, 13)
}

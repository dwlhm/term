package terminal_tests

import "core:testing"
import terminal "../"

@ (test)
test_ecma48_hpa_hpr_vpr_movement :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 10, 20)
	defer terminal.terminal_destroy(&term)

	// 1. HPA (CSI Ps `) - Horizontal Position Absolute (1-indexed)
	// Default (omitted) moves to col 0 (1-based col 1)
	terminal.terminal_feed_string(&term, "\x1b[1;5H\x1b[`")
	r, c := terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 0)
	testing.expect_value(t, c, 0)

	// Explicit col 12 (1-indexed -> 0-indexed 11)
	terminal.terminal_feed_string(&term, "\x1b[12`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 11)

	// Ps == 0 defaults to col 1 (0-indexed 0)
	terminal.terminal_feed_string(&term, "\x1b[0`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 0)

	// Clamped to screen right margin (col 19)
	terminal.terminal_feed_string(&term, "\x1b[99`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 19)

	// 2. HPR (CSI Ps a) - Horizontal Position Relative
	// Home cursor to (0, 0)
	terminal.terminal_feed_string(&term, "\x1b[1;1H")
	// Omitted Ps defaults to 1
	terminal.terminal_feed_string(&term, "\x1b[a")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 1)

	// Move forward by 4
	terminal.terminal_feed_string(&term, "\x1b[4a")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 5)

	// Ps == 0 defaults to 1
	terminal.terminal_feed_string(&term, "\x1b[0a")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 6)

	// Clamping at right edge
	terminal.terminal_feed_string(&term, "\x1b[50a")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 19)

	// 3. VPR (CSI Ps e) - Vertical Position Relative
	terminal.terminal_feed_string(&term, "\x1b[1;1H")
	// Omitted Ps defaults to 1
	terminal.terminal_feed_string(&term, "\x1b[e")
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 1)

	// Move down by 3
	terminal.terminal_feed_string(&term, "\x1b[3e")
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 4)

	// Ps == 0 defaults to 1
	terminal.terminal_feed_string(&term, "\x1b[0e")
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 5)

	// Clamping at bottom edge
	terminal.terminal_feed_string(&term, "\x1b[50e")
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 9)
}

@ (test)
test_ecma48_hpa_hpr_vpr_with_margins_and_decom :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 10, 20)
	defer terminal.terminal_destroy(&term)

	// Set vertical margins: rows 3..7 (1-based -> 2..6 0-based)
	// Set horizontal margins: cols 4..12 (1-based -> 3..11 0-based)
	// Enable DECOM (?6)
	terminal.terminal_feed_string(&term, "\x1b[?69h\x1b[3;7r\x1b[4;12s\x1b[?6h")

	// DECOM homes cursor to margin top-left (2, 3)
	r, c := terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 2)
	testing.expect_value(t, c, 3)

	// HPA (CSI Ps `): in DECOM, relative to left margin (eff_left = 3)
	// Col 1 in region -> col 3
	terminal.terminal_feed_string(&term, "\x1b[1`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 3)

	// Col 5 in region -> col 3 + 5 - 1 = 7
	terminal.terminal_feed_string(&term, "\x1b[5`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 7)

	// Clamping to right margin (col 11)
	terminal.terminal_feed_string(&term, "\x1b[99`")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 11)

	// HPR (CSI Ps a): relative forward within margins
	terminal.terminal_feed_string(&term, "\x1b[1`") // back to col 3
	terminal.terminal_feed_string(&term, "\x1b[2a")
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 5)

	terminal.terminal_feed_string(&term, "\x1b[20a") // clamped to eff_right (11)
	_, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, c, 11)

	// VPR (CSI Ps e): relative down within margins
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 2)

	terminal.terminal_feed_string(&term, "\x1b[2e")
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 4)

	terminal.terminal_feed_string(&term, "\x1b[20e") // clamped to scroll_bottom (6)
	r, _ = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 6)
}

@ (test)
test_cpr_and_decxcpr_normal_and_origin_mode :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 10, 20)
	defer terminal.terminal_destroy(&term)

	resp: [64]u8

	// 1. Normal mode (DECOM off)
	terminal.terminal_feed_string(&term, "\x1b[4;8H") // Move to row 3, col 7 (0-based)
	terminal.terminal_feed_string(&term, "\x1b[6n")   // Standard CPR
	n := terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[4;8R")

	terminal.terminal_feed_string(&term, "\x1b[?6n")  // DECXCPR
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?4;8;1R")

	// 2. Set margins: rows 3..8 (1-based -> 2..7 0-based), cols 5..15 (1-based -> 4..14 0-based)
	// Enable DECOM (?6)
	terminal.terminal_feed_string(&term, "\x1b[?69h\x1b[3;8r\x1b[5;15s\x1b[?6h")

	// DECOM homes cursor to margin origin (row 2, col 4).
	// In DECOM, CPR should report row 1, col 1!
	terminal.terminal_feed_string(&term, "\x1b[6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[1;1R")

	terminal.terminal_feed_string(&term, "\x1b[?6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?1;1;1R")

	// Move cursor inside region to line 3, col 6 (relative to margin!)
	// 0-based physical coords: row = 2 + 3 - 1 = 4, col = 4 + 6 - 1 = 9
	terminal.terminal_feed_string(&term, "\x1b[3;6H")
	r, c := terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 4)
	testing.expect_value(t, c, 9)

	// CPR & DECXCPR must report origin-relative (3;6)
	terminal.terminal_feed_string(&term, "\x1b[6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[3;6R")

	terminal.terminal_feed_string(&term, "\x1b[?6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?3;6;1R")

	// 3. Reset DECOM (?6l): cursor is homed to (0, 0), reports absolute (1;1)
	terminal.terminal_feed_string(&term, "\x1b[?6l\x1b[4;9H")
	terminal.terminal_feed_string(&term, "\x1b[6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[4;9R")

	terminal.terminal_feed_string(&term, "\x1b[?6n")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?4;9;1R")
}

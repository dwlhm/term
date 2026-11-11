package terminal_tests

import "core:testing"
import terminal "../"
import cell "../cell"
import grid "../grid"

// _vt420_row_str extracts ASCII characters from `row` across `[0..<cols]`.
@(private = "file")
_vt420_row_str :: proc(term: ^terminal.Terminal, row: int, buf: []u8) -> string {
	cols := min(term.cols, len(buf))
	for c in 0 ..< cols {
		ch := terminal.terminal_get_cell(term, row, c).char
		buf[c] = u8(ch) if (ch >= 0x20 && ch <= 0x7E) else ' '
	}
	return string(buf[:cols])
}

@(test)
test_vt420_declrmm_and_decslrm_lifecycle :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 5, 10)
	defer terminal.terminal_destroy(&term)

	// 1. Default ?69 is reset (2); CSI s saves cursor (SCOSC) when ?69 is off.
	terminal.terminal_feed_string(&term, "\x1b[?69$p")
	resp: [32]u8
	n := terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?69;2$y")

	terminal.terminal_feed_string(&term, "\x1b[3;4H\x1b[s\x1b[1;1H\x1b[u")
	r, c := terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 2)
	testing.expect_value(t, c, 3)

	// 2. Enable ?69: DECRQM reports 1; CSI 3;8 s sets left=2, right=7 and homes cursor.
	terminal.terminal_feed_string(&term, "\x1b[?69h\x1b[?69$p\x1b[3;8s")
	n = terminal.terminal_drain_response(&term, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?69;1$y")
	r, c = terminal.terminal_cursor_pos(&term)
	testing.expect_value(t, r, 0)
	testing.expect_value(t, c, 0)
	testing.expect_value(t, term.parser.scroll_left, 2)
	testing.expect_value(t, term.parser.scroll_right, 7)

	// 3. Resetting ?69 restores full width margins (0..9).
	terminal.terminal_feed_string(&term, "\x1b[?69l")
	testing.expect_value(t, term.parser.declrmm, false)
	testing.expect_value(t, term.parser.scroll_left, 0)
	testing.expect_value(t, term.parser.scroll_right, 9)
}

@(test)
test_vt420_subregion_scroll_and_autowrap :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 4, 10)
	defer terminal.terminal_destroy(&term)

	// Fill 4 rows with static border columns outside [2..6] (1-based 3..7).
	terminal.terminal_feed_string(&term, "0123456789\r\nABCDEFGHIJ\r\nabcdefghij\r\n!@#$%^&*()")
	// Lock margins to rows 2..3 (1-based), cols 3..7 (1-based) + Origin Mode (?6).
	terminal.terminal_feed_string(&term, "\x1b[?69h\x1b[2;3r\x1b[3;7s\x1b[?6h")

	// Write 10 chars inside the 5-col×2-row box: wraps at col 7 -> col 3, then scrolls box up!
	terminal.terminal_feed_string(&term, "XXXXXYYYYYZZZZZ")

	buf: [10]u8
	// Row 0 and Row 3 (outside top/bottom margins) untouched; cols 0..1 and 7..9 untouched!
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), "0123456789")
	testing.expect_value(t, _vt420_row_str(&term, 1, buf[:]), "ABYYYYYHIJ")
	testing.expect_value(t, _vt420_row_str(&term, 2, buf[:]), "abZZZZZhij")
	testing.expect_value(t, _vt420_row_str(&term, 3, buf[:]), "!@#$%^&*()")
}

@(test)
test_vt420_ich_dch_and_cursor_clamping :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 3, 10)
	defer terminal.terminal_destroy(&term)

	terminal.terminal_feed_string(&term, "0123456789")
	// Set horizontal margins to cols 3..8 (0-based 2..7).
	terminal.terminal_feed_string(&term, "\x1b[?69h\x1b[3;8s")

	// DCH outside margins (col 0) is a no-op.
	terminal.terminal_feed_string(&term, "\x1b[1;1H\x1b[2P")
	buf: [10]u8
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), "0123456789")

	// Move inside margins (col 4, 0-based 3), insert 2 blanks (ICH), then delete 1 (DCH).
	terminal.terminal_feed_string(&term, "\x1b[1;4H\x1b[2@")
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), "012  34589")
	terminal.terminal_feed_string(&term, "\x1b[1P")
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), "012 345 89")
}

@(test)
test_vt420_decfra_decera_decsera :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 4, 8)
	defer terminal.terminal_destroy(&term)

	// DECFRA: fill rows 1..3, cols 2..7 with '#' (35) and bold style.
	terminal.terminal_feed_string(&term, "\x1b[1;31m\x1b[35;1;2;3;7$x")
	buf: [8]u8
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), " ###### ")
	testing.expect_value(t, _vt420_row_str(&term, 1, buf[:]), " ###### ")
	testing.expect_value(t, _vt420_row_str(&term, 2, buf[:]), " ###### ")
	testing.expect(t, .Bold in terminal.terminal_get_cell(&term, 1, 3).style)

	// DECSERA: selective erase rows 2..2, cols 3..4 -> spaces, but keeps Bold & fg!
	terminal.terminal_feed_string(&term, "\x1b[2;3;2;4${")
	testing.expect_value(t, _vt420_row_str(&term, 1, buf[:]), " #  ### ")
	testing.expect(t, .Bold in terminal.terminal_get_cell(&term, 1, 2).style)
	testing.expect_value(t, terminal.terminal_get_cell(&term, 1, 2).fg, 1)

	// DECERA: full erase rows 2..2, cols 5..6 -> spaces, resets style!
	terminal.terminal_feed_string(&term, "\x1b[0m\x1b[2;5;2;6$z")
	testing.expect_value(t, _vt420_row_str(&term, 1, buf[:]), " #    # ")
	testing.expect(t, .Bold not_in terminal.terminal_get_cell(&term, 1, 4).style)
}

@(test)
test_vt420_deccra_overlap_and_wide_sanitization :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 4, 8)
	defer terminal.terminal_destroy(&term)

	terminal.terminal_feed_string(&term, "ABCD1234\r\nEFGH5678")
	// Overlapping copy within row 1..2, cols 1..4 -> dst (1, 3).
	terminal.terminal_feed_string(&term, "\x1b[1;1;2;4;1;1;3;1$v")
	buf: [8]u8
	testing.expect_value(t, _vt420_row_str(&term, 0, buf[:]), "ABABCD34")
	testing.expect_value(t, _vt420_row_str(&term, 1, buf[:]), "EFEFGH78")

	// Wide glyph boundary sanitization: write CJK '中' at cols 2..3 (1-based 3..4) on row 3,
	// then DECERA col 4 (1-based) only -> must sanitize the severed Wide_Lead at col 3!
	terminal.terminal_feed_string(&term, "\x1b[3;3H中\x1b[3;4;3;4$z")
	c_lead := terminal.terminal_get_cell(&term, 2, 2)
	testing.expect_value(t, c_lead.char, ' ')
	testing.expect(t, .Wide_Lead not_in c_lead.flags)
}

@(test)
test_vt420_paint_roundtrip :: proc(t: ^testing.T) {
	src, dst: terminal.Terminal
	terminal.terminal_init(&src, 5, 12)
	terminal.terminal_init(&dst, 5, 12)
	defer terminal.terminal_destroy(&src)
	defer terminal.terminal_destroy(&dst)

	terminal.terminal_feed_string(&src, "\x1b[?69h\x1b[2;4r\x1b[3;10s\x1b[?6hHello")
	out: [dynamic]u8
	defer delete(out)
	terminal.terminal_paint(&src, &out, 0)
	terminal.terminal_feed_bytes(&dst, out[:])

	testing.expect_value(t, dst.parser.declrmm, true)
	testing.expect_value(t, dst.parser.scroll_left, 2)
	testing.expect_value(t, dst.parser.scroll_right, 9)
	testing.expect_value(t, dst.parser.scroll_top, 1)
	testing.expect_value(t, dst.parser.scroll_bottom, 3)
	sr, sc := terminal.terminal_cursor_pos(&src)
	dr, dc := terminal.terminal_cursor_pos(&dst)
	testing.expect_value(t, dr, sr)
	testing.expect_value(t, dc, sc)
}

@(test)
test_osc_7502_interrupted_escape_does_not_leak :: proc(t: ^testing.T) {
	term: terminal.Terminal
	terminal.terminal_init(&term, 10, 80)
	defer terminal.terminal_destroy(&term)

	// Create split surface 10, then simulate an incomplete ESC or CSI right before OSC 7502;1;0
	terminal.terminal_feed_string(&term, "\x1b]7502;2;10;dir=right;ratio=40\x07")
	terminal.terminal_feed_string(&term, "\x1b]7502;1;10\x07OK\x1b\x1b]7502;1;0\x07")
	terminal.terminal_feed_string(&term, "\x1b]7502;1;10\x07!\x1b[3\x1b]7502;1;0\x07")

	testing.expect_value(t, term.active_surface_id, u16(0))
	s10 := terminal.terminal_surface_find(&term, 10)
	testing.expect(t, s10 != nil, "surface 10 should exist")
	if s10 != nil {
		testing.expect_value(t, grid.grid_get_cell(&s10.grid, 0, 0).char, 'O')
		testing.expect_value(t, grid.grid_get_cell(&s10.grid, 0, 1).char, 'K')
		testing.expect_value(t, grid.grid_get_cell(&s10.grid, 0, 2).char, '!')
		testing.expect_value(t, grid.grid_get_cell(&s10.grid, 0, 3).char, ' ')
	}
}

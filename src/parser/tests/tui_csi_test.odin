package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// Helper to check cell rune on active grid
_cell_rune :: proc(term: ^tg.Terminal, row, col: int) -> rune {
	cell := tg.grid_get_cell(&term.grid, row, col)
	return rune(cell.content)
}

// 1. Test CHA ('G') and VPA ('d') cursor movements, plus HPR ('a'), VPR ('e'), HVP ('f')
@(test)
test_tui_cha_vpa_cursor_movement :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Move cursor to (5, 10) via CUP
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '6', ';', '1', '1', 'H'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 10)

	// CHA 20: 1-indexed column 20 -> 0-indexed column 19; row unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', '0', 'G'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 19)

	// CHA bare (default 1): column becomes 0; row unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'G'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 0)

	// CHA 0 (defaults to 1): column becomes 0; row unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '0', 'G'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 0)

	// VPA 12: 1-indexed row 12 -> 0-indexed row 11; col unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', '2', 'd'})
	testing.expect_value(t, term.cursor.row, 11)
	testing.expect_value(t, term.cursor.col, 0)

	// VPA bare (default 1): row becomes 0; col unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'd'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 0)

	// VPA 0 (defaults to 1): row becomes 0; col unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '0', 'd'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 0)

	// HPR ('a'): relative horizontal forward by 7 columns
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '7', 'a'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 7)

	// VPR ('e'): relative vertical down by 4 rows
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', 'e'})
	testing.expect_value(t, term.cursor.row, 4)
	testing.expect_value(t, term.cursor.col, 7)

	// HVP ('f'): identical to CUP (row 2, col 3 -> 0-indexed 1, 2)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', ';', '3', 'f'})
	testing.expect_value(t, term.cursor.row, 1)
	testing.expect_value(t, term.cursor.col, 2)
}

// 2. Test ECH ('X') erasing characters without moving cursor
@(test)
test_tui_ech_erase_characters :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Write "ABCDEFGHIJ" on row 0
	p.parse_chunk(&parser, &term, []u8{'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'})

	// Move cursor to row 0, col 3 ('D')
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', ';', '4', 'H'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 3)
	testing.expect_value(t, _cell_rune(&term, 0, 3), 'D')

	// ECH 4: Erase 4 characters starting at col 3 ('D', 'E', 'F', 'G')
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', 'X'})

	// Cursor must NOT move
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 3)

	// Cells 0..2 unchanged
	testing.expect_value(t, _cell_rune(&term, 0, 0), 'A')
	testing.expect_value(t, _cell_rune(&term, 0, 1), 'B')
	testing.expect_value(t, _cell_rune(&term, 0, 2), 'C')

	// Cells 3..6 erased to default (content 0)
	testing.expect_value(t, _cell_rune(&term, 0, 3), 0)
	testing.expect_value(t, _cell_rune(&term, 0, 4), 0)
	testing.expect_value(t, _cell_rune(&term, 0, 5), 0)
	testing.expect_value(t, _cell_rune(&term, 0, 6), 0)

	// Cells 7..9 unchanged
	testing.expect_value(t, _cell_rune(&term, 0, 7), 'H')
	testing.expect_value(t, _cell_rune(&term, 0, 8), 'I')
	testing.expect_value(t, _cell_rune(&term, 0, 9), 'J')

	// Default ECH (no parameter = 1) at col 7
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', ';', '8', 'H'}) // col 7 ('H')
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'X'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 7)
	testing.expect_value(t, _cell_rune(&term, 0, 7), 0)
	testing.expect_value(t, _cell_rune(&term, 0, 8), 'I')

	// Clamping to right edge: cursor at col 78, erase 10 chars
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', ';', '7', '9', 'H'}) // col 78
	tg.terminal_put_char(&term, 'Y')
	tg.terminal_put_char(&term, 'Z')
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', ';', '7', '9', 'H'}) // back to col 78
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', '0', 'X'})
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 78)
	testing.expect_value(t, _cell_rune(&term, 0, 78), 0)
	testing.expect_value(t, _cell_rune(&term, 0, 79), 0)
}

// 3. Test IL ('L') and DL ('M') line insertion and deletion
@(test)
test_tui_il_dl_line_editing :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Write rows 0, 1, 2, 3
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', ';', '1', 'H', '0'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', ';', '1', 'H', '1'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '3', ';', '1', 'H', '2'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', ';', '1', 'H', '3'})

	// Move cursor to row 1, col 5
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', ';', '6', 'H'})
	testing.expect_value(t, term.cursor.row, 1)
	testing.expect_value(t, term.cursor.col, 5)

	// IL 1: insert blank line at row 1
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', 'L'})

	// Cursor col is reset to 0 per spec, row remains 1
	testing.expect_value(t, term.cursor.row, 1)
	testing.expect_value(t, term.cursor.col, 0)

	// Row 0 is unchanged ('0')
	testing.expect_value(t, _cell_rune(&term, 0, 0), '0')
	// Row 1 is newly inserted blank
	testing.expect_value(t, _cell_rune(&term, 1, 0), 0)
	// Former row 1 moved to row 2 ('1')
	testing.expect_value(t, _cell_rune(&term, 2, 0), '1')
	// Former row 2 moved to row 3 ('2')
	testing.expect_value(t, _cell_rune(&term, 3, 0), '2')
	// Former row 3 moved to row 4 ('3')
	testing.expect_value(t, _cell_rune(&term, 4, 0), '3')

	// Move cursor to row 2, col 4
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '3', ';', '5', 'H'})

	// DL 1: delete line at row 2 ('1')
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', 'M'})

	// Cursor col is reset to 0 per spec, row remains 2
	testing.expect_value(t, term.cursor.row, 2)
	testing.expect_value(t, term.cursor.col, 0)

	// Row 0 is still '0', row 1 is blank
	testing.expect_value(t, _cell_rune(&term, 0, 0), '0')
	testing.expect_value(t, _cell_rune(&term, 1, 0), 0)
	// Row 2 is now former row 3 ('2')
	testing.expect_value(t, _cell_rune(&term, 2, 0), '2')
	// Row 3 is now former row 4 ('3')
	testing.expect_value(t, _cell_rune(&term, 3, 0), '3')

	// Verify IL / DL outside scroll margins are ignored
	tg.terminal_set_scroll_region(&term, 5, 10)
	term.cursor.row = 2 // outside margins [5, 10]
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', 'L'})
	// Row 2 should still be '2'
	testing.expect_value(t, _cell_rune(&term, 2, 0), '2')
}

// 4. Test RI (ESC M), IND (ESC D), and NEL (ESC E)
@(test)
test_tui_reverse_index :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Position away from scroll_top
	term.cursor.row = 5
	term.cursor.col = 10

	// ESC M: Reverse Index -> cursor up 1 row, col unchanged
	p.parse_chunk(&parser, &term, []u8{0x1B, 'M'})
	testing.expect_value(t, term.cursor.row, 4)
	testing.expect_value(t, term.cursor.col, 10)

	// Position at scroll_top (0) with content
	tg.terminal_move_cursor(&term, 0, 0)
	tg.terminal_put_char(&term, 'T')
	tg.terminal_move_cursor(&term, 0, 0)

	// ESC M at scroll_top: scrolls grid down 1 row; cursor remains at scroll_top
	p.parse_chunk(&parser, &term, []u8{0x1B, 'M'})
	testing.expect_value(t, term.cursor.row, 0)
	// Row 0 is now blanked by scroll_down
	testing.expect_value(t, _cell_rune(&term, 0, 0), 0)
	// Row 1 now contains 'T'
	testing.expect_value(t, _cell_rune(&term, 1, 0), 'T')

	// Test IND (ESC D): moves cursor down without changing column
	term.cursor.row = 3
	term.cursor.col = 7
	p.parse_chunk(&parser, &term, []u8{0x1B, 'D'})
	testing.expect_value(t, term.cursor.row, 4)
	testing.expect_value(t, term.cursor.col, 7)

	// Test NEL (ESC E): moves cursor down and resets column to 0
	p.parse_chunk(&parser, &term, []u8{0x1B, 'E'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 0)
}

// 5. Test DECSTBM cursor homing to (0, 0)
@(test)
test_tui_decstbm_cursor_home :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Move cursor to (10, 20)
	tg.terminal_move_cursor(&term, 10, 20)
	testing.expect_value(t, term.cursor.row, 10)
	testing.expect_value(t, term.cursor.col, 20)

	// DECSTBM 5;15r sets scroll region to 4..14 and HOMES cursor to (0, 0)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '5', ';', '1', '5', 'r'})
	testing.expect_value(t, term.scroll_top, 4)
	testing.expect_value(t, term.scroll_bottom, 14)
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 0)

	// Move cursor away again
	tg.terminal_move_cursor(&term, 8, 12)

	// Bare DECSTBM resets margins to full grid and HOMES cursor to (0, 0)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'r'})
	testing.expect_value(t, term.scroll_top, 0)
	testing.expect_value(t, term.scroll_bottom, 23)
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 0)
}

// 6. Test ?1049h and ?1049l alternate screen buffer switching and primary preservation
@(test)
test_tui_alt_screen_1049 :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Primary screen: write content at row 0
	p.parse_chunk(&parser, &term, []u8{'P', 'r', 'i', 'm', 'a', 'r', 'y'})
	testing.expect_value(t, _cell_rune(&term, 0, 0), 'P')

	// Move cursor to (5, 15)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '6', ';', '1', '6', 'H'})
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 15)

	// Enter alt screen: CSI ? 1049 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '4', '9', 'h'})
	testing.expect(t, term.is_alt_screen, "Terminal should be in alt screen")
	testing.expect_value(t, term.cursor.row, 0)
	testing.expect_value(t, term.cursor.col, 0)

	// Alternate screen must be cleared
	testing.expect_value(t, _cell_rune(&term, 0, 0), 0)

	// Write content on alt screen
	p.parse_chunk(&parser, &term, []u8{'A', 'l', 't', 'e', 'r', 'n', 'a', 't', 'e'})
	testing.expect_value(t, _cell_rune(&term, 0, 0), 'A')

	// Scrolling in alt screen must NOT pollute scrollback
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '3', '0', 'S'}) // SU 30
	testing.expect_value(t, len(term.scrollback.rows), 0)

	// Leave alt screen: CSI ? 1049 l
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '4', '9', 'l'})
	testing.expect(t, !term.is_alt_screen, "Terminal should not be in alt screen")

	// Cursor restored to primary position (5, 15)
	testing.expect_value(t, term.cursor.row, 5)
	testing.expect_value(t, term.cursor.col, 15)

	// Primary content restored
	testing.expect_value(t, _cell_rune(&term, 0, 0), 'P')
	testing.expect_value(t, _cell_rune(&term, 0, 1), 'r')
	testing.expect_value(t, _cell_rune(&term, 0, 6), 'y')

	// Also test legacy mode 47 (CSI ? 47 h / l)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '4', '7', 'h'})
	testing.expect(t, term.is_alt_screen, "Terminal should enter alt screen with ?47h")
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '4', '7', 'l'})
	testing.expect(t, !term.is_alt_screen, "Terminal should leave alt screen with ?47l")
}

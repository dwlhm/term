package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// --- UTF-8 Decoder Tests ---

@(test)
test_utf8_ascii :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// ASCII byte 'A' (0x41)
	p.utf8_feed(&parser, &term, 0x41)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'A', "Should decode ASCII 'A'")
}

@(test)
test_utf8_2byte :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// 2-byte UTF-8: é (U+00E9) = 0xC3 0xA9
	p.utf8_feed(&parser, &term, 0xC3)
	p.utf8_feed(&parser, &term, 0xA9)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x00E9, "Should decode 2-byte UTF-8 é")
}

@(test)
test_utf8_3byte :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// 3-byte UTF-8: € (U+20AC) = 0xE2 0x82 0xAC
	p.utf8_feed(&parser, &term, 0xE2)
	p.utf8_feed(&parser, &term, 0x82)
	p.utf8_feed(&parser, &term, 0xAC)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x20AC, "Should decode 3-byte UTF-8 €")
}

@(test)
test_utf8_4byte :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// 4-byte UTF-8: 😀 (U+1F600) = 0xF0 0x9F 0x98 0x80
	p.utf8_feed(&parser, &term, 0xF0)
	p.utf8_feed(&parser, &term, 0x9F)
	p.utf8_feed(&parser, &term, 0x98)
	p.utf8_feed(&parser, &term, 0x80)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x1F600, "Should decode 4-byte UTF-8 😀")
}

@(test)
test_utf8_invalid_lead :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Invalid lead byte (continuation byte as lead)
	p.utf8_feed(&parser, &term, 0x80)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0xFFFD, "Should emit replacement char for invalid lead")
}

@(test)
test_utf8_invalid_continuation :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Invalid continuation (0xC3 followed by 0x20 which is ASCII space)
	p.utf8_feed(&parser, &term, 0xC3)
	p.utf8_feed(&parser, &term, 0x20)
	
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0xFFFD, "Should emit replacement char for invalid continuation")
}

// --- ASCII Scanner Tests ---

@(test)
test_ascii_scan_basic :: proc(t: ^testing.T) {
	input := []u8{'h', 'e', 'l', 'l', 'o'}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 5, "Should scan 5 bytes")
	testing.expect(t, len(run.data) == 5, "Data length should be 5")
}

@(test)
test_ascii_scan_empty :: proc(t: ^testing.T) {
	input := []u8{}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 0, "Empty input should return length 0")
}

@(test)
test_ascii_scan_esc_in_middle :: proc(t: ^testing.T) {
	input := []u8{'h', 'e', 'l', 0x1B, 'l', 'o'}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 3, "Should stop at ESC")
}

@(test)
test_ascii_scan_utf8_lead :: proc(t: ^testing.T) {
	input := []u8{'h', 'e', 'l', 0xC3, 'l', 'o'}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 3, "Should stop at UTF-8 lead byte")
}

@(test)
test_ascii_scan_c0_control :: proc(t: ^testing.T) {
	input := []u8{'h', 'e', 'l', 0x0A, 'l', 'o'}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 3, "Should stop at C0 control")
}

@(test)
test_ascii_scan_all_printable :: proc(t: ^testing.T) {
	input := make([]u8, 256)
	for i in 0..<256 {
		input[i] = u8(0x20 + (i % 95)) // printable ASCII range
	}
	run := p.scan_ascii_run(input)
	
	testing.expect(t, run.length == 256, "Should scan all 256 bytes")
	delete(input)
}

// --- VT State Machine Tests ---

@(test)
test_vt_ground_print :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[0][0x41] // Ground + 'A'
	
	testing.expect(t, transition.action == .Print, "Action should be Print")
	testing.expect(t, transition.next_state == .Ground, "Next state should be Ground")
}

@(test)
test_vt_ground_esc :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[0][0x1B] // Ground + ESC
	
	testing.expect(t, transition.action == .Clear, "Action should be Clear")
	testing.expect(t, transition.next_state == .Escape, "Next state should be Escape")
}

@(test)
test_vt_escape_csi :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[1][0x5B] // Escape + '['
	
	testing.expect(t, transition.action == .Clear, "Action should be Clear")
	testing.expect(t, transition.next_state == .CSI_Entry, "Next state should be CSI_Entry")
}

@(test)
test_vt_csi_entry_digit :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[2][0x31] // CSI_Entry + '1'
	
	testing.expect(t, transition.action == .Param, "Action should be Param")
	testing.expect(t, transition.next_state == .CSI_Param, "Next state should be CSI_Param")
}

@(test)
test_vt_csi_param_semi :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[3][0x3B] // CSI_Param + ';'
	
	testing.expect(t, transition.action == .Param, "Action should be Param")
	testing.expect(t, transition.next_state == .CSI_Param, "Next state should be CSI_Param")
}

@(test)
test_vt_csi_param_dispatch :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[3][0x48] // CSI_Param + 'H'
	
	testing.expect(t, transition.action == .CsiDispatch, "Action should be CsiDispatch")
	testing.expect(t, transition.next_state == .Ground, "Next state should be Ground")
}

@(test)
test_vt_ground_utf8 :: proc(t: ^testing.T) {
	transition := p.TRANSITION_TABLE[0][0xC3] // Ground + UTF-8 lead
	
	testing.expect(t, transition.action == .Utf8, "Action should be Utf8")
	testing.expect(t, transition.next_state == .Utf8, "Next state should be Utf8")
}

// --- CSI Sequence Tests ---

@(test)
test_csi_cup :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// ESC[1;2H - move to row 1, col 2
	input := []u8{0x1B, '[', '1', ';', '2', 'H'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 0, "Row should be 0 (1-1)")
	testing.expect(t, cursor.col == 1, "Col should be 1 (2-1)")
}

@(test)
test_csi_cuu :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Move to row 10 first
	tg.terminal_move_cursor(&term, 10, 0)
	
	// ESC[3A - cursor up 3
	input := []u8{0x1B, '[', '3', 'A'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 7, "Row should be 7 (10-3)")
}

@(test)
test_csi_cud :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// ESC[2B - cursor down 2
	input := []u8{0x1B, '[', '2', 'B'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 2, "Row should be 2")
}

@(test)
test_csi_cuf :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// ESC[4C - cursor forward 4
	input := []u8{0x1B, '[', '4', 'C'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 4, "Col should be 4")
}

@(test)
test_csi_cub :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Move to col 10 first
	tg.terminal_move_cursor(&term, 0, 10)
	
	// ESC[5D - cursor back 5
	input := []u8{0x1B, '[', '5', 'D'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 5, "Col should be 5 (10-5)")
}

@(test)
test_csi_el_to_end :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Write "hello"
	tg.terminal_put_string(&term, "hello")
	
	// ESC[K - erase to end of line
	input := []u8{0x1B, '[', 'K'}
	p.parse_chunk(&parser, &term, input)
	
	// Characters before cursor should remain
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'h', "H should remain")
}

@(test)
test_csi_su :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// Write to row 0
	tg.terminal_put_string(&term, "Line 0")
	tg.terminal_newline(&term)
	tg.terminal_put_string(&term, "Line 1")
	
	// ESC[2S - scroll up 2
	input := []u8{0x1B, '[', '2', 'S'}
	p.parse_chunk(&parser, &term, input)
	
	// Row 0 should now be empty (scrolled up)
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0, "Row 0 should be cleared after scroll")
}

// --- Integration Tests ---

@(test)
test_integration_simple_text :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// "hello world"
	input := []u8{'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd'}
	p.parse_chunk(&parser, &term, input)
	
	// Verify row 0
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'h', "Row 0, col 0 should be 'h'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 4).content == 'o', "Row 0, col 4 should be 'o'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 6).content == 'w', "Row 0, col 6 should be 'w'")
	
	// Verify cursor
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 0, "Cursor row should be 0")
	testing.expect(t, cursor.col == 11, "Cursor col should be 11")
}

@(test)
test_integration_cursor_movement :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// ESC[2;5H - move to row 2, col 5
	input := []u8{0x1B, '[', '2', ';', '5', 'H'}
	p.parse_chunk(&parser, &term, input)
	
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 1, "Cursor row should be 1 (0-indexed)")
	testing.expect(t, cursor.col == 4, "Cursor col should be 4 (0-indexed)")
}

@(test)
test_integration_erase :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// "hello" then ESC[K
	input := []u8{'h', 'e', 'l', 'l', 'o', 0x1B, '[', 'K'}
	p.parse_chunk(&parser, &term, input)
	
	// Row 0 should have "hello"
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'h', "Row 0, col 0 should be 'h'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 4).content == 'o', "Row 0, col 4 should be 'o'")
	
	// Cells 5+ should be blank
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 5).content == 0, "Row 0, col 5 should be blank")
}

@(test)
test_integration_mixed :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// "hello " then ESC[2;1H then "world"
	input := []u8{
		'h', 'e', 'l', 'l', 'o', ' ',
		0x1B, '[', '2', ';', '1', 'H',
		'w', 'o', 'r', 'l', 'd',
	}
	p.parse_chunk(&parser, &term, input)
	
	// Row 0 should have "hello "
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'h', "Row 0, col 0 should be 'h'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 5).content == ' ', "Row 0, col 5 should be ' '")
	
	// Row 1 should have "world"
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 0).content == 'w', "Row 1, col 0 should be 'w'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 1, 4).content == 'd', "Row 1, col 4 should be 'd'")
	
	// Cursor should be at (1, 5)
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 1, "Cursor row should be 1")
	testing.expect(t, cursor.col == 5, "Cursor col should be 5")
}

@(test)
test_integration_utf8 :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)
	
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	
	// "café" (with UTF-8 é)
	input := []u8{'c', 'a', 'f', 0xC3, 0xA9}
	p.parse_chunk(&parser, &term, input)
	
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'c', "Row 0, col 0 should be 'c'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 'a', "Row 0, col 1 should be 'a'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 'f', "Row 0, col 2 should be 'f'")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 3).content == 0x00E9, "Row 0, col 3 should be 'é'")
}

@(test)
test_parser_memory_layout :: proc(t: ^testing.T) {
	testing.expect(t, offset_of(p.Parser, state) == 0, "offset state == 0")
	testing.expect(t, offset_of(p.Parser, csi_count) == 1, "offset csi_count == 1")
	testing.expect(t, offset_of(p.Parser, csi_subparam_mask) == 2, "offset csi_subparam_mask == 2")
	testing.expect(t, offset_of(p.Parser, csi_values) == 4, "offset csi_values == 4 (0 padding)")
	testing.expect(t, offset_of(p.Parser, utf8_state) == 68, "offset utf8_state == 68")
	testing.expect(t, offset_of(p.Parser, utf8_len) == 69, "offset utf8_len == 69")
	testing.expect(t, offset_of(p.Parser, utf8_buffer) == 70, "offset utf8_buffer == 70")
	testing.expect(t, offset_of(p.Parser, intermediate) == 74, "offset intermediate == 74")
	testing.expect(t, offset_of(p.Parser, string_esc_pending) == 75, "offset string_esc_pending == 75")
	testing.expect(t, offset_of(p.Parser, osc_truncated) == 76, "offset osc_truncated == 76")
	testing.expect(t, offset_of(p.Parser, osc_len) == 80, "offset osc_len == 80")
	testing.expect(t, offset_of(p.Parser, osc_buffer) == 88, "offset osc_buffer == 88")
	testing.expect(t, offset_of(p.Parser, dcs_len) == 600, "offset dcs_len == 600")
	testing.expect(t, offset_of(p.Parser, dcs_buffer) == 608, "offset dcs_buffer == 608")
	testing.expect(t, offset_of(p.Parser, print_run_start) == 1120, "offset print_run_start == 1120")
	testing.expect(t, offset_of(p.Parser, print_run_len) == 1128, "offset print_run_len == 1128")
	testing.expect(t, offset_of(p.Parser, response_cb) == 1136, "offset response_cb == 1136")
	testing.expect(t, offset_of(p.Parser, clipboard_cb) == 1144, "offset clipboard_cb == 1144")
	testing.expect(t, offset_of(p.Parser, clipboard_read_cb) == 1152, "offset clipboard_read_cb == 1152")
	testing.expect(t, offset_of(p.Parser, clipboard_read_user_data) == 1160, "offset clipboard_read_user_data == 1160")
	testing.expect(t, size_of(p.Parser) == 1168, "size_of(Parser) == 1168")
}

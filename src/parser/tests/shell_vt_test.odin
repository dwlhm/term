package parser_test

// Shell startup and terminal-control coverage. These tests keep shell output
// on the parser/output side of the boundary and exercise split VT strings.

import "core:testing"
import parser "../"
import termgrid "../../terminal"

_shell_term :: proc(rows, cols: int) -> termgrid.Terminal {
	t: termgrid.Terminal
	termgrid.terminal_init(&t, rows, cols)
	return t
}

@(test)
test_shell_osc_bel_and_st_are_persistent :: proc(t: ^testing.T) {
	term := _shell_term(4, 20)
	defer termgrid.terminal_destroy(&term)
	p: parser.Parser
	parser.parser_init(&p)

	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '8', ';', ';', 'u', 'r', 'l'})
	testing.expect(t, parser.parser_get_state(&p) == .OSC, "OSC must persist across chunks")
	parser.parse_chunk(&p, &term, []u8{0x07, 'A'})
	testing.expect(t, parser.parser_get_state(&p) == .Ground, "BEL must terminate OSC")
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 0, 0).content, u32('A'))

	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '0', ';', 'x', 0x1B})
	testing.expect(t, parser.parser_get_state(&p) == .OSC, "ST may be split after ESC")
	parser.parse_chunk(&p, &term, []u8{'\\', 'B'})
	testing.expect(t, parser.parser_get_state(&p) == .Ground, "ST must terminate OSC")
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 0, 1).content, u32('B'))
}

@(test)
test_shell_string_cancel_recovers :: proc(t: ^testing.T) {
	term := _shell_term(3, 12)
	defer termgrid.terminal_destroy(&term)
	p: parser.Parser
	parser.parser_init(&p)
	parser.parse_chunk(&p, &term, []u8{0x1B, 'P', 'x', 0x18, 'C'})
	testing.expect(t, parser.parser_get_state(&p) == .Ground, "CAN must cancel DCS")
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 0, 0).content, u32('C'))

	parser.parse_chunk(&p, &term, []u8{0x1B, ']', 'x', 0x1A, 'D'})
	testing.expect(t, parser.parser_get_state(&p) == .Ground, "SUB must cancel OSC")
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 0, 1).content, u32('D'))
}

@(test)
test_shell_cursor_save_restore_and_reset :: proc(t: ^testing.T) {
	term := _shell_term(4, 16)
	defer termgrid.terminal_destroy(&term)
	p: parser.Parser
	parser.parser_init(&p)
	termgrid.terminal_move_cursor(&term, 2, 5)
	parser.parse_chunk(&p, &term, []u8{0x1B, '7'})
	termgrid.terminal_move_cursor(&term, 0, 0)
	parser.parse_chunk(&p, &term, []u8{0x1B, '8'})
	cur := termgrid.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 2 && cur.col == 5, "DECSC/DECRC must restore cursor")

	parser.parse_chunk(&p, &term, []u8{0x1B, 'c'})
	cur = termgrid.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 0 && cur.col == 0 && cur.visible, "RIS must reset terminal state")
}

@(test)
test_shell_clear_sequence_has_no_synthetic_percent :: proc(t: ^testing.T) {
	term := _shell_term(3, 12)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_string(&term, "old")
	termgrid.terminal_move_cursor(&term, 0, 0)
	p: parser.Parser
	parser.parser_init(&p)
	parser.parse_chunk(&p, &term, []u8{0x1B, '[', '3', 'J', 0x1B, '[', 'H', 0x1B, '[', '2', 'J'})
	testing.expect(t, parser.parser_get_state(&p) == .Ground, "clear must finish in Ground")
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 0, 0).content, u32(0))
	for row in 0..<3 {
		for col in 0..<12 {
			testing.expect(t, termgrid.terminal_get_cell(&term, row, col).content != u32('%'), "clear must not synthesize percent")
		}
	}
}

@(test)
test_shell_lf_preserves_column_and_cr_resets_it :: proc(t: ^testing.T) {
	term := _shell_term(4, 16)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_move_cursor(&term, 0, 3)
	p: parser.Parser
	parser.parser_init(&p)
	parser.parse_chunk(&p, &term, []u8{'\n', 'X'})
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 1, 3).content, u32('X'))
	parser.parse_chunk(&p, &term, []u8{'\r', 'Y'})
	testing.expect_value(t, termgrid.terminal_get_cell(&term, 1, 0).content, u32('Y'))
}

@(test)
test_osc_133_prompt_and_command_lifecycle :: proc(t: ^testing.T) {
	term := _shell_term(4, 20)
	defer termgrid.terminal_destroy(&term)
	p: parser.Parser
	parser.parser_init(&p)

	testing.expect(t, !term.has_osc_133, "initially has_osc_133 is false")
	testing.expect(t, !term.in_prompt_zone, "initially in_prompt_zone is false")

	// Emit prompt start: \x1b]133;A\x07
	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '1', '3', '3', ';', 'A', 0x07})
	testing.expect(t, term.has_osc_133, "has_osc_133 is true after OSC 133")
	testing.expect(t, term.in_prompt_zone, "in_prompt_zone is true after 133;A")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is marked as prompt")

	// Print prompt text
	parser.parse_chunk(&p, &term, []u8{'>', ' '})

	// Emit prompt end: \x1b]133;B\x07
	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '1', '3', '3', ';', 'B', 0x07})
	testing.expect(t, !term.in_prompt_zone, "in_prompt_zone is false after 133;B")

	// User enters command: emit command start \x1b]133;C\x07
	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '1', '3', '3', ';', 'C', 0x07})
	testing.expect(t, !term.in_prompt_zone, "in_prompt_zone is false during command execution")

	// Command prints newline and output
	parser.parse_chunk(&p, &term, []u8{'\r', '\n', 'h', 'e', 'l', 'l', 'o'})
	testing.expect(t, !term.grid.rows[1].is_prompt, "output row 1 is not prompt")

	// Emit command end: \x1b]133;D;0\x07 (with exit code)
	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '1', '3', '3', ';', 'D', ';', '0', 0x07})
	testing.expect(t, !term.in_prompt_zone, "in_prompt_zone is false after 133;D")
}

@(test)
test_osc_133_st_terminator :: proc(t: ^testing.T) {
	term := _shell_term(4, 20)
	defer termgrid.terminal_destroy(&term)
	p: parser.Parser
	parser.parser_init(&p)

	// Emit prompt start with ST terminator: \x1b]133;A\x1b\
	parser.parse_chunk(&p, &term, []u8{0x1B, ']', '1', '3', '3', ';', 'A', 0x1B, '\\'})
	testing.expect(t, term.has_osc_133, "has_osc_133 is true with ST")
	testing.expect(t, term.in_prompt_zone, "in_prompt_zone is true with ST")
	testing.expect(t, term.grid.rows[0].is_prompt, "row 0 is marked as prompt with ST")
}


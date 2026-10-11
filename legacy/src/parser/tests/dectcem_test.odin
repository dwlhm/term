package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// --- DECTCEM (CSI ? 25 h/l) Tests ---

@(test)
test_dectcem_hide :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.cursor.visible, "Cursor should start visible")

	// ESC[?25l - hide cursor
	input := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, input)

	testing.expect(t, !term.cursor.visible, "ESC[?25l should hide cursor")
}

@(test)
test_dectcem_show :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Hide first, then show
	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)
	testing.expect(t, !term.cursor.visible, "Should be hidden after ?25l")

	show := []u8{0x1B, '[', '?', '2', '5', 'h'}
	p.parse_chunk(&parser, &term, show)
	testing.expect(t, term.cursor.visible, "ESC[?25h should show cursor")
}

@(test)
test_dectcem_idempotent :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)
	p.parse_chunk(&parser, &term, hide)
	testing.expect(t, !term.cursor.visible, "Repeated ?25l should stay hidden")

	show := []u8{0x1B, '[', '?', '2', '5', 'h'}
	p.parse_chunk(&parser, &term, show)
	p.parse_chunk(&parser, &term, show)
	testing.expect(t, term.cursor.visible, "Repeated ?25h should stay visible")
}

@(test)
test_dectcem_plain_ignored :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Plain 25l (no ?) must NOT hide: DECTCEM requires the private marker
	plain_hide := []u8{0x1B, '[', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, plain_hide)
	testing.expect(t, term.cursor.visible, "Plain 25l without ? should be ignored")

	// Hide via private, then plain 25h must NOT show
	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)
	plain_show := []u8{0x1B, '[', '2', '5', 'h'}
	p.parse_chunk(&parser, &term, plain_show)
	testing.expect(t, !term.cursor.visible, "Plain 25h without ? should be ignored")
}

@(test)
test_dectcem_other_private_ignored :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// ?1049h (alt screen) must not change visibility
	alt := []u8{0x1B, '[', '?', '1', '0', '4', '9', 'h'}
	p.parse_chunk(&parser, &term, alt)
	testing.expect(t, term.cursor.visible, "?1049h should not change visibility")

	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)
	p.parse_chunk(&parser, &term, alt)
	testing.expect(t, !term.cursor.visible, "?1049h should not re-show a hidden cursor")

	alt_off := []u8{0x1B, '[', '?', '1', '0', '4', '9', 'l'}
	p.parse_chunk(&parser, &term, alt_off)
	testing.expect(t, !term.cursor.visible, "?1049l should not change visibility")
}

@(test)
test_dectcem_multi_param :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// ?25;1h applies because 25 is present
	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)
	multi := []u8{0x1B, '[', '?', '2', '5', ';', '1', 'h'}
	p.parse_chunk(&parser, &term, multi)
	testing.expect(t, term.cursor.visible, "?25;1h should show (25 present)")
}

@(test)
test_dectcem_persists_across_output :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	hide := []u8{0x1B, '[', '?', '2', '5', 'l'}
	p.parse_chunk(&parser, &term, hide)

	// Plain output must not change visibility state
	text := []u8{'h', 'e', 'l', 'l', 'o'}
	p.parse_chunk(&parser, &term, text)
	testing.expect(t, !term.cursor.visible, "Visibility should persist across output")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'h', "Output should still print while hidden")

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 5, "Cursor should advance normally while hidden")
}

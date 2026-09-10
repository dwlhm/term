package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// _sgr_feed feeds raw bytes through parse_chunk.
_sgr_feed :: proc(parser: ^p.Parser, term: ^tg.Terminal, s: string) {
	p.parse_chunk(parser, term, transmute([]u8)s)
}

// _sgr_style_of returns the Style for a cell's style id.
_sgr_style_of :: proc(term: ^tg.Terminal, row, col: int) -> tg.Style {
	cell := tg.terminal_get_cell(term, row, col)
	return tg.style_table_get(&term.grid.style_table, cell.style)
}

@(test)
test_sgr_reset_bare :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// ESC[31m then text, then ESC[0m reset.
	_sgr_feed(&parser, &term, "\x1b[31mA")
	_sgr_feed(&parser, &term, "\x1b[0m")
	testing.expect(t, term.current_style == 0, "ESC[0m must reset to style 0")

	// Bare ESC[m also resets.
	_sgr_feed(&parser, &term, "\x1b[31mB")
	testing.expect(t, term.current_style != 0, "ESC[31m must leave style 0")
	_sgr_feed(&parser, &term, "\x1b[m")
	testing.expect(t, term.current_style == 0, "bare ESC[m must reset to style 0")
}

@(test)
test_sgr_fg_red :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[31mR")
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'R', "cell must hold R")
	testing.expect(t, cell.style != 0, "red cell must carry non-default style")
	st := tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.fg == 0xFFCD0000, "fg must be xterm red")
	testing.expect(t, st.bg == 0xFF000000, "bg must stay default black")
}

@(test)
test_sgr_bold_red_combined :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[1;31mB")
	cell := tg.terminal_get_cell(&term, 0, 0)
	st := tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.fg == 0xFFCD0000, "fg must be xterm red")
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "bold flag must be set")
	// ONE style id carries both: single insert per sequence.
	testing.expect(t, int(term.grid.style_table.count) == 2, "combined SGR must insert exactly one style")
}

@(test)
test_sgr_fg_bg :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[31;42mX")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFFCD0000, "fg must be xterm red")
	testing.expect(t, st.bg == 0xFF00CD00, "bg must be xterm green")
}

@(test)
test_sgr_cumulative :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[31m")
	_sgr_feed(&parser, &term, "\x1b[42mY")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFFCD0000, "fg red must survive later bg-only SGR")
	testing.expect(t, st.bg == 0xFF00CD00, "bg must be xterm green")
}

@(test)
test_sgr_fg_bg_default_only :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 39 resets only fg.
	_sgr_feed(&parser, &term, "\x1b[31;42m")
	_sgr_feed(&parser, &term, "\x1b[39mZ")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFFFFFFFF, "39 must reset fg to default white")
	testing.expect(t, st.bg == 0xFF00CD00, "39 must preserve bg")

	// 49 resets only bg.
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[31;42m")
	_sgr_feed(&parser, &term, "\x1b[49mW")
	// Cursor advanced past Z, so W lands at col 1.
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.fg == 0xFFCD0000, "49 must preserve fg")
	testing.expect(t, st.bg == 0xFF000000, "49 must reset bg to default black")
}

@(test)
test_sgr_bright :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[90mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFF7F7F7F, "90 must be bright black")

	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[102mB")
	// Cursor advanced to col 1; read the second cell.
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.bg == 0xFF00FF00, "102 must be bright green bg")
}

@(test)
test_sgr_256_color :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[38;5;196mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFFFF0000, "38;5;196 must be 256-color red fg")
	testing.expect(t, st.bg == 0xFF000000, "bg must stay default")

	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[48;5;27mB")
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.bg == 0xFF005FFF, "48;5;27 must be 256-color bg")
	testing.expect(t, st.fg == 0xFFFFFFFF, "fg must stay default white")
}

@(test)
test_sgr_truecolor :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[38;2;10;20;30mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFF0A141E, "38;2;10;20;30 must be truecolor fg")
}

@(test)
test_sgr_truncated_tail :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Truncated 256-color: tail ignored, style unchanged.
	_sgr_feed(&parser, &term, "\x1b[31m")
	before := term.current_style
	_sgr_feed(&parser, &term, "\x1b[38;5m")
	testing.expect(t, term.current_style == before, "truncated 38;5 tail must leave style unchanged")

	// Truncated truecolor: tail ignored.
	_sgr_feed(&parser, &term, "\x1b[38;2;1;2m")
	testing.expect(t, term.current_style == before, "truncated 38;2 tail must leave style unchanged")

	// Prior params in the same sequence still apply.
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[32;38;5mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.fg == 0xFF00CD00, "prior param 32 must apply despite truncated tail")
}

@(test)
test_sgr_unknown_ignored :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[31m")
	before := term.current_style
	_sgr_feed(&parser, &term, "\x1b[999m")
	testing.expect(t, term.current_style == before, "unknown code must leave style unchanged")
}

@(test)
test_sgr_inverse_flag :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[7mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.flags & tg.STYLE_FLAG_INVERSE != 0, "inverse flag must be stored")

	_sgr_feed(&parser, &term, "\x1b[27mB")
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.flags & tg.STYLE_FLAG_INVERSE == 0, "27 must clear inverse")
}

@(test)
test_sgr_attr_set_clear :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[1;3;4;9mA")
	st := _sgr_style_of(&term, 0, 0)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "bold must be set")
	testing.expect(t, st.flags & tg.STYLE_FLAG_ITALIC != 0, "italic must be set")
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE != 0, "underline must be set")
	testing.expect(t, st.flags & tg.STYLE_FLAG_STRIKE != 0, "strike must be set")

	_sgr_feed(&parser, &term, "\x1b[22;23;24;29mB")
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD == 0, "22 must clear bold")
	testing.expect(t, st.flags & tg.STYLE_FLAG_ITALIC == 0, "23 must clear italic")
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE == 0, "24 must clear underline")
	testing.expect(t, st.flags & tg.STYLE_FLAG_STRIKE == 0, "29 must clear strike")
}

@(test)
test_sgr_dedup :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[31m")
	id1 := term.current_style
	count1 := term.grid.style_table.count

	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[31m")
	id2 := term.current_style
	count2 := term.grid.style_table.count

	testing.expect(t, id1 == id2, "same SGR twice must yield same style id")
	testing.expect(t, count1 == count2, "dedup must not grow the table")
}

@(test)
test_sgr_table_full :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Fill the table to capacity with distinct styles.
	i := 0
	for int(term.grid.style_table.count) < tg.STYLE_TABLE_CAPACITY {
		s := tg.Style{fg = u32(0xFF000000 | u32(i + 2)), bg = 0xFF000000, underline = 0, flags = 0}
		_ = tg.style_table_insert(&term.grid.style_table, s)
		i += 1
	}
	testing.expect(t, int(term.grid.style_table.count) == tg.STYLE_TABLE_CAPACITY, "table must be full")

	// A new SGR color must fall back to style 0 without crashing.
	_sgr_feed(&parser, &term, "\x1b[38;2;11;22;33mA")
	testing.expect(t, term.current_style == 0, "full table must return style 0 per overflow rule")
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 'A', "text must still print when style table is full")
}

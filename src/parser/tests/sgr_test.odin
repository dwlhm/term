package parser_test

import "core:testing"
import "core:fmt"
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_RED, "fg must use themed red")
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_BASE, "bg must stay default base")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_RED, "fg must use themed red")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_RED, "fg must use themed red")
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_GREEN, "bg must use themed green")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_RED, "fg red must survive later bg-only SGR")
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_GREEN, "bg must use themed green")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_TEXT, "39 must reset fg to default text")
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_GREEN, "39 must preserve bg")

	// 49 resets only bg.
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[31;42m")
	_sgr_feed(&parser, &term, "\x1b[49mW")
	// Cursor advanced past Z, so W lands at col 1.
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_RED, "49 must preserve fg")
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_BASE, "49 must reset bg to default base")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_SURFACE2, "90 must be themed bright black")

	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[102mB")
	// Cursor advanced to col 1; read the second cell.
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_GREEN, "102 must be themed bright green bg")
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
	testing.expect(t, st.bg == tg.CATPPUCCIN_MOCHA_BASE, "bg must stay default base")

	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[48;5;27mB")
	st = _sgr_style_of(&term, 0, 1)
	testing.expect(t, st.bg == 0xFF005FFF, "48;5;27 must be 256-color bg")
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_TEXT, "fg must stay default text")
}

@(test)
test_sgr_truecolor :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	_sgr_feed(&parser, &term, "\x1b[38;2;10;20;30mA")
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) != 0, "cell must have Direct_Color flag")
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Has_Extension) != 0, "cell must have Has_Extension flag")
	phys := tg._grid_physical_row(&term.grid, 0)
	testing.expect(t, .Direct_Color in term.grid.rows[phys].ext.channels, "row must have Direct_Color channel")
	testing.expect(t, term.grid.rows[phys].ext.colors[0].fg == 0xFF0A141E, "38;2;10;20;30 must be direct truecolor fg")
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
	testing.expect(t, st.fg == tg.CATPPUCCIN_MOCHA_GREEN, "prior param 32 must apply despite truncated tail")
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

@(test)
test_fast_parse_sgr_truecolor :: proc(t: ^testing.T) {
	// FG Semicolon
	consumed, ok, is_fg, color := p.fast_parse_sgr_truecolor(transmute([]u8)string("38;2;255;128;64m"))
	testing.expect(t, ok, "FG semicolon truecolor must parse ok")
	testing.expect(t, is_fg, "must be fg")
	testing.expect(t, consumed == 16, "must consume 16 bytes")
	testing.expect(t, color == 0xFFFF8040, "color must match 0xFFFF8040")

	// BG Semicolon
	consumed, ok, is_fg, color = p.fast_parse_sgr_truecolor(transmute([]u8)string("48;2;10;20;30m"))
	testing.expect(t, ok, "BG semicolon truecolor must parse ok")
	testing.expect(t, !is_fg, "must be bg")
	testing.expect(t, consumed == 14, "must consume 14 bytes")
	testing.expect(t, color == 0xFF0A141E, "color must match 0xFF0A141E")

	// Colon form 38:2::R:G:Bm
	consumed, ok, is_fg, color = p.fast_parse_sgr_truecolor(transmute([]u8)string("38:2::255;128:64m"))
	testing.expect(t, !ok, "mixed separator must fail")

	consumed, ok, is_fg, color = p.fast_parse_sgr_truecolor(transmute([]u8)string("38:2::255:128:64m"))
	testing.expect(t, ok, "Colon form 38:2::R:G:Bm must parse ok")
	testing.expect(t, is_fg, "must be fg")
	testing.expect(t, consumed == 17, "must consume 17 bytes")
	testing.expect(t, color == 0xFFFF8040, "color must match 0xFFFF8040")

	// Colon form 38:2:0:R:G:Bm
	consumed, ok, is_fg, color = p.fast_parse_sgr_truecolor(transmute([]u8)string("38:2:0:255:128:64m"))
	testing.expect(t, ok, "Colon form 38:2:0:R:G:Bm must parse ok")
	testing.expect(t, is_fg, "must be fg")
	testing.expect(t, consumed == 18, "must consume 18 bytes")
	testing.expect(t, color == 0xFFFF8040, "color must match 0xFFFF8040")

	// Clamping
	consumed, ok, is_fg, color = p.fast_parse_sgr_truecolor(transmute([]u8)string("38;2;300;400;500m"))
	testing.expect(t, ok, "Values > 255 must parse ok and clamp")
	testing.expect(t, color == 0xFFFFFFFF, "clamped color must be 0xFFFFFFFF")

	// Edge cases / Rejections
	_, ok, _, _ = p.fast_parse_sgr_truecolor(transmute([]u8)string("38;2;1m"))
	testing.expect(t, !ok, "short sequence must fail")
	_, ok, _, _ = p.fast_parse_sgr_truecolor(transmute([]u8)string("58;2;1;2;3m"))
	testing.expect(t, !ok, "invalid prefix must fail")
	_, ok, _, _ = p.fast_parse_sgr_truecolor(transmute([]u8)string("38;5;123m"))
	testing.expect(t, !ok, "256-color must fail fast path")
	_, ok, _, _ = p.fast_parse_sgr_truecolor(transmute([]u8)string("38;2;1;2;3;1m"))
	testing.expect(t, !ok, "compound SGR must fail fast path")
}

@(test)
test_fast_csi_parse_chunk :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Feed direct truecolor FG + BG followed by UTF-8 half-block '▀'
	_sgr_feed(&parser, &term, "\x1b[38;2;255;0;0m\x1b[48;2;0;0;255m\xe2\x96\x80")
	testing.expect(t, term.cursor.col == 1 && term.cursor.row == 0, "cursor must advance by 1 cell")
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x2580, "cell content must be half block U+2580")
	testing.expect(t, term.has_direct_fg, "direct fg must be set")
	testing.expect(t, term.direct_fg == 0xFFFF0000, "direct fg must be 0xFFFF0000")
	testing.expect(t, term.has_direct_bg, "direct bg must be set")
	testing.expect(t, term.direct_bg == 0xFF0000FF, "direct bg must be 0xFF0000FF")

	// Fast reset \x1b[0m
	_sgr_feed(&parser, &term, "\x1b[0m")
	testing.expect(t, !term.has_direct_fg, "direct fg must be reset")
	testing.expect(t, !term.has_direct_bg, "direct bg must be reset")

	// Fast cursor home \x1b[H
	tg.terminal_move_cursor(&term, 10, 15)
	_sgr_feed(&parser, &term, "\x1b[H")
	testing.expect(t, term.cursor.col == 0 && term.cursor.row == 0, "cursor must be at (0, 0)")

	// Fast erase to end of line \x1b[K and \x1b[0K
	_sgr_feed(&parser, &term, "ABCDEF")
	_sgr_feed(&parser, &term, "\x1b[H")
	_sgr_feed(&parser, &term, "\x1b[K")
	c0 := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, c0.content == 0, "erased line must clear cell")

	_sgr_feed(&parser, &term, "XYZ")
	_sgr_feed(&parser, &term, "\x1b[H")
	_sgr_feed(&parser, &term, "\x1b[0K")
	c1 := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, c1.content == 0, "erased line with 0K must clear cell")
}

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

@(test)
test_fast_path_16_color :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	theme := term.grid.style_table.theme

	// Standard fg: 30..=37
	for code in 30..=37 {
		s := fmt.tprintf("\x1b[%dmA", code)
		_sgr_feed(&parser, &term, s)
		st := tg.style_table_get(&term.grid.style_table, term.current_style)
		expected_color := tg.theme_palette_256(theme, code - 30)
		testing.expect(t, st.fg == expected_color, "Standard fg color must match theme palette")
		testing.expect(t, !term.has_direct_fg, "Direct fg must be cleared on indexed fg")
	}

	// Standard bg: 40..=47
	for code in 40..=47 {
		s := fmt.tprintf("\x1b[%dmB", code)
		_sgr_feed(&parser, &term, s)
		st := tg.style_table_get(&term.grid.style_table, term.current_style)
		expected_color := tg.theme_palette_256(theme, code - 40)
		testing.expect(t, st.bg == expected_color, "Standard bg color must match theme palette")
		testing.expect(t, !term.has_direct_bg, "Direct bg must be cleared on indexed bg")
	}

	// Bright fg: 90..=97
	for code in 90..=97 {
		s := fmt.tprintf("\x1b[%dmC", code)
		_sgr_feed(&parser, &term, s)
		st := tg.style_table_get(&term.grid.style_table, term.current_style)
		expected_color := tg.theme_palette_256(theme, code - 90 + 8)
		testing.expect(t, st.fg == expected_color, "Bright fg color must match theme palette")
	}

	// Bright bg: 100..=107
	for code in 100..=107 {
		s := fmt.tprintf("\x1b[%dmD", code)
		_sgr_feed(&parser, &term, s)
		st := tg.style_table_get(&term.grid.style_table, term.current_style)
		expected_color := tg.theme_palette_256(theme, code - 100 + 8)
		testing.expect(t, st.bg == expected_color, "Bright bg color must match theme palette")
	}

	// Default fg reset: 39
	_sgr_feed(&parser, &term, "\x1b[31;42m") // red on green
	_sgr_feed(&parser, &term, "\x1b[39m")    // reset fg
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.fg == theme.foreground, "39 must restore default fg")
	testing.expect(t, st.bg == tg.theme_palette_256(theme, 2), "39 must keep bg unchanged")

	// Default bg reset: 49
	_sgr_feed(&parser, &term, "\x1b[31;42m") // red on green
	_sgr_feed(&parser, &term, "\x1b[49m")    // reset bg
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.bg == theme.background, "49 must restore default bg")
	testing.expect(t, st.fg == tg.theme_palette_256(theme, 1), "49 must keep fg unchanged")

	// Reset 0m and bare m
	_sgr_feed(&parser, &term, "\x1b[31;42m")
	_sgr_feed(&parser, &term, "\x1b[0m")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.fg == theme.foreground, "0m must restore default fg")
	testing.expect(t, st.bg == theme.background, "0m must restore default bg")

	_sgr_feed(&parser, &term, "\x1b[31;42m")
	_sgr_feed(&parser, &term, "\x1b[m")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.fg == theme.foreground, "bare m must restore default fg")
	testing.expect(t, st.bg == theme.background, "bare m must restore default bg")
}

@(test)
test_fast_path_256_color :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	theme := term.grid.style_table.theme

	// Direct procedure testing of fast_parse_sgr_256
	consumed, ok, is_fg, idx := p.fast_parse_sgr_256(transmute([]u8)string("38;5;196m"))
	testing.expect(t, ok, "38;5;196m must parse successfully")
	testing.expect(t, is_fg, "38 must be foreground")
	testing.expect(t, consumed == 9, "consumed must be 9 bytes")
	testing.expect(t, idx == 196, "index must be 196")

	consumed, ok, is_fg, idx = p.fast_parse_sgr_256(transmute([]u8)string("48;5;42m"))
	testing.expect(t, ok, "48;5;42m must parse successfully")
	testing.expect(t, !is_fg, "48 must be background")
	testing.expect(t, consumed == 8, "consumed must be 8 bytes")
	testing.expect(t, idx == 42, "index must be 42")

	// Colon syntax
	consumed, ok, is_fg, idx = p.fast_parse_sgr_256(transmute([]u8)string("38:5:82m"))
	testing.expect(t, ok, "38:5:82m must parse successfully")
	testing.expect(t, is_fg, "38 must be foreground")
	testing.expect(t, consumed == 8, "consumed must be 8 bytes")
	testing.expect(t, idx == 82, "index must be 82")

	consumed, ok, is_fg, idx = p.fast_parse_sgr_256(transmute([]u8)string("48:5:0m"))
	testing.expect(t, ok, "48:5:0m must parse successfully")
	testing.expect(t, !is_fg, "48 must be background")
	testing.expect(t, consumed == 7, "consumed must be 7 bytes")
	testing.expect(t, idx == 0, "index must be 0")

	// End-to-end feed testing
	_sgr_feed(&parser, &term, "\x1b[38;5;196mX")
	cell := tg.terminal_get_cell(&term, 0, 0)
	st := tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.fg == tg.theme_palette_256(theme, 196), "38;5;196m must apply palette 196")

	_sgr_feed(&parser, &term, "\x1b[48;5;21mY")
	cell = tg.terminal_get_cell(&term, 0, 1)
	st = tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.bg == tg.theme_palette_256(theme, 21), "48;5;21m must apply palette 21")

	_sgr_feed(&parser, &term, "\x1b[38:5:82mZ")
	cell = tg.terminal_get_cell(&term, 0, 2)
	st = tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.fg == tg.theme_palette_256(theme, 82), "38:5:82m must apply palette 82")

	_sgr_feed(&parser, &term, "\x1b[48:5:235mW")
	cell = tg.terminal_get_cell(&term, 0, 3)
	st = tg.style_table_get(&term.grid.style_table, cell.style)
	testing.expect(t, st.bg == tg.theme_palette_256(theme, 235), "48:5:235m must apply palette 235")
}

@(test)
test_fast_path_sgr_text_attributes :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Bold (1) and clear (22)
	_sgr_feed(&parser, &term, "\x1b[1mA")
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "1 must set BOLD")
	_sgr_feed(&parser, &term, "\x1b[22mB")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD == 0, "22 must clear BOLD")

	// Dim (2) and clear (22)
	_sgr_feed(&parser, &term, "\x1b[2mC")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM != 0, "2 must set DIM")
	_sgr_feed(&parser, &term, "\x1b[22mD")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM == 0, "22 must clear DIM")

	// Italic (3) and clear (23)
	_sgr_feed(&parser, &term, "\x1b[3mE")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_ITALIC != 0, "3 must set ITALIC")
	_sgr_feed(&parser, &term, "\x1b[23mF")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_ITALIC == 0, "23 must clear ITALIC")

	// Underline (4) and clear (24)
	_sgr_feed(&parser, &term, "\x1b[4mG")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE != 0, "4 must set UNDERLINE")
	_sgr_feed(&parser, &term, "\x1b[24mH")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE == 0, "24 must clear UNDERLINE")

	// Inverse (7) and clear (27)
	_sgr_feed(&parser, &term, "\x1b[7mI")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_INVERSE != 0, "7 must set INVERSE")
	_sgr_feed(&parser, &term, "\x1b[27mJ")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_INVERSE == 0, "27 must clear INVERSE")

	// Strike (9) and clear (29)
	_sgr_feed(&parser, &term, "\x1b[9mK")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_STRIKE != 0, "9 must set STRIKE")
	_sgr_feed(&parser, &term, "\x1b[29mL")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_STRIKE == 0, "29 must clear STRIKE")

	// Compound attributes: 1;31m (Bold + Red FG)
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[1;31mM")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "1;31m must set BOLD")
	testing.expect(t, st.fg == tg.theme_palette_256(term.grid.style_table.theme, 1), "1;31m must set red fg")

	// Multi-compound: 1;3;4;42m (Bold + Italic + Underline + Green BG)
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[1;3;4;42mN")
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "Compound must set BOLD")
	testing.expect(t, st.flags & tg.STYLE_FLAG_ITALIC != 0, "Compound must set ITALIC")
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE != 0, "Compound must set UNDERLINE")
	testing.expect(t, st.bg == tg.theme_palette_256(term.grid.style_table.theme, 2), "Compound must set green bg")
}

@(test)
test_fast_path_cursor_controls :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Bare commands
	tg.terminal_move_cursor(&term, 10, 10)
	_sgr_feed(&parser, &term, "\x1b[H")
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 0, "Bare H must move to 0,0")

	tg.terminal_move_cursor(&term, 10, 10)
	_sgr_feed(&parser, &term, "\x1b[f")
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 0, "Bare f must move to 0,0")

	tg.terminal_move_cursor(&term, 10, 10)
	_sgr_feed(&parser, &term, "\x1b[A")
	testing.expect(t, term.cursor.row == 9 && term.cursor.col == 10, "Bare A must move up 1")

	_sgr_feed(&parser, &term, "\x1b[B")
	testing.expect(t, term.cursor.row == 10 && term.cursor.col == 10, "Bare B must move down 1")

	_sgr_feed(&parser, &term, "\x1b[C")
	testing.expect(t, term.cursor.row == 10 && term.cursor.col == 11, "Bare C must move right 1")

	_sgr_feed(&parser, &term, "\x1b[D")
	testing.expect(t, term.cursor.row == 10 && term.cursor.col == 10, "Bare D must move left 1")

	_sgr_feed(&parser, &term, "\x1b[G")
	testing.expect(t, term.cursor.row == 10 && term.cursor.col == 0, "Bare G must move col to 0")

	_sgr_feed(&parser, &term, "\x1b[d")
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 0, "Bare d must move row to 0")

	// 1 param commands
	tg.terminal_move_cursor(&term, 10, 10)
	_sgr_feed(&parser, &term, "\x1b[4A")
	testing.expect(t, term.cursor.row == 6 && term.cursor.col == 10, "4A must move up 4")

	_sgr_feed(&parser, &term, "\x1b[5B")
	testing.expect(t, term.cursor.row == 11 && term.cursor.col == 10, "5B must move down 5")

	_sgr_feed(&parser, &term, "\x1b[6C")
	testing.expect(t, term.cursor.row == 11 && term.cursor.col == 16, "6C must move right 6")

	_sgr_feed(&parser, &term, "\x1b[3D")
	testing.expect(t, term.cursor.row == 11 && term.cursor.col == 13, "3D must move left 3")

	_sgr_feed(&parser, &term, "\x1b[25G")
	testing.expect(t, term.cursor.row == 11 && term.cursor.col == 24, "25G must move col to 24")

	_sgr_feed(&parser, &term, "\x1b[8d")
	testing.expect(t, term.cursor.row == 7 && term.cursor.col == 24, "8d must move row to 7")

	_sgr_feed(&parser, &term, "\x1b[15H")
	testing.expect(t, term.cursor.row == 14 && term.cursor.col == 0, "15H must move row to 14, col to 0")

	_sgr_feed(&parser, &term, "\x1b[5f")
	testing.expect(t, term.cursor.row == 4 && term.cursor.col == 0, "5f must move row to 4, col to 0")

	// 2 params CUP / HVP
	_sgr_feed(&parser, &term, "\x1b[12;34H")
	testing.expect(t, term.cursor.row == 11 && term.cursor.col == 33, "12;34H must move to 11, 33")

	_sgr_feed(&parser, &term, "\x1b[7;19f")
	testing.expect(t, term.cursor.row == 6 && term.cursor.col == 18, "7;19f must move to 6, 18")

	_sgr_feed(&parser, &term, "\x1b[0;0H")
	testing.expect(t, term.cursor.row == 0 && term.cursor.col == 0, "0;0H must clamp to 0, 0")

	// Erase in Line: EL (0: to end, 1: to start, 2: all)
	_sgr_feed(&parser, &term, "\x1b[1;1HABCDEF")
	_sgr_feed(&parser, &term, "\x1b[1;3H\x1b[0K") // cursor at col 2 (0-indexed), erase to end
	testing.expect(t, tg.terminal_get_cell(&term, 0, 0).content == 'A', "cell 0 untouched")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 1).content == 'B', "cell 1 untouched")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 2).content == 0, "cell 2 cleared")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 3).content == 0, "cell 3 cleared")

	_sgr_feed(&parser, &term, "\x1b[1;1HABCDEF")
	_sgr_feed(&parser, &term, "\x1b[1;4H\x1b[1K") // cursor at col 3 (0-indexed), erase to start
	testing.expect(t, tg.terminal_get_cell(&term, 0, 0).content == 0, "cell 0 cleared")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 3).content == 0, "cell 3 cleared")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 4).content == 'E', "cell 4 untouched")

	_sgr_feed(&parser, &term, "\x1b[1;1HABCDEF")
	_sgr_feed(&parser, &term, "\x1b[1;3H\x1b[2K") // erase entire line
	testing.expect(t, tg.terminal_get_cell(&term, 0, 0).content == 0, "cell 0 cleared")
	testing.expect(t, tg.terminal_get_cell(&term, 0, 5).content == 0, "cell 5 cleared")

	// Erase in Display: ED (0: to end, 1: to start, 2: all)
	_sgr_feed(&parser, &term, "\x1b[1;1HHELLO\x1b[2;1HWORLD")
	_sgr_feed(&parser, &term, "\x1b[2J") // clear all
	testing.expect(t, tg.terminal_get_cell(&term, 0, 0).content == 0, "ED 2 clears all row 0")
	testing.expect(t, tg.terminal_get_cell(&term, 1, 0).content == 0, "ED 2 clears all row 1")
}

@(test)
test_fast_path_fallbacks_and_edge_cases :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// fast_parse_sgr_256 rejections
	_, ok, _, _ := p.fast_parse_sgr_256(transmute([]u8)string("38;5;256m"))
	testing.expect(t, !ok, "256-color > 255 must be rejected")

	_, ok, _, _ = p.fast_parse_sgr_256(transmute([]u8)string("38;5;m"))
	testing.expect(t, !ok, "missing index must be rejected")

	_, ok, _, _ = p.fast_parse_sgr_256(transmute([]u8)string("38;5;123;1m"))
	testing.expect(t, !ok, "compound 256-color must be rejected by fast_parse_sgr_256")

	_, ok, _, _ = p.fast_parse_sgr_256(transmute([]u8)string("58;5;10m"))
	testing.expect(t, !ok, "58 (underline color) must be rejected by fast_parse_sgr_256")

	// fast_parse_sgr_basic rejections
	_, ok = p.fast_parse_sgr_basic(transmute([]u8)string("38;5;123m"), &term)
	testing.expect(t, !ok, "38 code must be rejected by fast_parse_sgr_basic")

	_, ok = p.fast_parse_sgr_basic(transmute([]u8)string("48;5;123m"), &term)
	testing.expect(t, !ok, "48 code must be rejected by fast_parse_sgr_basic")

	_, ok = p.fast_parse_sgr_basic(transmute([]u8)string("58;2;1;2;3m"), &term)
	testing.expect(t, !ok, "58 code must be rejected by fast_parse_sgr_basic")

	_, ok = p.fast_parse_sgr_basic(transmute([]u8)string("999m"), &term)
	testing.expect(t, !ok, "unknown code 999 must be rejected by fast_parse_sgr_basic")

	_, ok = p.fast_parse_sgr_basic(transmute([]u8)string("1;31"), &term)
	testing.expect(t, !ok, "unterminated basic SGR must be rejected")

	// fast_parse_cursor rejections
	_, ok = p.fast_parse_cursor(transmute([]u8)string("4J"), &term)
	testing.expect(t, !ok, "J mode 4 must be rejected")

	_, ok = p.fast_parse_cursor(transmute([]u8)string("3K"), &term)
	testing.expect(t, !ok, "K mode 3 must be rejected")

	_, ok = p.fast_parse_cursor(transmute([]u8)string("10;20Z"), &term)
	testing.expect(t, !ok, "unknown 2-param command Z must be rejected")

	_, ok = p.fast_parse_cursor(transmute([]u8)string("10;"), &term)
	testing.expect(t, !ok, "incomplete 2-param command must be rejected")

	// Fallback through parse_chunk to VT state machine for sequences fast path rejects
	// E.g. compound 38;5 sequence with other params: ESC[1;38;5;196m
	_sgr_feed(&parser, &term, "\x1b[0m")
	_sgr_feed(&parser, &term, "\x1b[1;38;5;196mFallback")
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "VT state machine handles bold in compound 256 SGR")
	testing.expect(t, st.fg == tg.theme_palette_256(term.grid.style_table.theme, 196), "VT state machine handles color in compound 256 SGR")

	// Truncated buffers safely processed without panic
	_sgr_feed(&parser, &term, "\x1b[")
	_sgr_feed(&parser, &term, "\x1b[3")
	_sgr_feed(&parser, &term, "\x1b[38;")
}

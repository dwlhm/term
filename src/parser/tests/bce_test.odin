package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

@(test)
test_background_color_erase :: proc(t: ^testing.T) {
	Case :: struct { sequence: string, first, last: int }
	cases := []Case{
		{"\x1b[K", 8, 11}, {"\x1b[1K", 6, 8}, {"\x1b[2K", 6, 11},
		{"\x1b[J", 8, 17}, {"\x1b[1J", 0, 8}, {"\x1b[2J", 0, 17},
		{"\x1b[2X", 8, 9}, {"\x1b[999X", 8, 11},
	}
	for c in cases {
		term := new(tg.Terminal)
		tg.terminal_init(term, 3, 6)
		parser: p.Parser
		p.parser_init(&parser)
		p.parse_chunk(&parser, term, transmute([]u8)string("abcdefghijklmnopqr"))
		p.parse_chunk(&parser, term, transmute([]u8)string("\x1b[2;3H\x1b]8;;https://example.com\x1b\\\x1b[1;4;7;48;2;57;57;71m"))
		p.parse_chunk(&parser, term, transmute([]u8)c.sequence)
		for i in 0..<18 {
			cell := tg.terminal_get_cell(term, i / 6, i % 6)
			want := tg.style_table_default(&term.grid.style_table)
			selected := i >= c.first && i <= c.last
			testing.expect_value(t, tg.style_table_get(&term.grid.style_table, cell.style), want)
			testing.expect_value(t, cell.content, selected ? u32(0) : u32('a' + i))
			testing.expect_value(t, cell.width, u8(1))
			phys := tg._grid_physical_row(&term.grid, i / 6)
			if selected {
				testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) != 0)
				testing.expect_value(t, term.grid.rows[phys].ext.colors[i % 6].bg, u32(0xFF393947))
			} else {
				testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) == 0)
			}
		}
		testing.expect_value(t, term.cursor.row, 1)
		testing.expect_value(t, term.cursor.col, 2)
		p.parse_chunk(&parser, term, transmute([]u8)string("\x1bc"))
		for row in 0..<3 { for col in 0..<6 {
			testing.expect_value(t, tg.terminal_get_cell(term, row, col), tg.CELL_DEFAULT)
		}}
		tg.terminal_destroy(term)
		free(term)
	}
}

@(test)
test_background_erase_wide_and_empty :: proc(t: ^testing.T) {
	sequences := []string{"\x1b[2G\x1b[K", "\x1b[1G\x1b[1K", "\x1b[2G\x1b[X"}
	for sequence in sequences {
		term := new(tg.Terminal)
		tg.terminal_init(term, 1, 6)
		parser: p.Parser
		p.parser_init(&parser)
		p.parse_chunk(&parser, term, transmute([]u8)string("中\u0301\x1b[48;2;57;57;71m"))
		testing.expect(t, term.grapheme_store.live_count > 0)
		p.parse_chunk(&parser, term, transmute([]u8)sequence)
		for col in 0..<2 {
			cell := tg.terminal_get_cell(term, 0, col)
			testing.expect_value(t, cell.content, u32(0))
			phys := tg._grid_physical_row(&term.grid, 0)
			testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) != 0)
			testing.expect_value(t, term.grid.rows[phys].ext.colors[col].bg, u32(0xFF393947))
		}
		testing.expect_value(t, term.grapheme_store.live_count, 0)
		tg.terminal_destroy(term)
		free(term)
	}
	empty := new(tg.Terminal)
	defer free(empty)
	tg.terminal_erase_line(empty, .Entire)
	tg.terminal_erase_display(empty, .Entire)
	tg.terminal_erase_chars(empty, 1)
	tg.terminal_erase_line(nil, .Entire)
	tg.terminal_erase_display(nil, .Entire)
}

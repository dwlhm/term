package termgrid_test

import "core:testing"
import "core:fmt"
import tg "../"
import p "../../parser"

@(test)
test_row_extensions_init :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.grid.ext_colors != nil, "grid.ext_colors must be allocated")
	testing.expect(t, len(term.grid.ext_colors) >= 24 * 80, "grid.ext_colors size check")
	for i in 0..<term.grid.row_count {
		phys := tg._grid_physical_row(&term.grid, i)
		testing.expect(t, term.grid.rows[phys].ext.colors != nil, "row.ext.colors must be non-nil")
		testing.expect(t, len(term.grid.rows[phys].ext.colors) == 80, "row.ext.colors length must match col_count")
		testing.expect(t, term.grid.rows[phys].ext.channels == {}, "initial channels must be empty")
	}

	testing.expect(t, term.scrollback.ext_colors != nil, "scrollback.ext_colors must be allocated")
	testing.expect(t, len(term.scrollback.ext_colors) >= term.scrollback.max_lines * 80, "scrollback.ext_colors size check")
	for i in 0..<term.scrollback.max_lines {
		testing.expect(t, term.scrollback.rows[i].ext.colors != nil, "scrollback row.ext.colors must be non-nil")
		testing.expect(t, len(term.scrollback.rows[i].ext.colors) == 80, "scrollback row.ext.colors length must match col_count")
	}
}

@(test)
test_direct_color_write :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	fg_color: u32 = 0xFF123456
	bg_color: u32 = 0xFF654321
	tg.terminal_set_direct_fg(&term, fg_color)
	tg.terminal_set_direct_bg(&term, bg_color)
	tg.terminal_put_char(&term, 'X')

	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Has_Extension) != 0, "cell must have Has_Extension flag")
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) != 0, "cell must have Direct_Color flag")

	phys := tg._grid_physical_row(&term.grid, 0)
	row := &term.grid.rows[phys]
	testing.expect(t, .Direct_Color in row.ext.channels, "row must have Direct_Color channel")
	testing.expect(t, row.ext.colors[0].fg == fg_color, "direct fg color must match")
	testing.expect(t, row.ext.colors[0].bg == bg_color, "direct bg color must match")

	// Reset direct colors and write standard char
	tg.terminal_reset_direct_fg(&term)
	tg.terminal_reset_direct_bg(&term)
	tg.terminal_put_char(&term, 'Y')

	cell2 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, u8(cell2.flags) & u8(tg.Cell_Flags.Direct_Color) == 0, "cell2 must NOT have Direct_Color flag")
	testing.expect(t, row.ext.colors[1].fg == 0, "cell2 direct fg color must be 0")
	testing.expect(t, row.ext.colors[1].bg == 0, "cell2 direct bg color must be 0")
}

@(test)
test_scrollback_truecolor_preservation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 2, 10)
	defer tg.terminal_destroy(&term)

	fg_color: u32 = 0xFFAABBCC
	bg_color: u32 = 0xFF112233
	tg.terminal_set_direct_fg(&term, fg_color)
	tg.terminal_set_direct_bg(&term, bg_color)

	// Write line 0 with truecolor
	tg.terminal_put_string(&term, "LINE0")
	tg.terminal_newline(&term)

	// Write line 1 with truecolor
	tg.terminal_put_string(&term, "LINE1")
	tg.terminal_newline(&term) // scrolls LINE0 into scrollback!

	testing.expect(t, tg.scrollback_len(&term.scrollback) >= 1, "scrollback should have at least 1 row")
	sb_row := tg.scrollback_get(&term.scrollback, 0)
	testing.expect(t, sb_row != nil, "scrollback row must not be nil")
	testing.expect(t, .Direct_Color in sb_row.ext.channels, "scrollback row must retain Direct_Color channel")
	testing.expect(t, sb_row.ext.colors[0].fg == fg_color, "scrollback row direct fg must be preserved")
	testing.expect(t, sb_row.ext.colors[0].bg == bg_color, "scrollback row direct bg must be preserved")
}

@(test)
test_sgr_truecolor_no_style_overflow :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	initial_style_count := term.grid.style_table.count

	// Feed 2000 different truecolor sequences (far beyond STYLE_TABLE_CAPACITY = 1024)
	buf: [64]u8
	for i in 0..<2000 {
		r := u8((i * 7) & 0xFF)
		g := u8((i * 13) & 0xFF)
		b := u8((i * 19) & 0xFF)
		seq := fmt.bprintf(buf[:], "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm#", r, g, b, b, g, r)
		p.parse_chunk(&parser, &term, transmute([]u8)seq)
	}

	// Verify style table did NOT grow or overflow
	testing.expect(t, term.grid.style_table.count == initial_style_count, "style table count must not increase for truecolor")
	testing.expect(t, term.grid.style_table.count < tg.STYLE_TABLE_CAPACITY, "style table must not be full")
}

@(test)
test_resize_reflow_truecolor_preservation :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 10)
	defer tg.terminal_destroy(&term)

	fg_color: u32 = 0xFF112233
	bg_color: u32 = 0xFF445566
	tg.terminal_set_direct_fg(&term, fg_color)
	tg.terminal_set_direct_bg(&term, bg_color)
	tg.terminal_put_string(&term, "0123456789") // fills 10 cols

	// Resize to cols = 5 (should wrap line into 2 rows)
	tg.terminal_resize(&term, 4, 5)

	// Check row 0
	phys0 := tg._grid_physical_row(&term.grid, 0)
	testing.expect(t, .Direct_Color in term.grid.rows[phys0].ext.channels, "reflowed row 0 must have Direct_Color channel")
	testing.expect_value(t, term.grid.rows[phys0].ext.colors[0].fg, fg_color)
	testing.expect_value(t, term.grid.rows[phys0].ext.colors[0].bg, bg_color)

	// Check row 1 (wrapped part)
	phys1 := tg._grid_physical_row(&term.grid, 1)
	testing.expect(t, .Direct_Color in term.grid.rows[phys1].ext.channels, "reflowed row 1 must have Direct_Color channel")
	testing.expect_value(t, term.grid.rows[phys1].ext.colors[0].fg, fg_color)
	testing.expect_value(t, term.grid.rows[phys1].ext.colors[0].bg, bg_color)

	// Check terminal_view_get_direct_color
	view: tg.Terminal_View
	c0 := tg.terminal_view_get_direct_color(&term, &view, 0, 0)
	testing.expect(t, c0 != nil, "c0 must not be nil")
	if c0 != nil {
		testing.expect_value(t, c0.fg, fg_color)
		testing.expect_value(t, c0.bg, bg_color)
	}
	c1 := tg.terminal_view_get_direct_color(&term, &view, 1, 0)
	testing.expect(t, c1 != nil, "c1 must not be nil")
	if c1 != nil {
		testing.expect_value(t, c1.fg, fg_color)
		testing.expect_value(t, c1.bg, bg_color)
	}
}

@(test)
test_terminal_sync_copies_direct_color :: proc(t: ^testing.T) {
	src: tg.Terminal
	tg.terminal_init(&src, 4, 10)
	defer tg.terminal_destroy(&src)

	dst: tg.Terminal
	tg.terminal_init(&dst, 4, 10)
	defer tg.terminal_destroy(&dst)

	fg_color: u32 = 0xFFAABBCC
	bg_color: u32 = 0xFFDDEEFF
	tg.terminal_set_direct_fg(&src, fg_color)
	tg.terminal_set_direct_bg(&src, bg_color)
	tg.terminal_put_string(&src, "SYNC")

	// 1. Full grid sync simulation (matches backend _terminal_sync_to_front full copy)
	copy(dst.grid.cells, src.grid.cells)
	if dst.grid.ext_colors != nil && src.grid.ext_colors != nil {
		copy(dst.grid.ext_colors, src.grid.ext_colors)
	}
	for i in 0..<src.grid.capacity {
		if i < len(dst.grid.rows) && i < len(src.grid.rows) {
			dst.grid.rows[i].generation = src.grid.rows[i].generation
			dst.grid.rows[i].wrapped = src.grid.rows[i].wrapped
			dst.grid.rows[i].is_prompt = src.grid.rows[i].is_prompt
			dst.grid.rows[i].ext.channels = src.grid.rows[i].ext.channels
		}
	}

	phys := tg._grid_physical_row(&dst.grid, 0)
	testing.expect(t, .Direct_Color in dst.grid.rows[phys].ext.channels, "dst row must have Direct_Color channel after full sync")
	testing.expect_value(t, dst.grid.rows[phys].ext.colors[0].fg, fg_color)
	testing.expect_value(t, dst.grid.rows[phys].ext.colors[0].bg, bg_color)

	view: tg.Terminal_View
	c := tg.terminal_view_get_direct_color(&dst, &view, 0, 0)
	testing.expect(t, c != nil, "dst direct color via view must not be nil")
	if c != nil {
		testing.expect_value(t, c.fg, fg_color)
		testing.expect_value(t, c.bg, bg_color)
	}

	// 2. Delta row sync simulation (matches backend _terminal_sync_to_front delta copy)
	dst.grid.rows[phys].ext.channels = {}
	dst.grid.rows[phys].ext.colors[0] = {}

	src_phys := tg._grid_physical_row(&src.grid, 0)
	dst_phys := tg._grid_physical_row(&dst.grid, 0)
	copy(dst.grid.rows[dst_phys].cells, src.grid.rows[src_phys].cells)
	dst.grid.rows[dst_phys].generation = src.grid.rows[src_phys].generation
	dst.grid.rows[dst_phys].wrapped = src.grid.rows[src_phys].wrapped
	dst.grid.rows[dst_phys].is_prompt = src.grid.rows[src_phys].is_prompt
	dst.grid.rows[dst_phys].ext.channels = src.grid.rows[src_phys].ext.channels
	if len(dst.grid.rows[dst_phys].ext.colors) > 0 && len(src.grid.rows[src_phys].ext.colors) > 0 {
		copy(dst.grid.rows[dst_phys].ext.colors, src.grid.rows[src_phys].ext.colors)
	}

	testing.expect(t, .Direct_Color in dst.grid.rows[dst_phys].ext.channels, "dst row must have Direct_Color channel after delta sync")
	testing.expect_value(t, dst.grid.rows[dst_phys].ext.colors[0].fg, fg_color)
	testing.expect_value(t, dst.grid.rows[dst_phys].ext.colors[0].bg, bg_color)
	c_delta := tg.terminal_view_get_direct_color(&dst, &view, 0, 0)
	testing.expect(t, c_delta != nil, "dst direct color via delta sync must not be nil")
}

@(test)
test_fast_path_block_element_direct_color :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	fg_color: u32 = 0xFFAABBCC
	bg_color: u32 = 0xFF112233
	tg.terminal_set_direct_fg(&term, fg_color)
	tg.terminal_set_direct_bg(&term, bg_color)

	// U+2580 is upper half block '▀'
	block_char: rune = 0x2580
	tg.terminal_put_char(&term, block_char)

	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect_value(t, rune(cell.content), block_char)
	testing.expect_value(t, cell.width, 1)
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Has_Extension) != 0, "cell must have Has_Extension flag")
	testing.expect(t, u8(cell.flags) & u8(tg.Cell_Flags.Direct_Color) != 0, "cell must have Direct_Color flag")

	phys := tg._grid_physical_row(&term.grid, 0)
	row := &term.grid.rows[phys]
	testing.expect(t, .Direct_Color in row.ext.channels, "row must have Direct_Color channel")
	testing.expect_value(t, row.ext.colors[0].fg, fg_color)
	testing.expect_value(t, row.ext.colors[0].bg, bg_color)

	// Verify contiguous damage span coalescing
	tg.terminal_put_char(&term, 0x2584)
	dr := &term.damage.dirty_rows[0]
	testing.expect_value(t, dr.span_count, 1)
	testing.expect_value(t, dr.spans[0].col_start, 0)
	testing.expect_value(t, dr.spans[0].col_end, 2)
}


package terminal_tests

// Paint must restore the per-cell underline shape (SGR 4:n / 21) and colour
// (SGR 58 / 59), which live in the parallel cell side storage.

import "core:mem"
import "core:strings"
import "core:testing"
import term "../"
import cell "../cell"
import grid "../grid"

PAINT_UNDERLINE_SCENE ::
	"\x1b[4:0mA" +
	"\x1b[4:1mB" +
	"\x1b[4:2mC" +
	"\x1b[4:3;58:2::255:0:0mD" +
	"\x1b[4:4;58;5;196mE" +
	"\x1b[4:5;58:5:33mF" +
	"\x1b[59mG" +
	"\x1b[21mH" +
	"\x1b[0mI" +
	"\x1b[4:3;58;5;200m" // leave the pen itself in a curly/palette state

PAINT_UNDERLINE_STYLES := [9]cell.Underline_Style{
	.None,
	.Single,
	.Double,
	.Curly,
	.Dotted,
	.Dashed,
	.Dashed,
	.Double,
	.None,
}

_paint_underline_cell :: proc(t: ^testing.T, term_val: ^term.Terminal, col: int) -> (cell.Semantic_Cell, cell.Direct_Color) {
	row := grid.grid_get_row(&term_val.grid, 0)
	if !testing.expectf(t, row != nil, "row 0 missing") do return {}, {}
	return row.cells[col], row.direct_colors[col]
}

@test
test_paint_underline_styles_and_colors_round_trip :: proc(t: ^testing.T) {
	src, dst: term.Terminal
	term.terminal_init(&src, 4, 30)
	defer term.terminal_destroy(&src)
	term.terminal_feed_string(&src, PAINT_UNDERLINE_SCENE)

	for style, c in PAINT_UNDERLINE_STYLES {
		sc, dc := _paint_underline_cell(t, &src, c)
		testing.expectf(t, cell.cell_underline_style(sc, dc) == style, "col %d style %v != %v", c, cell.cell_underline_style(sc, dc), style)
		expect_underline := style != .None
		testing.expectf(t, (.Underline in sc.style) == expect_underline, "col %d underline flag", c)
	}

	_, curly_dc := _paint_underline_cell(t, &src, 3)
	testing.expect_value(t, curly_dc.underline.mode, cell.Underline_Color_Mode.Rgb)
	testing.expect_value(t, curly_dc.underline.rgb, [3]u8{255, 0, 0})
	_, dotted_dc := _paint_underline_cell(t, &src, 4)
	testing.expect_value(t, dotted_dc.underline.mode, cell.Underline_Color_Mode.Palette)
	testing.expect_value(t, dotted_dc.underline.index, u8(196))
	_, default_dc := _paint_underline_cell(t, &src, 6)
	testing.expect_value(t, default_dc.underline.mode, cell.Underline_Color_Mode.Default)

	out := make([dynamic]u8, 0, 4096)
	defer delete(out)
	term.terminal_paint(&src, &out, 0)
	painted := string(out[:])
	testing.expect(t, strings.contains(painted, "4:3"), "paint must emit the curly underline shape")
	testing.expect(t, strings.contains(painted, "4:5"), "paint must emit the dashed underline shape")
	testing.expect(t, strings.contains(painted, "58:2::255:0:0"), "paint must emit the RGB underline colour")
	testing.expect(t, strings.contains(painted, "58;5;196"), "paint must emit the 256 underline colour")

	term.terminal_init(&dst, 4, 30)
	defer term.terminal_destroy(&dst)
	term.terminal_feed_bytes(&dst, out[:])
	testing.expect(t, term.terminal_parser_at_ground(&dst))
	_paint_expect_state_equal(t, &src, &dst)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, 0, 4)

	for c in 0 ..< 9 {
		sa, da := _paint_underline_cell(t, &src, c)
		sb, db := _paint_underline_cell(t, &dst, c)
		testing.expectf(t, sa == sb, "col %d cell differs: %v != %v", c, sa, sb)
		testing.expectf(t, da.underline == db.underline, "col %d underline colour differs", c)
		testing.expectf(t, da.underline_style == db.underline_style, "col %d underline style differs", c)
	}
}

@test
test_paint_underline_steady_state_zero_alloc :: proc(t: ^testing.T) {
	term_val: term.Terminal
	term.terminal_init(&term_val, 6, 40)
	defer term.terminal_destroy(&term_val)
	stream := transmute([]u8)string("\x1b[4:3;58:2::255:0:0mcurly\x1b[0m")
	term.terminal_feed_bytes(&term_val, stream)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&track)
	for _ in 0 ..< 50 do term.terminal_feed_bytes(&term_val, stream)
	testing.expect_value(t, track.total_allocation_count, 0)
}

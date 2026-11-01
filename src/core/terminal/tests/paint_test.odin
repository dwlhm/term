package terminal_tests

// terminal_paint must rebuild a Terminal in a fresh one of the same size: the
// core paints a session for every newly attached viewer.

import "core:testing"
import term "../"
import cell "../cell"
import extension "../extension"
import grid "../grid"

PAINT_SCENE_MAIN ::
	"\x1b]2;paint title\x1b\\" +
	"\x1b[1;3;31mred\x1b[0m \x1b[38;5;200m256\x1b[48;2;1;2;3mrgb\x1b[0m " +
	"\x1b[4;5;7;8;9;2mstyles\x1b[0m\r\n" +
	"wide中x 👍🏽 é \x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\ \x1b[44mbce\x1b[K\x1b[0m\r\n" +
	"0123456789012345678901234567890123456789wrapped\r\n"

PAINT_SCENE_ALT ::
	"\x1b[?1049h\x1b[H\x1b[2JALT \x1b[92;48;5;17mscreen\x1b[0m\r\nline2" +
	"\x1b[2;5r\x1b[?6h\x1b[2;4H\x1b[1;38;2;9;8;7m" +
	"\x1b[?1h\x1b=\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[>1u\x1b[>5u" +
	"\x1b[6 q\x1b[?25l\x1b(0\x1b)A\x0e"

_paint_scene :: proc(terminal: ^term.Terminal) {
	term.terminal_init(terminal, 6, 30)
	for i in 0 ..< 12 do term.terminal_feed_string(terminal, "history line\r\n")
	term.terminal_feed_string(terminal, PAINT_SCENE_MAIN)
	term.terminal_feed_string(terminal, PAINT_SCENE_ALT)
}

_paint_expect_rows_equal :: proc(t: ^testing.T, a, b: ^term.Terminal, ga, gb: ^grid.Grid, from, to: int) {
	for r in from ..< to {
		ra, rb := grid.grid_get_row(ga, r), grid.grid_get_row(gb, r)
		if !testing.expectf(t, ra != nil && rb != nil, "row %d missing", r) do return
		testing.expectf(t, ra.wrap == rb.wrap, "row %d wrap %v != %v", r, ra.wrap, rb.wrap)
		for c in 0 ..< len(ra.cells) {
			ca, cb := ra.cells[c], rb.cells[c]
			da, db := ra.direct_colors[c], rb.direct_colors[c]
			if .Has_Egc in ca.flags {
				ea, eb := term.terminal_get_egc_runes(a, ca.char), term.terminal_get_egc_runes(b, cb.char)
				testing.expectf(t, len(ea) == len(eb) && (len(ea) == 0 || ea[0] == eb[0]), "row %d col %d cluster differs", r, c)
				ca.char, cb.char = 0, 0
			}
			testing.expectf(t, ca == cb, "row %d col %d: %v != %v", r, c, ca, cb)
			testing.expectf(t, term.terminal_link_uri(a, da.link_id) == term.terminal_link_uri(b, db.link_id), "row %d col %d link differs", r, c)
			da.link_id, db.link_id = 0, 0
			if .Has_Direct_Color in ca.flags do testing.expectf(t, da == db, "row %d col %d: %v != %v", r, c, da, db)
		}
	}
}

// _paint_scene_flags collects the cell flags present on a grid's visible rows,
// proving the scene exercises wide, cluster, truecolor and hyperlink cells.
_paint_scene_flags :: proc(g: ^grid.Grid) -> (flags: cell.Cell_Flags) {
	for r in 0 ..< g.row_count {
		for c in grid.grid_get_row(g, r).cells do flags += c.flags
	}
	return
}

_paint_expect_state_equal :: proc(t: ^testing.T, a, b: ^term.Terminal) {
	pa, pb := &a.parser, &b.parser
	testing.expect_value(t, pb.in_alt_screen, pa.in_alt_screen)
	testing.expect_value(t, pb.cursor.row, pa.cursor.row)
	testing.expect_value(t, pb.cursor.col, pa.cursor.col)
	testing.expect_value(t, pb.cursor.pending_wrap, pa.cursor.pending_wrap)
	testing.expect_value(t, pb.cursor.shape, pa.cursor.shape)
	testing.expect_value(t, pb.cursor.blinking, pa.cursor.blinking)
	testing.expect_value(t, pb.cursor.visible, pa.cursor.visible)
	testing.expect_value(t, pb.cursor.active_fg, pa.cursor.active_fg)
	testing.expect_value(t, pb.cursor.active_style, pa.cursor.active_style)
	testing.expect_value(t, pb.cursor.direct_color, pa.cursor.direct_color)
	testing.expect_value(t, pb.scroll_top, pa.scroll_top)
	testing.expect_value(t, pb.scroll_bottom, pa.scroll_bottom)
	testing.expect_value(t, pb.origin_mode, pa.origin_mode)
	testing.expect_value(t, pb.autowrap, pa.autowrap)
	testing.expect_value(t, pb.cursor_key_mode, pa.cursor_key_mode)
	testing.expect_value(t, pb.keypad_app, pa.keypad_app)
	testing.expect_value(t, pb.bracketed_paste, pa.bracketed_paste)
	testing.expect_value(t, pb.mouse_mode, pa.mouse_mode)
	testing.expect_value(t, pb.mouse_format, pa.mouse_format)
	testing.expect_value(t, pb.report_focus, pa.report_focus)
	testing.expect_value(t, pb.kbd_depth, pa.kbd_depth)
	testing.expect_value(t, pb.kbd_flags, pa.kbd_flags)
	testing.expect_value(t, pb.charsets, pa.charsets)
	testing.expect_value(t, pb.gl, pa.gl)
	testing.expect_value(t, term.terminal_title(b), term.terminal_title(a))
}

@test
test_paint_round_trip :: proc(t: ^testing.T) {
	src: term.Terminal
	_paint_scene(&src)
	defer term.terminal_destroy(&src)
	testing.expect(t, src.parser.in_alt_screen && src.grid.history_count == 0)
	want_flags := cell.Cell_Flags{.Wide_Lead, .Wide_Continuation, .Has_Egc, .Has_Direct_Color, .Has_Hyperlink}
	testing.expect_value(t, _paint_scene_flags(&src.alt_grid) & want_flags, want_flags)

	out := make([dynamic]u8, 0, 4096)
	defer delete(out)
	term.terminal_paint(&src, &out, 5)

	dst: term.Terminal
	term.terminal_init(&dst, 6, 30)
	defer term.terminal_destroy(&dst)
	term.terminal_feed_bytes(&dst, out[:])

	testing.expect(t, term.terminal_parser_at_ground(&dst))
	testing.expect_value(t, dst.alt_grid.history_count, 5)
	_paint_expect_state_equal(t, &src, &dst)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, 0, 6)
	_paint_expect_rows_equal(t, &src, &dst, &src.alt_grid, &dst.alt_grid, -5, 6)

	// Leaving the alternate screen restores the same main screen and saved cursor.
	for target in ([]^term.Terminal{&src, &dst}) do term.terminal_feed_string(target, "\x1b[?1049l\x1b[r")
	_paint_expect_state_equal(t, &src, &dst)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, -5, 6)
}

@test
test_paint_pending_wrap_and_main_screen :: proc(t: ^testing.T) {
	src: term.Terminal
	term.terminal_init(&src, 3, 10)
	defer term.terminal_destroy(&src)
	term.terminal_feed_string(&src, "abc\r\n\x1b[33m0123456789")
	testing.expect(t, src.parser.cursor.pending_wrap)

	out: [dynamic]u8
	defer delete(out)
	term.terminal_paint(&src, &out, 100)

	dst: term.Terminal
	term.terminal_init(&dst, 3, 10)
	defer term.terminal_destroy(&dst)
	term.terminal_feed_bytes(&dst, out[:])
	_paint_expect_state_equal(t, &src, &dst)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, 0, 3)

	// The next glyph wraps the same way in both.
	for target in ([]^term.Terminal{&src, &dst}) do term.terminal_feed_string(target, "Z")
	_paint_expect_state_equal(t, &src, &dst)
	_paint_expect_rows_equal(t, &src, &dst, &src.grid, &dst.grid, 0, 3)
}

@test
test_paint_kitty_images_reemitted :: proc(t: ^testing.T) {
	src, dst: term.Terminal
	term.terminal_init(&src, 6, 20)
	term.terminal_init(&dst, 6, 20)
	defer term.terminal_destroy(&src)
	defer term.terminal_destroy(&dst)
	term.terminal_register_extension(&src, extension.kitty_graphics_extension_make())
	term.terminal_register_extension(&dst, extension.kitty_graphics_extension_make())

	// 2x1 RGBA image, placed at row 2 col 3 over 4x2 cells.
	term.terminal_feed_string(&src, "\x1b[3;4H\x1b_Ga=T,f=32,s=2,v=1,i=7,c=4,r=2,q=2;/wAA/wD/AP8=\x1b\\")

	out: [dynamic]u8
	defer delete(out)
	term.terminal_paint(&src, &out, 0)
	term.terminal_feed_bytes(&dst, out[:])

	ks := (^extension.Kitty_Extension)(dst.extensions.extensions[0].user_data)
	img := extension.kitty_graphics_get_image(ks, 7)
	if !testing.expect(t, img != nil, "image 7 must be re-transmitted") do return
	testing.expect_value(t, img.width, 2)
	testing.expect_value(t, img.pixels[4], 0)
	testing.expect_value(t, img.pixels[5], 0xFF)
	found := false
	for pl in ks.placements {
		if pl.is_active && pl.image_id == 7 {
			found = true
			testing.expect_value(t, pl.y_row, 2)
			testing.expect_value(t, pl.x_col, 3)
			testing.expect_value(t, pl.cols, 4)
			testing.expect_value(t, pl.rows, 2)
		}
	}
	testing.expect(t, found, "placement must be re-created")
	testing.expect_value(t, dst.parser.cursor.row, src.parser.cursor.row)
	testing.expect_value(t, dst.parser.response_len, 0)
}

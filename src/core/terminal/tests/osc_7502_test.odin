package terminal_tests

import "core:testing"
import term "../"
import ext "../extension"
import grid "../grid"

@(test)
test_osc_7502_parse_opcodes :: proc(t: ^testing.T) {
	m_probe, ok_p := ext.osc_7502_parse("?")
	testing.expect(t, ok_p && m_probe.is_probe, "probe should parse")

	m_rst, ok_r := ext.osc_7502_parse("0")
	testing.expect(t, ok_r && m_rst.op == .Reset, "reset should parse")

	m_tgt, ok_t := ext.osc_7502_parse("1;42")
	testing.expect(t, ok_t && m_tgt.op == .Target && m_tgt.id == 42, "target 42 should parse")

	m_spl, ok_s := ext.osc_7502_parse("2;1;0;0;35;1")
	testing.expect(t, ok_s && m_spl.op == .Split, "split should parse")
	testing.expect_value(t, m_spl.id, u16(1))
	testing.expect_value(t, m_spl.ratio, 35)
	testing.expect_value(t, m_spl.focus, true)

	// "Confirm" in Base64 is "Q29uZmlybQ=="
	m_pop, ok_pop := ext.osc_7502_parse("3;10;30;8;0;0;0;5;2;1;Q29uZmlybQ==")
	testing.expect(t, ok_pop && m_pop.op == .Popup, "popup should parse")
	testing.expect_value(t, m_pop.id, u16(10))
	testing.expect_value(t, m_pop.w, 30)
	testing.expect_value(t, m_pop.h, 8)
	testing.expect_value(t, m_pop.chrome, ext.Surface_Chrome.Modal)
	testing.expect_value(t, string(m_pop.title_buf[:m_pop.title_len]), "Confirm")

	_, ok_bad := ext.osc_7502_parse("99;1")
	testing.expect(t, !ok_bad, "unknown opcode should fail")
}

@(test)
test_osc_7502_probe_and_split_isolation :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 10, 40)
	defer term.terminal_destroy(&tm)

	term.terminal_feed_string(&tm, "\x1b]7502;?\x1b\\")
	buf: [128]u8
	n := term.terminal_drain_response(&tm, buf[:])
	testing.expect_value(t, string(buf[:n]), "\x1b]7502;?1\x1b\\")

	// Create right split (id=1, ratio=50, focus=1) and write to both surfaces in one chunk
	term.terminal_feed_string(&tm,
		"\x1b]7502;2;1;0;0;50;1\x1b\\" +
		"RIGHT_PANE\r\nLINE2\r\n" +
		"\x1b]7502;1;0\x07" +
		"LEFT_ROOT",
	)
	n = term.terminal_drain_response(&tm, buf[:])
	testing.expect_value(t, n, 0)

	testing.expect_value(t, tm.grid.col_count, 20)
	testing.expect_value(t, rune(term.terminal_get_cell(&tm, 0, 0).char), 'L')
	testing.expect_value(t, rune(term.terminal_get_cell(&tm, 0, 4).char), '_')

	s1 := term.terminal_surface_find(&tm, 1)
	testing.expect(t, s1 != nil, "surface 1 must exist")
	testing.expect_value(t, s1.cell_rect, [4]int{20, 0, 20, 10})
	testing.expect_value(t, rune(grid.grid_get_cell(&s1.grid, 0, 0).char), 'R')
	testing.expect_value(t, rune(grid.grid_get_cell(&s1.grid, 1, 0).char), 'L')
}

@(test)
test_osc_7502_independent_scroll :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 4, 20)
	defer term.terminal_destroy(&tm)

	term.terminal_feed_string(&tm, "\x1b]7502;2;1;0;0;50;0\x1b\\")
	term.terminal_feed_string(&tm, "\x1b]7502;1;0\x07ROOT_TOP")
	// Switch to split 1 and scroll it 6 lines
	term.terminal_feed_string(&tm, "\x1b]7502;1;1\x07A\r\nB\r\nC\r\nD\r\nE\r\nF")

	// Root (0) row 0 must still be "ROOT_TOP" untouched by split 1's scrolling
	testing.expect_value(t, rune(term.terminal_get_cell(&tm, 0, 0).char), 'R')
	testing.expect_value(t, rune(term.terminal_get_cell(&tm, 0, 5).char), 'T')

	// Split (1) scrolled so row 0..'C', row 1..'D', row 2..'E', row 3..'F'
	s1 := term.terminal_surface_find(&tm, 1)
	testing.expect_value(t, rune(grid.grid_get_cell(&s1.grid, 0, 0).char), 'C')
	testing.expect_value(t, rune(grid.grid_get_cell(&s1.grid, 3, 0).char), 'F')
}

@(test)
test_osc_7502_popup_and_lifecycle_reset :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 24, 80)
	defer term.terminal_destroy(&tm)

	term.terminal_feed_string(&tm, "\x1b[?1049h")
	// Spawn centered modal popup 20x6 with focus=1 and title "Confirm"
	term.terminal_feed_string(&tm, "\x1b]7502;3;10;20;6;0;0;0;5;2;1;Q29uZmlybQ==\x1b\\POPUP_BODY")

	p := term.terminal_surface_find(&tm, 10)
	testing.expect(t, p != nil && p.kind == .Popup && p.visible, "popup 10 must be visible")
	testing.expect_value(t, p.cell_rect, [4]int{30, 9, 20, 6})
	testing.expect_value(t, term.terminal_surface_title(p), "Confirm")
	testing.expect_value(t, rune(grid.grid_get_cell(&p.grid, 0, 0).char), 'P')

	// Hide and re-show without losing grid content
	term.terminal_feed_string(&tm, "\x1b]7502;5;10;0\x1b\\")
	testing.expect(t, !p.visible, "popup 10 should be hidden")
	term.terminal_feed_string(&tm, "\x1b]7502;5;10;1\x1b\\")
	testing.expect(t, p.visible && rune(grid.grid_get_cell(&p.grid, 0, 0).char) == 'P', "popup 10 content preserved")

	// Leaving alternate screen (?1049l) must auto-destroy all child surfaces
	term.terminal_feed_string(&tm, "\x1b[?1049l")
	testing.expect_value(t, len(tm.surfaces), 0)
	testing.expect_value(t, tm.active_surface_id, u16(0))
	testing.expect_value(t, tm.focused_surface_id, u16(0))
}

@(test)
test_osc_7502_paint_roundtrip_and_relay :: proc(t: ^testing.T) {
	src: term.Terminal
	term.terminal_init(&src, 12, 40)
	defer term.terminal_destroy(&src)

	r: term.Relay
	viewer_out := make([dynamic]u8)
	replies_out := make([dynamic]u8)
	defer delete(viewer_out)
	defer delete(replies_out)

	// Probe is answered by relay and stripped from viewer_out
	term.relay_feed(&r, &src, transmute([]u8)string("\x1b]7502;?\x1b\\"), &viewer_out, &replies_out)
	testing.expect_value(t, string(replies_out[:]), "\x1b]7502;?1\x1b\\")
	testing.expect_value(t, len(viewer_out), 0)

	// Create split 1 and popup 2, write content, and roundtrip through terminal_paint
	term.terminal_feed_string(&src,
		"\x1b[?1049h\x1b]7502;2;1;0;0;50;0\x1b\\ROOT_TXT" +
		"\x1b]7502;1;1\x07SPLIT_TXT" +
		"\x1b]7502;3;2;16;4;0;0;0;5;2;1;TW9kYWw=\x1b\\MODAL_TXT",
	)

	paint_buf := make([dynamic]u8)
	defer delete(paint_buf)
	term.terminal_paint(&src, &paint_buf, 0)

	dst: term.Terminal
	term.terminal_init(&dst, 12, 40)
	defer term.terminal_destroy(&dst)
	term.terminal_feed_bytes(&dst, paint_buf[:])

	testing.expect_value(t, len(dst.surfaces), 2)
	testing.expect_value(t, dst.focused_surface_id, u16(2))
	testing.expect_value(t, dst.active_surface_id, u16(2))
	testing.expect_value(t, rune(term.terminal_get_cell(&dst, 0, 0).char), 'R')

	ds1 := term.terminal_surface_find(&dst, 1)
	dp2 := term.terminal_surface_find(&dst, 2)
	testing.expect(t, ds1 != nil && dp2 != nil, "both surfaces reconstructed")
	testing.expect_value(t, rune(grid.grid_get_cell(&ds1.grid, 0, 0).char), 'S')
	testing.expect_value(t, rune(grid.grid_get_cell(&dp2.grid, 0, 0).char), 'M')
	testing.expect_value(t, term.terminal_surface_title(dp2), "Modal")
}

@(test)
test_osc_7502_per_surface_parser_isolation :: proc(t: ^testing.T) {
	src: term.Terminal
	term.terminal_init(&src, 12, 40)
	defer term.terminal_destroy(&src)

	// Root enables Kitty Keyboard Protocol (flags=1) and DECCKM (?1h)
	term.terminal_feed_string(&src, "\x1b[>1u\x1b[?1h")
	// Create Split 1 and enable only bracketed paste (?2004h) inside Split 1
	term.terminal_feed_string(&src, "\x1b]7502;2;1;0;0;50;1\x1b\\\x1b[?2004h")

	_, _, p0 := term.terminal_surface_parts(&src, 0)
	_, _, p1 := term.terminal_surface_parts(&src, 1)
	testing.expect_value(t, p0.kbd_flags[0], u8(1))
	testing.expect_value(t, p0.cursor_key_mode, true)
	testing.expect_value(t, p0.bracketed_paste, false)
	testing.expect_value(t, p1.kbd_depth, 0)
	testing.expect_value(t, p1.cursor_key_mode, false)
	testing.expect_value(t, p1.bracketed_paste, true)
}

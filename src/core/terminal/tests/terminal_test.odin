package terminal_tests

import "core:testing"
import term "../"
import cell "../cell"
import egc "../egc"
import damage "../damage"
import extension "../extension"
import grid "../grid"

@test
test_cell_layout :: proc(t: ^testing.T) {
	c := cell.cell_make('X', 2, 0, {.Bold, .Underline})
	testing.expect(t, c.char == 'X', "Character mismatch")
	testing.expect(t, c.fg == 2, "FG color mismatch")
	testing.expect(t, .Bold in c.style, "Bold flag missing")
	testing.expect(t, .Underline in c.style, "Underline flag missing")
	testing.expect(t, !cell.cell_is_empty(c), "Cell should not be empty")

	empty := cell.CELL_DEFAULT
	testing.expect(t, cell.cell_is_empty(empty), "Default cell should be empty")
}

@test
test_egc_pool :: proc(t: ^testing.T) {
	pool: egc.Egc_Pool
	egc.egc_pool_init(&pool)

	runes1 := []rune{'e', 0x0301} // é with combining acute
	idx1, ok1 := egc.egc_pool_alloc(&pool, runes1)
	testing.expect(t, ok1, "EGC alloc failed")

	// Dedup check: allocating identical sequence returns same index
	idx2, ok2 := egc.egc_pool_alloc(&pool, runes1)
	testing.expect(t, ok2, "EGC dedup alloc failed")
	testing.expect_value(t, idx1, idx2)

	got := egc.egc_pool_get(&pool, idx1)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], 'e')
	testing.expect_value(t, got[1], rune(0x0301))

	egc.egc_pool_release(&pool, idx1)
	egc.egc_pool_release(&pool, idx2)
	testing.expect_value(t, pool.active_cnt, 0)
}

@test
test_damage_journal :: proc(t: ^testing.T) {
	d: damage.Damage_Tracker
	damage.damage_init(&d, 24, 80)
	defer damage.damage_destroy(&d)

	damage.damage_reset(&d)
	testing.expect(t, !d.has_damage, "Damage should be empty after reset")

	damage.damage_mark_cell(&d, 5, 10, 1)
	damage.damage_mark_span(&d, 5, 11, 20, 1)

	journal := damage.damage_consume(&d)
	testing.expect(t, journal.has_damage, "Journal should record damage")
	testing.expect_value(t, journal.min_row, 5)
	testing.expect_value(t, journal.max_row, 5)
	testing.expect_value(t, journal.min_col, 10)
	testing.expect_value(t, journal.max_col, 20)

	// After consume, tracker should be reset
	testing.expect(t, !d.has_damage, "Damage should be reset after consume")
}

@test
test_grid_scroll_o1 :: proc(t: ^testing.T) {
	g: grid.Grid
	d: damage.Damage_Tracker
	grid.grid_init(&g, 4, 10)
	damage.damage_init(&d, 4, 10)
	defer grid.grid_destroy(&g)
	defer damage.damage_destroy(&d)

	// Write 'A' to row 0, 'B' to row 1
	grid.grid_set_cell(&g, &d, 0, 0, cell.cell_make('A'))
	grid.grid_set_cell(&g, &d, 1, 0, cell.cell_make('B'))

	// Scroll full grid up by 1 row
	scrolled := grid.grid_scroll_up(&g, &d, 0, 3, 1)
	testing.expect_value(t, scrolled, 1)

	// Now logical row 0 should contain 'B'
	c0 := grid.grid_get_cell(&g, 0, 0)
	testing.expect_value(t, c0.char, 'B')

	// Logical row 3 should be blank
	c3 := grid.grid_get_cell(&g, 3, 0)
	testing.expect_value(t, c3.char, ' ')
}

@test
test_parser_sgr :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed "Hello", then SGR Red Bold "World"
	term.terminal_feed_string(&terminal, "Hello \x1b[1;31mWorld\x1b[0m")

	// Check 'H'
	cH := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect_value(t, cH.char, 'H')
	testing.expect_value(t, cH.fg, 7)

	// Check 'W'
	cW := term.terminal_get_cell(&terminal, 0, 6)
	testing.expect_value(t, cW.char, 'W')
	testing.expect_value(t, cW.fg, 1) // Red
	testing.expect(t, .Bold in cW.style, "Bold style flag expected on 'W'")
}

@test
test_parser_combining_mark :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 10)
	defer term.terminal_destroy(&terminal)

	// "e" + U+0301 (combining acute) in UTF-8
	term.terminal_feed_bytes(&terminal, []u8{0x65, 0xCC, 0x81})

	c := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Egc in c.flags, "Expected Has_Egc flag on combined cell")
	runes := egc.egc_pool_get(&terminal.egc_pool, int(c.char - egc.EGC_INDEX_BASE))
	testing.expect_value(t, len(runes), 2)
	testing.expect_value(t, runes[0], 'e')
	testing.expect_value(t, runes[1], rune(0x0301))
	testing.expect_value(t, terminal.parser.cursor.col, 1)
}

@test
test_parser_zwj_emoji :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 10)
	defer term.terminal_destroy(&terminal)

	// U+1F468 (👨) + ZWJ (U+200D) + U+1F469 (👩)
	term.terminal_feed_bytes(&terminal, []u8{0xF0, 0x9F, 0x91, 0xA8, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x91, 0xA9})

	c := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Egc in c.flags, "Expected Has_Egc on ZWJ emoji")
	testing.expect(t, .Wide_Lead in c.flags, "Expected Wide_Lead on ZWJ emoji")
	runes := egc.egc_pool_get(&terminal.egc_pool, int(c.char - egc.EGC_INDEX_BASE))
	testing.expect_value(t, len(runes), 3)
	testing.expect_value(t, runes[0], rune(0x1F468))
	testing.expect_value(t, runes[1], rune(0x200D))
	testing.expect_value(t, runes[2], rune(0x1F469))

	cont := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect(t, .Wide_Continuation in cont.flags, "Expected Wide_Continuation")
	testing.expect_value(t, terminal.parser.cursor.col, 2)
}

@test
test_parser_vs16_widen :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 10)
	defer term.terminal_destroy(&terminal)

	// U+2640 (♀) + VS16 (U+FE0F): narrow text symbol widens to emoji presentation
	term.terminal_feed_bytes(&terminal, []u8{0xE2, 0x99, 0x80, 0xEF, 0xB8, 0x8F})

	c := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Egc in c.flags, "Expected Has_Egc")
	testing.expect(t, .Wide_Lead in c.flags, "Expected Wide_Lead after VS16")
	cont := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect(t, .Wide_Continuation in cont.flags, "Expected continuation")
	testing.expect_value(t, terminal.parser.cursor.col, 2)
}

import "core:strings"

// Mock state for verifying OSC extensions
Mock_Osc_State :: struct {
	osc_52_received:  bool,
	osc_52_payload:   string,
	osc_7_received:   bool,
	osc_7_payload:    string,
	osc_133_received: bool,
	osc_133_payload:  string,
	custom_received:  bool,
}

@test
test_osc_extension_dispatch :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	mock: Mock_Osc_State
	defer {
		delete(mock.osc_52_payload)
		delete(mock.osc_7_payload)
		delete(mock.osc_133_payload)
	}

	// Register specific handlers
	term.terminal_register_osc(&terminal, 52, proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
		m := (^Mock_Osc_State)(user_data)
		m.osc_52_received = true
		m.osc_52_payload = strings.clone(payload)
		return true
	}, &mock)

	term.terminal_register_osc(&terminal, 7, proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
		m := (^Mock_Osc_State)(user_data)
		m.osc_7_received = true
		m.osc_7_payload = strings.clone(payload)
		return true
	}, &mock)

	term.terminal_register_osc(&terminal, 133, proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
		m := (^Mock_Osc_State)(user_data)
		m.osc_133_received = true
		m.osc_133_payload = strings.clone(payload)
		return true
	}, &mock)

	term.terminal_register_osc(&terminal, 999, proc(user_data: rawptr, osc_id: int, payload: string, term_ptr: rawptr) -> bool {
		m := (^Mock_Osc_State)(user_data)
		m.custom_received = true
		return true
	}, &mock)

	// Feed OSC sequences terminated with BEL (0x07) or ST (\x1b\\)
	term.terminal_feed_string(&terminal, "\x1b]52;c;dGVzdA==\x07")
	term.terminal_feed_string(&terminal, "\x1b]7;file:///Users/dwlhm/project/term\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b]133;A\x07")
	term.terminal_feed_string(&terminal, "\x1b]999;custom_data\x07")

	testing.expect(t, mock.osc_52_received, "OSC 52 handler not invoked")
	testing.expect_value(t, mock.osc_52_payload, "c;dGVzdA==")

	testing.expect(t, mock.osc_7_received, "OSC 7 handler not invoked")
	testing.expect_value(t, mock.osc_7_payload, "file:///Users/dwlhm/project/term")

	testing.expect(t, mock.osc_133_received, "OSC 133 handler not invoked")
	testing.expect_value(t, mock.osc_133_payload, "A")

	testing.expect(t, mock.custom_received, "Custom OSC 999 handler not invoked")
}

@test
test_parser_utf8_multibyte :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed Box drawing (3-byte UTF-8: 0xE2 0x94 0x80 -> U+2500 '─')
	// Feed Braille (3-byte UTF-8: 0xE2 0xA0 0x81 -> U+2801 '⠁')
	// Feed Nerd Font icon (3-byte UTF-8: 0xEF 0x90 0x98 -> U+F418 '')
	// Feed Emoji (4-byte UTF-8: 0xF0 0x9F 0x9A 0x80 -> U+1F680 '🚀')
	input := "─⠁🚀"
	term.terminal_feed_string(&terminal, input)

	c0 := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect_value(t, c0.char, rune(0x2500))

	c1 := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect_value(t, c1.char, rune(0x2801))

	c2 := term.terminal_get_cell(&terminal, 0, 2)
	testing.expect_value(t, c2.char, rune(0xF418))

	// Rocket is wide (2 columns)
	c3 := term.terminal_get_cell(&terminal, 0, 3)
	testing.expect_value(t, c3.char, rune(0x1F680))
	testing.expect(t, .Wide_Lead in c3.flags, "Expected Wide_Lead flag on lead emoji cell")

	c4 := term.terminal_get_cell(&terminal, 0, 4)
	testing.expect(t, .Wide_Continuation in c4.flags, "Expected Wide_Continuation flag on continuation cell")
}

@test
test_parser_decscusr_no_qq :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed zsh/p10k startup sequence setting cursor to steady bar: \x1b[6 q\x1b[6 q
	term.terminal_feed_string(&terminal, "\x1b[6 q\x1b[6 q")

	// Ensure no 'q' character leaked onto the screen grid
	c0 := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, c0.char == ' ' || c0.char == 0, "Character grid should not contain leaked 'q' from DECSCUSR")
	testing.expect_value(t, terminal.parser.cursor.col, 0)
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	// Verify cursor shape updated to Beam and blinking false (mode 6)
	testing.expect(t, terminal.parser.cursor.shape == .Beam, "Cursor shape should be Beam for mode 6")
	testing.expect(t, terminal.parser.cursor.blinking == false, "Cursor blinking should be false for steady bar mode 6")

	// Test switching to blinking underline: \x1b[3 q
	term.terminal_feed_string(&terminal, "\x1b[3 q")
	testing.expect(t, terminal.parser.cursor.shape == .Underline, "Cursor shape should be Underline for mode 3")
	testing.expect(t, terminal.parser.cursor.blinking == true, "Cursor blinking should be true for blinking underline mode 3")

	// Feed text with embedded DECSCUSR: "Hello\x1b[2 qWorld"
	term.terminal_feed_string(&terminal, "Hello\x1b[2 qWorld")
	testing.expect(t, terminal.parser.cursor.shape == .Block, "Cursor shape should be Block for mode 2")
	testing.expect(t, terminal.parser.cursor.blinking == false, "Cursor blinking should be false for steady block mode 2")

	// Verify grid content is strictly "HelloWorld" without any extra 'q'
	expected := "HelloWorld"
	for ch, idx in expected {
		cell_val := term.terminal_get_cell(&terminal, 0, idx)
		testing.expect_value(t, cell_val.char, ch)
	}
}

@test
test_terminal_scrollback_history :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 20)
	defer term.terminal_destroy(&terminal)

	// Feed 6 lines on a 4-line terminal (causes 2 full-screen scroll-ups)
	term.terminal_feed_string(&terminal, "Line 1\r\nLine 2\r\nLine 3\r\nLine 4\r\nLine 5\r\nLine 6")

	// History count should be at least 2
	testing.expect(t, terminal.grid.history_count >= 2, "Expected history_count >= 2 after scrolling 6 lines on 4-row terminal")

	// The row immediately above the viewport is row -1 in grid indexing (should contain "Line 2")
	c_hist := term.terminal_get_cell(&terminal, -1, 0)
	testing.expect(t, c_hist.char == 'L', "Expected 'L' on scrolled history row -1")

	// Test clear history
	grid.grid_clear_history(&terminal.grid)
	testing.expect_value(t, terminal.grid.history_count, 0)
}

@test
test_terminal_alt_screen_modes :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	testing.expect(t, !terminal.parser.in_alt_screen, "Expected normal screen initially")
	testing.expect(t, !terminal.parser.cursor_key_mode, "Expected normal cursor keys initially")

	// Print cell with background color in normal screen: should NOT sample
	term.terminal_feed_string(&terminal, "\x1b[48;2;20;30;40mX\x1b[0m")
	_, _, found_normal := term.terminal_sample_bg(&terminal)
	testing.expect(t, !found_normal, "Normal screen should not sample background into pane card")

	// Enter alternate screen (?1049h) and set application cursor keys (?1h)
	term.terminal_feed_string(&terminal, "\x1b[?1049h\x1b[?1h")
	testing.expect(t, terminal.parser.in_alt_screen, "Expected in_alt_screen == true")
	testing.expect(t, terminal.parser.cursor_key_mode, "Expected cursor_key_mode == true")

	// In alternate screen (e.g. Neovim), screen is cleared and TUI draws
	term.terminal_feed_string(&terminal, "\x1b[2J\x1b[13;41H\x1b[48;2;30;40;50m \x1b[0m")
	dc_alt, _, found_alt := term.terminal_sample_bg(&terminal)
	testing.expect(t, found_alt, "Alternate screen (Neovim) should sample background for seamless blending")
	testing.expect_value(t, dc_alt.bg[0], u8(30))

	// Exit alternate screen (?1049l) and reset cursor keys (?1l)
	term.terminal_feed_string(&terminal, "\x1b[?1049l\x1b[?1l")
	testing.expect(t, !terminal.parser.in_alt_screen, "Expected in_alt_screen == false")
	testing.expect(t, !terminal.parser.cursor_key_mode, "Expected cursor_key_mode == false")

	// Once exited, sampling immediately turns off and reverts to original background
	_, _, found_after := term.terminal_sample_bg(&terminal)
	testing.expect(t, !found_after, "Exiting alternate screen must revert background sampling immediately")
}

@test
test_parser_combining_at_right_margin :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 5) // 5 columns (0..4)
	defer term.terminal_destroy(&terminal)

	// Feed "abcde" to fill row 0 completely (pending_wrap becomes true at col 4)
	term.terminal_feed_string(&terminal, "abcde")
	testing.expect(t, terminal.parser.cursor.pending_wrap, "Expected pending_wrap == true after filling row")
	testing.expect_value(t, terminal.parser.cursor.col, 4)

	// Feed combining acute: U+0301 (0xCC 0x81)
	term.terminal_feed_bytes(&terminal, []u8{0xCC, 0x81})

	// Cell at col 4 ('e') should have the combining mark attached, NOT col 3 ('d')
	c3 := term.terminal_get_cell(&terminal, 0, 3)
	testing.expect_value(t, c3.char, 'd')
	testing.expect(t, .Has_Egc not_in c3.flags, "Col 3 should not have Has_Egc")

	c4 := term.terminal_get_cell(&terminal, 0, 4)
	testing.expect(t, .Has_Egc in c4.flags, "Col 4 ('e') should have Has_Egc attached at right margin")
	runes := egc.egc_pool_get(&terminal.egc_pool, int(c4.char - egc.EGC_INDEX_BASE))
	testing.expect_value(t, len(runes), 2)
	testing.expect_value(t, runes[0], 'e')
	testing.expect_value(t, runes[1], rune(0x0301))

	// Subsequent normal char should wrap to row 1 col 0
	term.terminal_feed_string(&terminal, "x")
	c_wrap := term.terminal_get_cell(&terminal, 1, 0)
	testing.expect_value(t, c_wrap.char, 'x')
}

@test
test_osc_52_extension :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	captured_text: string
	sink_called := false

	ctx := extension.Osc_52_Context{
		sink = proc(user_data: rawptr, text: string) -> bool {
			p_text := (^string)(user_data)
			p_text^ = strings.clone(text)
			return true
		},
		user_data = &captured_text,
	}

	term.terminal_register_osc(&terminal, 52, extension.osc_52_handler, &ctx)

	// Feed valid base64 "SGVsbG8=" ("Hello")
	term.terminal_feed_string(&terminal, "\x1b]52;c;SGVsbG8=\x07")
	testing.expect_value(t, captured_text, "Hello")
	delete(captured_text)
	captured_text = ""

	// Feed query "?" -> security must reject and not call sink
	term.terminal_feed_string(&terminal, "\x1b]52;c;?\x07")
	testing.expect_value(t, captured_text, "")
}

@test
test_parser_iso2022_charset_no_stray_b :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed \x1b(B (Select ASCII into G0) and \x1b)0 (DEC special graphics)
	term.terminal_feed_string(&terminal, "\x1b(B\x1b)0Hello")
	testing.expect_value(t, terminal.parser.cursor.col, 5)

	// Verify row 0 contains "Hello" starting at col 0, NO stray 'B' or '0'
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'H')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 1).char, 'e')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 2).char, 'l')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 3).char, 'l')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 4).char, 'o')
}

@test
test_parser_dcs_and_apc_swallowed :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed XTGETTCAP DCS sequence and Kitty Graphics APC query
	term.terminal_feed_string(&terminal, "\x1bP+q4D73\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Gi=31337,s=1;AAAA\x1b\\")

	// Neither payload must be emitted onto the screen
	testing.expect_value(t, terminal.parser.cursor.col, 0)
	testing.expect_value(t, terminal.parser.cursor.row, 0)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, ' ')
}

@test
test_parser_csi_colon_subparameter :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed curly underline \x1b[4:3m then "Text"
	term.terminal_feed_string(&terminal, "\x1b[4:3mText")
	testing.expect_value(t, terminal.parser.cursor.col, 4)
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, 'T')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 1).char, 'e')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 2).char, 'x')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 3).char, 't')
}

@test
test_parser_truecolor_direct_color :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Set 24-bit TrueColor FG (255, 128, 64) and BG (10, 20, 30)
	term.terminal_feed_string(&terminal, "\x1b[38;2;255;128;64m\x1b[48;2;10;20;30mZ\x1b[0m")

	c := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect_value(t, c.char, 'Z')
	testing.expect(t, .Has_Direct_Color in c.flags, "Expected Has_Direct_Color flag on cell")

	dc := terminal.grid.rows[0].direct_colors[0]
	testing.expect(t, dc.has_fg, "Expected has_fg == true")
	testing.expect_value(t, dc.fg[0], 255)
	testing.expect_value(t, dc.fg[1], 128)
	testing.expect_value(t, dc.fg[2], 64)

	testing.expect(t, dc.has_bg, "Expected has_bg == true")
	testing.expect_value(t, dc.bg[0], 10)
	testing.expect_value(t, dc.bg[1], 20)
	testing.expect_value(t, dc.bg[2], 30)
}

@test
test_parser_queries_response :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// 1. DSR 5n -> \x1b[0n
	term.terminal_feed_string(&terminal, "\x1b[5n")
	resp: [64]u8
	n := term.terminal_drain_response(&terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[0n")

	// 2. DA1 -> \x1b[?62;c
	term.terminal_feed_string(&terminal, "\x1b[c")
	n = term.terminal_drain_response(&terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[?62;c")

	// 3. Move cursor to row 4, col 9 (1-indexed: row 5, col 10) and request CPR
	term.terminal_feed_string(&terminal, "\x1b[5;10H\x1b[6n")
	n = term.terminal_drain_response(&terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b[5;10R")
}

@test
test_osc_color_queries :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	color_cfg := extension.Osc_Color_Config{
		responder = proc(term_ptr: rawptr, response: []u8) -> bool {
			return term.terminal_emit_response(term_ptr, response)
		},
	}
	term.terminal_register_osc(&terminal, 10, extension.osc_color_handler, &color_cfg)
	term.terminal_register_osc(&terminal, 11, extension.osc_color_handler, &color_cfg)

	// Query FG
	term.terminal_feed_string(&terminal, "\x1b]10;?\x07")
	resp: [64]u8
	n := term.terminal_drain_response(&terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b]10;rgb:c6c6/d0d0/f0f0\x1b\\")

	// Query BG
	term.terminal_feed_string(&terminal, "\x1b]11;?\x07")
	n = term.terminal_drain_response(&terminal, resp[:])
	testing.expect_value(t, string(resp[:n]), "\x1b]11;rgb:1414/1616/1b1b\x1b\\")
}

@test
test_parser_bce_erase_line :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Set background to TrueColor (30, 34, 42) and Erase in Line (EL)
	term.terminal_feed_string(&terminal, "\x1b[48;2;30;34;42m\x1b[K")

	// Col 0..79 on row 0 must have Has_Direct_Color and direct background color (30, 34, 42)
	c0 := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Direct_Color in c0.flags, "Expected Has_Direct_Color on BCE erased cell")
	dc0 := terminal.grid.rows[0].direct_colors[0]
	testing.expect(t, dc0.has_bg, "Expected dc.has_bg == true")
	testing.expect_value(t, dc0.bg[0], 30)
	testing.expect_value(t, dc0.bg[1], 34)
	testing.expect_value(t, dc0.bg[2], 42)

	c79 := term.terminal_get_cell(&terminal, 0, 79)
	testing.expect(t, .Has_Direct_Color in c79.flags, "Expected Has_Direct_Color on BCE erased cell 79")
	dc79 := terminal.grid.rows[0].direct_colors[79]
	testing.expect(t, dc79.has_bg, "Expected dc.has_bg == true")
	testing.expect_value(t, dc79.bg[0], 30)
	testing.expect_value(t, dc79.bg[1], 34)
	testing.expect_value(t, dc79.bg[2], 42)
}

@test
test_parser_ech :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Write 10 characters: "0123456789", return to col 2, erase 4 characters via ECH (\x1b[4X)
	term.terminal_feed_string(&terminal, "0123456789\r\x1b[2C\x1b[4X")

	// Cursor should NOT move on ECH
	testing.expect_value(t, terminal.parser.cursor.col, 2)
	testing.expect_value(t, terminal.parser.cursor.row, 0)

	// Cols 0, 1 should remain '0', '1'
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 0).char, '0')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 1).char, '1')

	// Cols 2..5 should be erased to ' '
	for c in 2..=5 {
		testing.expect_value(t, term.terminal_get_cell(&terminal, 0, c).char, ' ')
	}

	// Cols 6..9 should remain '6', '7', '8', '9'
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 6).char, '6')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 7).char, '7')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 8).char, '8')
	testing.expect_value(t, term.terminal_get_cell(&terminal, 0, 9).char, '9')
}

@test
test_parser_ech_bce :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Set direct bg color to (50, 60, 70) and erase 5 characters
	term.terminal_feed_string(&terminal, "\x1b[48;2;50;60;70m\x1b[5X")

	for c in 0..<5 {
		cell_val := term.terminal_get_cell(&terminal, 0, c)
		testing.expect_value(t, cell_val.char, ' ')
		testing.expect(t, .Has_Direct_Color in cell_val.flags, "Expected Has_Direct_Color on BCE ECH cell")
		dc := terminal.grid.rows[0].direct_colors[c]
		testing.expect(t, dc.has_bg, "Expected dc.has_bg == true")
		testing.expect_value(t, dc.bg[0], 50)
		testing.expect_value(t, dc.bg[1], 60)
		testing.expect_value(t, dc.bg[2], 70)
	}
}

@test
test_parser_cha_vpa_cnl_cpl :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Move to col 15 via CHA (\x1b[15G) (1-indexed -> 14)
	term.terminal_feed_string(&terminal, "\x1b[15G")
	testing.expect_value(t, terminal.parser.cursor.col, 14)

	// Move to row 10 via VPA (\x1b[10d) (1-indexed -> 9)
	term.terminal_feed_string(&terminal, "\x1b[10d")
	testing.expect_value(t, terminal.parser.cursor.row, 9)

	// Cursor Next Line (\x1b[3E) -> down 3 rows, col 0
	term.terminal_feed_string(&terminal, "\x1b[3E")
	testing.expect_value(t, terminal.parser.cursor.row, 12)
	testing.expect_value(t, terminal.parser.cursor.col, 0)

	// Cursor Previous Line (\x1b[2F) -> up 2 rows, col 0
	term.terminal_feed_string(&terminal, "\x1b[2F")
	testing.expect_value(t, terminal.parser.cursor.row, 10)
	testing.expect_value(t, terminal.parser.cursor.col, 0)
}

@test
test_parser_wide_char_overwrite :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Write wide character '世' (U+4E16) at col 0 (occupies col 0 and 1)
	term.terminal_feed_string(&terminal, "世")
	c0 := term.terminal_get_cell(&terminal, 0, 0)
	c1 := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect(t, .Wide_Lead in c0.flags, "Expected Wide_Lead at col 0")
	testing.expect(t, .Wide_Continuation in c1.flags, "Expected Wide_Continuation at col 1")

	// Move cursor to col 0 and overwrite with narrow 'A'
	term.terminal_feed_string(&terminal, "\rA")
	c0_new := term.terminal_get_cell(&terminal, 0, 0)
	c1_new := term.terminal_get_cell(&terminal, 0, 1)
	testing.expect_value(t, c0_new.char, 'A')
	testing.expect(t, .Wide_Lead not_in c0_new.flags, "Wide_Lead must be removed from col 0")
	// Col 1 must have been sanitized: orphan Wide_Continuation removed
	testing.expect(t, .Wide_Continuation not_in c1_new.flags, "Orphan Wide_Continuation must be sanitized at col 1")

	// Now write wide char at cols 2..3
	term.terminal_feed_string(&terminal, "\x1b[3G界") // col 2 (1-indexed 3)
	c2 := term.terminal_get_cell(&terminal, 0, 2)
	c3 := term.terminal_get_cell(&terminal, 0, 3)
	testing.expect(t, .Wide_Lead in c2.flags, "Expected Wide_Lead at col 2")
	testing.expect(t, .Wide_Continuation in c3.flags, "Expected Wide_Continuation at col 3")

	// Overwrite col 3 (the continuation cell) with narrow 'B'
	term.terminal_feed_string(&terminal, "\x1b[4GB")
	c2_new := term.terminal_get_cell(&terminal, 0, 2)
	c3_new := term.terminal_get_cell(&terminal, 0, 3)
	testing.expect_value(t, c3_new.char, 'B')
	testing.expect(t, .Wide_Continuation not_in c3_new.flags, "Wide_Continuation must be removed from col 3")
	// Col 2 (the lead) must have been neutralized to space
	testing.expect_value(t, c2_new.char, ' ')
	testing.expect(t, .Wide_Lead not_in c2_new.flags, "Orphan Wide_Lead must be neutralized at col 2")
}

@test
test_parser_ech_wide_boundary :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Write "A世B" -> col 0: 'A', col 1: '世' (lead), col 2: ' ' (cont), col 3: 'B'
	term.terminal_feed_string(&terminal, "A世B")
	testing.expect(t, .Wide_Lead in term.terminal_get_cell(&terminal, 0, 1).flags, "col 1 Wide_Lead")
	testing.expect(t, .Wide_Continuation in term.terminal_get_cell(&terminal, 0, 2).flags, "col 2 Wide_Continuation")

	// Erase 1 character at col 2 (the continuation cell) via ECH
	term.terminal_feed_string(&terminal, "\x1b[3G\x1b[1X")
	c1 := term.terminal_get_cell(&terminal, 0, 1)
	c2 := term.terminal_get_cell(&terminal, 0, 2)
	// Col 1 must be neutralized to space, col 2 erased to space
	testing.expect_value(t, c1.char, ' ')
	testing.expect(t, .Wide_Lead not_in c1.flags, "col 1 lead neutralized")
	testing.expect_value(t, c2.char, ' ')
	testing.expect(t, .Wide_Continuation not_in c2.flags, "col 2 cont erased")
}

@test
test_parser_decoupled_osc_callback :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	Osc_Capture :: struct {
		received_id:      int,
		received_payload: [64]u8,
		payload_len:      int,
		called:           bool,
	}
	capture := Osc_Capture{}

	// Override parser callback directly (proving pure decoupling from extensions)
	terminal.parser.user_data = &capture
	terminal.parser.on_osc = proc(user_data: rawptr, osc_id: int, payload: string) -> bool {
		cap := (^Osc_Capture)(user_data)
		cap.received_id = osc_id
		cap.payload_len = min(len(payload), len(cap.received_payload))
		copy(cap.received_payload[:cap.payload_len], payload[:cap.payload_len])
		cap.called = true
		return true
	}

	term.terminal_feed_string(&terminal, "\x1b]133;A\x07")
	testing.expect(t, capture.called, "Expected on_osc to be called")
	testing.expect_value(t, capture.received_id, 133)
	testing.expect_value(t, string(capture.received_payload[:capture.payload_len]), "A")
}









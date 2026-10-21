package terminal_tests

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:testing"
import cursor "../../cursor"
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

@test
test_bracketed_paste_mode :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	testing.expect(t, !terminal.parser.bracketed_paste, "Bracketed paste should default to false")

	term.terminal_feed_string(&terminal, "\x1b[?2004h")
	testing.expect(t, terminal.parser.bracketed_paste, "Bracketed paste should be enabled after ?2004h")

	term.terminal_feed_string(&terminal, "\x1b[?2004l")
	testing.expect(t, !terminal.parser.bracketed_paste, "Bracketed paste should be disabled after ?2004l")
}

@test
test_mouse_and_focus_reporting_modes :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	testing.expect(t, terminal.parser.mouse_mode == .None, "Mouse mode should default to None")
	testing.expect(t, terminal.parser.mouse_format == .X10, "Mouse format should default to X10")
	testing.expect(t, !terminal.parser.report_focus, "Focus reporting should default to false")

	// DECSET 1000 (Normal tracking)
	term.terminal_feed_string(&terminal, "\x1b[?1000h")
	testing.expect(t, terminal.parser.mouse_mode == .Normal, "Expected mouse_mode == .Normal after ?1000h")

	// DECSET 1002 (Button-event motion)
	term.terminal_feed_string(&terminal, "\x1b[?1002h")
	testing.expect(t, terminal.parser.mouse_mode == .Button_Event, "Expected mouse_mode == .Button_Event after ?1002h")

	// DECSET 1003 (Any-event motion)
	term.terminal_feed_string(&terminal, "\x1b[?1003h")
	testing.expect(t, terminal.parser.mouse_mode == .Any_Event, "Expected mouse_mode == .Any_Event after ?1003h")

	// DECSET 9 (X10 legacy)
	term.terminal_feed_string(&terminal, "\x1b[?9h")
	testing.expect(t, terminal.parser.mouse_mode == .X10, "Expected mouse_mode == .X10 after ?9h")

	// DECSET 1006 (SGR format)
	term.terminal_feed_string(&terminal, "\x1b[?1006h")
	testing.expect(t, terminal.parser.mouse_format == .Sgr, "Expected mouse_format == .Sgr after ?1006h")

	// DECSET 1016 (SGR-Pixel format)
	term.terminal_feed_string(&terminal, "\x1b[?1016h")
	testing.expect(t, terminal.parser.mouse_format == .Sgr_Pixel, "Expected mouse_format == .Sgr_Pixel after ?1016h")

	// DECSET 1004 (Focus reporting)
	term.terminal_feed_string(&terminal, "\x1b[?1004h")
	testing.expect(t, terminal.parser.report_focus, "Expected report_focus == true after ?1004h")

	// DECSET 1007 (Alternate scroll mode)
	term.terminal_feed_string(&terminal, "\x1b[?1007h")
	testing.expect(t, terminal.parser.alternate_scroll_mode, "Expected alternate_scroll_mode == true after ?1007h")

	// DECRST 1000, 1006, 1004, 1007 (Reset modes)
	term.terminal_feed_string(&terminal, "\x1b[?1000;1006;1004;1007l")
	testing.expect(t, terminal.parser.mouse_mode == .None, "Expected mouse_mode == .None after reset")
	testing.expect(t, terminal.parser.mouse_format == .X10, "Expected mouse_format == .X10 after reset")
	testing.expect(t, !terminal.parser.report_focus, "Expected report_focus == false after reset")
	testing.expect(t, !terminal.parser.alternate_scroll_mode, "Expected alternate_scroll_mode == false after reset")
}

@test
test_unicode_placeholder_combining :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// U+10EEEE followed by Cyrillic combining mark U+0483
	term.terminal_feed_string(&terminal, "\U0010EEEE\u0483")
	// Combining mark must not advance column
	testing.expect_value(t, terminal.parser.cursor.col, 1)

	c0 := term.terminal_get_cell(&terminal, 0, 0)
	testing.expect(t, .Has_Egc in c0.flags, "Expected Has_Egc on placeholder cell")

	runes := term.terminal_get_egc_runes(&terminal, c0.char)
	testing.expect_value(t, len(runes), 2)
	testing.expect_value(t, runes[0], rune(0x10EEEE))
	testing.expect_value(t, runes[1], rune(0x0483))
}

@test
test_kitty_graphics_apc_query :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			kstate := (^extension.Kitty_Extension)(e.user_data)
			kstate.responder = proc(term_ptr: rawptr, resp: []u8) -> bool {
				return term.terminal_emit_response(term_ptr, resp)
			}
			break
		}
	}

	// Send Kitty Graphics Query
	term.terminal_feed_string(&terminal, "\x1b_Ga=q,i=42\x1b\\")

	resp_buf: [128]u8
	n := term.terminal_drain_response(&terminal, resp_buf[:])
	testing.expect(t, n > 0, "Expected response from Kitty query")
	testing.expect_value(t, string(resp_buf[:n]), "\x1b_Gi=42;OK\x1b\\")
}

@test
test_csi_window_ops_16t :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// CSI 16 t (Query default cell size)
	term.terminal_feed_string(&terminal, "\x1b[16t")
	resp_buf: [128]u8
	n := term.terminal_drain_response(&terminal, resp_buf[:])
	testing.expect(t, n > 0, "Expected response from CSI 16t")
	testing.expect_value(t, string(resp_buf[:n]), "\x1b[6;20;10t")

	// Set real Retina font cell size: 19x43
	term.terminal_set_cell_size(&terminal, 19, 43)
	term.terminal_feed_string(&terminal, "\x1b[16t")
	n2 := term.terminal_drain_response(&terminal, resp_buf[:])
	testing.expect(t, n2 > 0, "Expected response from CSI 16t with custom cell size")
	testing.expect_value(t, string(resp_buf[:n2]), "\x1b[6;43;19t")
}

@test
test_kitty_graphics_lifecycle :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "Kitty extension state must be non-nil")

	// 1. Transmit only (a=t): image stored, but not active/placed
	// 1x1 RGBA pixel (4 bytes: FF 00 00 FF base64 encoded is "/wAA/w==" or similar)
	term.terminal_feed_string(&terminal, "\x1b_Ga=t,i=15,s=1,v=1,f=32;AAAA\x1b\\")
	img15 := extension.kitty_graphics_get_image(rawptr(var_kstate), 15)
	testing.expect(t, img15 != nil, "Image 15 should be stored")
	testing.expect(t, !img15.is_active, "Image 15 should not be active yet (a=t)")

	// 2. Put (a=p): activates image 15
	term.terminal_feed_string(&terminal, "\x1b_Ga=p,i=15,c=5,r=3\x1b\\")
	testing.expect(t, img15.is_active, "Image 15 should now be active (a=p)")
	testing.expect_value(t, img15.cols, 5)
	testing.expect_value(t, img15.rows, 3)

	// 3. Transmit & Display (a=T): image stored and placed immediately
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=25,s=1,v=1,f=32;AAAA\x1b\\")
	img25 := extension.kitty_graphics_get_image(rawptr(var_kstate), 25)
	testing.expect(t, img25 != nil && img25.is_active, "Image 25 should be stored and active (a=T)")

	// 4. Granular delete by ID (a=d, d=i, i=15)
	term.terminal_feed_string(&terminal, "\x1b_Ga=d,d=i,i=15\x1b\\")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(var_kstate), 15) == nil, "Image 15 should be deleted")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(var_kstate), 25) != nil, "Image 25 should still exist")

	// 5. Delete all (a=d, d=A)
	term.terminal_feed_string(&terminal, "\x1b_Ga=d,d=A\x1b\\")
	testing.expect(t, extension.kitty_graphics_get_image(rawptr(var_kstate), 25) == nil, "All images should be deleted")

	// 6. Multi-chunk transmission (m=1 then m=0) preserves id, cols, rows, and action
	term.terminal_feed_string(&terminal, "\x1b_Ga=t,i=42,s=2,v=2,f=32,c=40,r=25,m=1;AAAA\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Gm=0;AAAA\x1b\\")
	img42 := extension.kitty_graphics_get_image(rawptr(var_kstate), 42)
	testing.expect(t, img42 != nil, "Multi-chunk image 42 should be stored")
	if img42 != nil {
		testing.expect(t, !img42.is_active, "Image 42 should not be active yet (a=t across chunks)")
		testing.expect_value(t, img42.cols, 40)
		testing.expect_value(t, img42.rows, 25)
	}

	// 7. Put command (a=p) activates image 42 with its specified cols/rows
	term.terminal_feed_string(&terminal, "\x1b_Ga=p,i=42\x1b\\")
	if img42 != nil {
		testing.expect(t, img42.is_active, "Image 42 should be active after a=p")
		testing.expect_value(t, img42.cols, 40)
		testing.expect_value(t, img42.rows, 25)
	}

	// 8. Apple screenshot PNG (with iDOT chunk) strip verification
	raw_png_with_idot := [?]u8{
		0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
		0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR (13)
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
		0x00, 0x00, 0x00, 0x04, 0x69, 0x44, 0x4F, 0x54, // iDOT (4)
		0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, // IDAT
		0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
		0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND
	}
	stripped := extension._kitty_strip_apple_chunks(raw_png_with_idot[:], context.temp_allocator)
	testing.expect(t, len(stripped) < len(raw_png_with_idot), "Apple chunks should be stripped")
	testing.expect(t, len(stripped) == len(raw_png_with_idot) - 16, "iDOT chunk length (4+12) should be removed")
}

@test
test_xtversion_query :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// CSI > q (Query XTVERSION)
	term.terminal_feed_string(&terminal, "\x1b[>q")
	resp_buf: [128]u8
	n := term.terminal_drain_response(&terminal, resp_buf[:])
	testing.expect(t, n > 0, "Expected response from XTVERSION query")
	testing.expect_value(t, string(resp_buf[:n]), "\x1bP>|term(0.1.0)\x1b\\")
}

@test
test_kitty_graphics_multi_placement_and_granular_deletion :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "Kitty state must not be nil")

	// 1. Upload base image (100x100 virtual)
	term.terminal_feed_string(&terminal, "\x1b_Ga=t,i=100,s=100,v=100,f=32;AAAA\x1b\\")
	img := extension.kitty_graphics_get_image(rawptr(var_kstate), 100)
	testing.expect(t, img != nil, "Image 100 should be stored")

	// 2. Put 3 multi-cell slices (mimicking Yazi)
	term.terminal_feed_string(&terminal, "\x1b[10;5H\x1b_Ga=p,i=100,p=1,x=0,y=0,w=50,h=50,c=1,r=1,z=-1\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b[10;6H\x1b_Ga=p,i=100,p=2,x=50,y=0,w=50,h=50,c=1,r=1,z=-1\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b[11;5H\x1b_Ga=p,i=100,p=3,x=0,y=50,w=50,h=50,c=1,r=1,z=2\x1b\\")

	active_count := 0
	for p in var_kstate.placements {
		if p.is_active do active_count += 1
	}
	testing.expect_value(t, active_count, 3)

	// Check placement 2 properties
	p2 := var_kstate.placements[1]
	testing.expect_value(t, p2.placement_id, u32(2))
	testing.expect_value(t, p2.src_x, 50)
	testing.expect_value(t, p2.src_w, 50)
	testing.expect_value(t, p2.z_index, -1)

	// 3. Delete single placement p=2 (d=p)
	term.terminal_feed_string(&terminal, "\x1b_Ga=d,d=p,i=100,p=2\x1b\\")
	testing.expect(t, !var_kstate.placements[1].is_active, "Placement 2 should be inactive")
	testing.expect(t, var_kstate.placements[0].is_active, "Placement 1 should still be active")
	testing.expect(t, var_kstate.placements[2].is_active, "Placement 3 should still be active")

	// 4. Delete by z-index z=2 (d=z)
	term.terminal_feed_string(&terminal, "\x1b_Ga=d,d=z,z=2\x1b\\")
	testing.expect(t, !var_kstate.placements[2].is_active, "Placement 3 (z=2) should be inactive")
	testing.expect(t, var_kstate.placements[0].is_active, "Placement 1 should still be active")

	// 5. Delete by cursor intersection at (row 9, col 4 0-indexed => 10;5 1-indexed) (d=c)
	term.terminal_feed_string(&terminal, "\x1b[10;5H\x1b_Ga=d,d=c\x1b\\")
	testing.expect(t, !var_kstate.placements[0].is_active, "Placement 1 should be deleted by cursor intersection")
}

@test
test_kitty_graphics_animation_and_placeholders :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "Kitty state must not be nil")

	// 1. Unicode Placeholder virtual image upload (U=1)
	term.terminal_feed_string(&terminal, "\x1b_Ga=t,i=200,s=2,v=2,f=32,U=1;AAAA\x1b\\")
	img200 := extension.kitty_graphics_get_image(rawptr(var_kstate), 200)
	testing.expect(t, img200 != nil, "Image 200 should be stored")
	testing.expect(t, img200.is_virtual, "Image 200 must be marked virtual")

	// 2. Upload animation frame 2 (a=f) with duration 100ms
	term.terminal_feed_string(&terminal, "\x1b_Ga=f,i=200,r=2,z=100,s=2,v=2,f=32;AAAA\x1b\\")
	testing.expect_value(t, len(img200.animation.frames), 2)
	testing.expect_value(t, img200.animation.frames[1].duration_ms, 100)

	// 3. Animation control (a=a): Stop (s=1)
	term.terminal_feed_string(&terminal, "\x1b_Ga=a,i=200,s=1\x1b\\")
	testing.expect(t, img200.animation.state == .Stopped, "Animation should be stopped")

	// 4. Animation control (a=a): Run (s=3)
	term.terminal_feed_string(&terminal, "\x1b_Ga=a,i=200,s=3\x1b\\")
	testing.expect(t, img200.animation.state == .Running, "Animation should be running")

	// 5. Jump directly to frame 2 (c=2)
	term.terminal_feed_string(&terminal, "\x1b_Ga=a,i=200,c=2\x1b\\")
	testing.expect_value(t, img200.animation.current_frame, 1)

	// 6. Test frame advancement via kitty_animation_tick
	ticked := extension.kitty_animation_tick(img200, img200.animation.last_tick_ms + 150)
	testing.expect(t, ticked, "Tick should advance frame")
	testing.expect_value(t, img200.animation.current_frame, 0)
}

@test
test_grid_clear_preserves_ring_buffer_integrity :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// Feed 50 lines to trigger scrolling into scrollback history
	for i in 0..<50 {
		term.terminal_feed_string(&terminal, "SCROLL_LINE_CONTENT\r\n")
	}

	testing.expect(t, terminal.grid.origin > 0, "Origin must be shifted after 50 lines")
	testing.expect(t, terminal.grid.history_count > 0, "History count must be > 0")

	// Execute ED 2 (clear screen)
	term.terminal_feed_string(&terminal, "\x1b[2J")

	// Ensure all visible lines are completely clear and NOT showing stale history content
	for r in 0..<terminal.rows {
		row := term.terminal_get_row(&terminal, r)
		testing.expect(t, row != nil, "Row should not be nil")
		for c in 0..<terminal.cols {
			testing.expect(t, row.cells[c].char == ' ' || row.cells[c].char == 0, "Visible row cells must be clear")
		}
	}
}

@test
test_kitty_graphics_stream_zlib_decompression :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "Kitty state must not be nil")

	// Transmit 2x2 red RGB image compressed with zlib (o=z) via stream inline mode
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=300,f=24,s=2,v=2,o=z;eJz7z8DwH4YAHe4D/Q==\x1b\\")

	img300 := extension.kitty_graphics_get_image(rawptr(var_kstate), 300)
	testing.expect(t, img300 != nil, "Image 300 must be stored after zlib decompression")
	testing.expect_value(t, img300.width, 2)
	testing.expect_value(t, img300.height, 2)
	testing.expect_value(t, len(img300.pixels), 16) // 2x2 * 4 (RGBA)
	// Verify red pixel RGBA: [255, 0, 0, 255]
	testing.expect_value(t, img300.pixels[0], 255)
	testing.expect_value(t, img300.pixels[1], 0)
	testing.expect_value(t, img300.pixels[2], 0)
	testing.expect_value(t, img300.pixels[3], 255)

	// Multi-chunk stream with unpadded base64 (matching real kitten stream transfer)
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=301,f=24,s=2,v=2,o=z,m=1;eJz7z8Dw\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=301,m=0;H4YAHe4D/Q\x1b\\")

	img301 := extension.kitty_graphics_get_image(rawptr(var_kstate), 301)
	testing.expect(t, img301 != nil, "Image 301 must be stored after multi-chunk unpadded zlib decompression")
	testing.expect_value(t, img301.width, 2)
	testing.expect_value(t, img301.height, 2)
	testing.expect_value(t, len(img301.pixels), 16)
	testing.expect_value(t, img301.pixels[0], 255)
}

@test
test_kitty_graphics_cursor_advancement_and_scrolling :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			var_kstate.cursor_provider = proc(term_ptr: rawptr) -> (int, int) {
				t := (^term.Terminal)(term_ptr)
				return t.parser.cursor.row, t.parser.cursor.col
			}
			var_kstate.cursor_advancer = proc(term_ptr: rawptr, cols, rows: int) {
				t := (^term.Terminal)(term_ptr)
				term.terminal_advance_cursor_for_image(t, cols, rows)
			}
			break
		}
	}

	// Move cursor to row 20
	terminal.parser.cursor.row = 20
	terminal.parser.cursor.col = 5

	// Display image 301 spanning 10 rows (r=10) with default C=0
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=301,s=2,v=2,f=32,r=10;AAAA\x1b\\")

	// Target row was 20 + 10 = 30 > scroll_bottom (23). Overflow = 7 rows.
	// Terminal should have scrolled 7 rows up, cursor landed on row 23.
	testing.expect_value(t, terminal.parser.cursor.row, 23)

	// Placement y_row should have been shifted up by 7 (20 - 7 = 13)
	testing.expect(t, len(var_kstate.placements) > 0, "Must have placement")
	testing.expect_value(t, var_kstate.placements[0].y_row, 13)
}

@test
test_kitty_graphics_base64_whitespace_handling :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "Kitty state must not be nil")

	// Base64 with carriage returns, newlines, and spaces interspersed across lines
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=305,f=24,s=2,v=2,o=z;\r\n  eJz7z8Dw\r\n  H4YAHe4D/Q==\r\n\x1b\\")

	img305 := extension.kitty_graphics_get_image(rawptr(var_kstate), 305)
	testing.expect(t, img305 != nil, "Image 305 must be stored despite whitespace in Base64")
	testing.expect_value(t, img305.width, 2)
	testing.expect_value(t, img305.height, 2)
	testing.expect_value(t, img305.pixels[0], 255)
}

@test
test_kitty_graphics_anonymous_no_response :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	// Feed anonymous image transmission (i=0)
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,f=24,s=2,v=2,o=z;eJz7z8DwH4YAHe4D/Q==\x1b\\")

	out_buf: [256]u8
	drained := term.terminal_drain_response(&terminal, out_buf[:])
	testing.expect_value(t, drained, 0)
}

@test
test_kitty_graphics_aspect_ratio_spans :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 30, 100)
	defer term.terminal_destroy(&terminal)
	term.terminal_set_cell_size(&terminal, 10, 20)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			var_kstate.cell_size_provider = proc(p: rawptr) -> (int, int) {
				t := (^term.Terminal)(p)
				return t.parser.cell_w, t.parser.cell_h
			}
			var_kstate.grid_size_provider = proc(p: rawptr) -> (int, int) {
				t := (^term.Terminal)(p)
				return t.cols, t.rows
			}
			break
		}
	}

	// 1. Image 400x200 (aspect 2:1), request c=40 only.
	// cell_w=10, cell_h=20.
	// w_px = 40 * 10 = 400.
	// h_px = 400 / 2 = 200.
	// rows = 200 / 20 = 10 rows.
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=310,s=400,v=200,f=32,c=40;AAAA\x1b\\")
	testing.expect(t, len(var_kstate.placements) > 0, "Must have placement 310")
	p310 := var_kstate.placements[len(var_kstate.placements) - 1]
	testing.expect_value(t, p310.cols, 40)
	testing.expect_value(t, p310.rows, 10)

	// 2. Image 400x200 (aspect 2:1), request r=10 only.
	// h_px = 10 * 20 = 200.
	// w_px = 200 * 2 = 400.
	// cols = 400 / 10 = 40 cols.
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=311,s=400,v=200,f=32,r=10;AAAA\x1b\\")
	p311 := var_kstate.placements[len(var_kstate.placements) - 1]
	testing.expect_value(t, p311.cols, 40)
	testing.expect_value(t, p311.rows, 10)

	// 3. Oversized image 5000x2500 (aspect 2:1) without c or r.
	// Terminal is 100 cols x 30 rows.
	// Max allowed height is ~28 rows = 560px.
	// Max allowed width is 100 cols = 1000px.
	// Scale fits into width 1000px and height 500px (25 rows).
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=312,s=5000,v=2500,f=32;AAAA\x1b\\")
	p312 := var_kstate.placements[len(var_kstate.placements) - 1]
	testing.expect(t, p312.cols <= 100, "Cols must not overflow terminal width")
	testing.expect(t, p312.rows <= 30, "Rows must not overflow terminal height")
}

@test
test_kitty_graphics_large_multi_chunk_stream :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 30, 100)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// 500x400 RGBA image = 800,000 bytes raw (>512KB)
	w, h := 500, 400
	raw_bytes := make([]u8, w * h * 4, context.temp_allocator)
	for i in 0..<len(raw_bytes) {
		raw_bytes[i] = u8(i & 255)
	}

	b64_str, _ := base64.encode(raw_bytes, base64.ENC_TABLE, context.temp_allocator)
	chunk_size := 4096
	total_len := len(b64_str)
	offset := 0
	chunk_idx := 0

	for offset < total_len {
		end := min(total_len, offset + chunk_size)
		slice := b64_str[offset:end]
		more := 1 if end < total_len else 0
		apc: string
		if chunk_idx == 0 {
			apc = fmt.tprintf("\x1b_Ga=T,i=320,f=32,s=%d,v=%d,m=%d;%s\x1b\\", w, h, more, slice)
		} else {
			apc = fmt.tprintf("\x1b_Gm=%d;%s\x1b\\", more, slice)
		}
		term.terminal_feed_string(&terminal, apc)
		offset = end
		chunk_idx += 1
	}

	img320 := extension.kitty_graphics_get_image(rawptr(var_kstate), 320)
	testing.expect(t, img320 != nil, "Image 320 (>512KB stream) must be successfully decoded and stored")
	testing.expect_value(t, img320.width, 500)
	testing.expect_value(t, img320.height, 400)
	testing.expect_value(t, len(img320.pixels), 800000)
}

@test
test_kitty_graphics_resize_placement_tracking :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			var_kstate.cursor_provider = proc(p: rawptr) -> (int, int) {
				t := (^term.Terminal)(p)
				return t.parser.cursor.row, t.parser.cursor.col
			}
			var_kstate.cursor_advancer = proc(p: rawptr, c, r: int) {
				t := (^term.Terminal)(p)
				term.terminal_advance_cursor_for_image(t, c, r)
			}
			break
		}
	}

	terminal.parser.cursor.row = 2
	terminal.parser.cursor.col = 0

	// Place image 330 at row 2, spanning 8 rows
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=330,s=2,v=2,f=32,r=8;AAAA\x1b\\")

	testing.expect_value(t, len(var_kstate.placements), 1)
	testing.expect_value(t, var_kstate.placements[0].y_row, 2)
	testing.expect_value(t, terminal.parser.cursor.row, 10)

	// Simulate terminal window shrink from 24 rows to 12 rows
	term.terminal_resize(&terminal, 12, 80)

	// Target rows became 12. Cursor was at 10.
	// Placement y_row must stay aligned with cursor, maintaining the exact vertical distance!
	testing.expect(t, var_kstate.placements[0].y_row < terminal.parser.cursor.row, "Placement must remain above prompt cursor")
	testing.expect_value(t, terminal.parser.cursor.row - var_kstate.placements[0].y_row, 8)
}

@test
test_kitty_graphics_stbi_jpeg_decoding :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("image.jpg", context.temp_allocator)
	if err != nil do return

	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// Transmit image.jpg via Kitty direct stream chunks
	b64_str, _ := base64.encode(data, base64.ENC_TABLE, context.temp_allocator)
	chunk_size := 4096
	total_len := len(b64_str)
	offset := 0
	chunk_idx := 0

	for offset < total_len {
		end := min(total_len, offset + chunk_size)
		slice := b64_str[offset:end]
		more := 1 if end < total_len else 0
		apc: string
		if chunk_idx == 0 {
			apc = fmt.tprintf("\x1b_Ga=T,i=340,f=100,m=%d;%s\x1b\\", more, slice)
		} else {
			apc = fmt.tprintf("\x1b_Gm=%d;%s\x1b\\", more, slice)
		}
		term.terminal_feed_string(&terminal, apc)
		offset = end
		chunk_idx += 1
	}

	img340 := extension.kitty_graphics_get_image(rawptr(var_kstate), 340)
	testing.expect(t, img340 != nil, "image.jpg (progressive JPEG stream) must be successfully decoded by stb_image")
	if img340 != nil {
		testing.expect_value(t, img340.width, 5000)
		testing.expect_value(t, img340.height, 3327)
		testing.expect(t, len(img340.pixels) == 5000 * 3327 * 4, "Pixel buffer must match RGBA size")
	}
}

@test
test_kitty_graphics_stream_base64url_and_padding :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// 2x2 RGBA image (16 bytes: 4 pixels of pure red)
	// Base64URL with '-' and '_' plus intermediate '=' padding chunks
	// Normal base64: /wAA/wAA/wAA/wAA -> Base64URL: _wAA_wAA_wAA_wAA
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=360,f=32,s=2,v=2,m=1;_wAA_wAA==\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Gm=0;_wAA_wAA\x1b\\")

	img360 := extension.kitty_graphics_get_image(rawptr(var_kstate), 360)
	testing.expect(t, img360 != nil, "Base64URL and intermediate padded chunks must decode successfully")
	if img360 != nil {
		testing.expect_value(t, img360.width, 2)
		testing.expect_value(t, img360.height, 2)
		testing.expect_value(t, len(img360.pixels), 16)
		testing.expect_value(t, img360.pixels[0], 0xFF) // Red
	}
}

@test
test_kitty_graphics_stream_empty_initial_chunk :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// Chunk 1 has NO payload (header metadata only), payload arrives in Chunk 2
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=370,f=32,s=1,v=1,m=1;\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Gm=0;/wAA\x1b\\")

	img370 := extension.kitty_graphics_get_image(rawptr(var_kstate), 370)
	testing.expect(t, img370 != nil, "Image must be stored when chunk 1 has empty payload")
	if img370 != nil {
		testing.expect_value(t, img370.width, 1)
		testing.expect_value(t, img370.height, 1)
	}
}

var_test_damaged_start_row := -1

@test
test_kitty_graphics_transmit_then_place_dimension_preservation :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 30, 100)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}

	// Transmit only with explicit c=20, r=10
	term.terminal_feed_string(&terminal, "\x1b_Ga=t,i=380,f=32,s=100,v=100,c=20,r=10,m=1;AAAA\x1b\\")
	term.terminal_feed_string(&terminal, "\x1b_Gm=0;AAAA\x1b\\")

	// Verify image is in cache but not placed
	img380 := extension.kitty_graphics_get_image(rawptr(var_kstate), 380)
	testing.expect(t, img380 != nil, "Image 380 must be cached")
	testing.expect_value(t, len(var_kstate.placements), 0)

	// Now place without re-specifying c and r
	var_test_damaged_start_row = -1
	var_kstate.damage_notifier = proc(ud: rawptr, start_row, row_count: int) {
		var_test_damaged_start_row = start_row
	}
	var_kstate.cursor_provider = proc(ud: rawptr) -> (int, int) { return 4, 2 }

	term.terminal_feed_string(&terminal, "\x1b_Ga=p,i=380\x1b\\")
	testing.expect_value(t, var_test_damaged_start_row, 4)
	testing.expect_value(t, len(var_kstate.placements), 1)
	p := var_kstate.placements[0]
	testing.expect_value(t, p.cols, 20)
	testing.expect_value(t, p.rows, 10)
	testing.expect_value(t, p.x_col, 2)
	testing.expect_value(t, p.y_row, 4)
}

@test
test_terminal_mouse_cursor_decisions :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	// 1. Default shell state -> Text (I-beam)
	c := term.terminal_cursor(&terminal, false, "")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Text)

	// 2. Mouse tracking enabled (e.g. Normal tracking 1000) -> Default (Arrow)
	terminal.parser.mouse_mode = .Normal
	c = term.terminal_cursor(&terminal, false, "")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Default)

	// 3. Mouse tracking enabled, but user holds Shift (bypass) -> Text (I-beam)
	c = term.terminal_cursor(&terminal, true, "")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Text)

	// 4. OSC 22 Pointer shapes override
	c = term.terminal_cursor(&terminal, false, "pointer")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Pointer)

	c = term.terminal_cursor(&terminal, false, "crosshair")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Crosshair)

	c = term.terminal_cursor(&terminal, false, "col-resize")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Col_Resize)

	c = term.terminal_cursor(&terminal, false, "row-resize")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Row_Resize)

	c = term.terminal_cursor(&terminal, false, "not-allowed")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Not_Allowed)

	c = term.terminal_cursor(&terminal, false, "wait")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Wait)

	c = term.terminal_cursor(&terminal, false, "default")
	testing.expect_value(t, c, cursor.Mouse_Cursor.Default)
}












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

	// Enter alternate screen (?1049h) and set application cursor keys (?1h)
	term.terminal_feed_string(&terminal, "\x1b[?1049h\x1b[?1h")
	testing.expect(t, terminal.parser.in_alt_screen, "Expected in_alt_screen == true")
	testing.expect(t, terminal.parser.cursor_key_mode, "Expected cursor_key_mode == true")

	// Exit alternate screen (?1049l) and reset cursor keys (?1l)
	term.terminal_feed_string(&terminal, "\x1b[?1049l\x1b[?1l")
	testing.expect(t, !terminal.parser.in_alt_screen, "Expected in_alt_screen == false")
	testing.expect(t, !terminal.parser.cursor_key_mode, "Expected cursor_key_mode == false")
}



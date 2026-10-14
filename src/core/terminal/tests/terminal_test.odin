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

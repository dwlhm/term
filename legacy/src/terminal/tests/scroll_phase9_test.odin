package termgrid_test

import "core:os"
import "core:strings"
import "core:testing"
import tg "../"
import p "../../parser"

@(test)
test_p9_full_scroll_up_one :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Distinct marker per row in col 0.
	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('A' + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}
	tg.damage_clear(&term.damage)

	old_origin := term.grid.origin
	testing.expect(t, old_origin == 0, "origin should start at 0")

	tg.terminal_scroll_up(&term, 1)

	testing.expect(t, term.grid.origin == ((old_origin + 1) & term.grid.mask), "origin should rotate by 1 with mask")
	// Content shift: logical row 0 now holds old row 1 ('B').
	c0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, c0.content == tg.Content_Handle('A' + 1), "row 0 should hold old row 1 content")
	// Bottom row cleared.
	cb := tg.grid_get_cell(&term.grid, 23, 0)
	testing.expect(t, cb.content == 0, "bottom row should be cleared")
	// Scroll_Op{0,R-1,+1}.
	testing.expect(t, len(term.damage.scroll_ops) == 1, "should record one Scroll_Op")
	op := term.damage.scroll_ops[0]
	testing.expect(t, op.top == 0 && op.bottom == 23 && op.rows == 1, "Scroll_Op should be {0,23,+1}")
}

@(test)
test_p9_full_scroll_down_one :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('A' + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}
	tg.damage_clear(&term.damage)

	tg.terminal_scroll_down(&term, 1)

	expected_origin := (0 - 1 + term.grid.capacity) & term.grid.mask
	testing.expect(t, term.grid.origin == expected_origin, "origin should rotate backward by 1")
	// Old row 22 now at logical row 23? Top cleared, second row holds old row 0.
	c1 := tg.grid_get_cell(&term.grid, 1, 0)
	testing.expect(t, c1.content == tg.Content_Handle('A' + 0), "row 1 should hold old row 0 content")
	c0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, c0.content == 0, "top row should be cleared")
	testing.expect(t, len(term.damage.scroll_ops) == 1, "should record one Scroll_Op")
	op := term.damage.scroll_ops[0]
	testing.expect(t, op.top == 0 && op.bottom == 23 && op.rows == -1, "Scroll_Op should be {0,23,-1}")
}

@(test)
test_p9_scroll_n_rows :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle(0x30 + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}
	tg.damage_clear(&term.damage)

	tg.terminal_scroll_up(&term, 5)

	testing.expect(t, term.grid.origin == 5, "origin should advance by 5")
	// Logical row 0 holds old row 5.
	c0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, c0.content == tg.Content_Handle(0x30 + 5), "row 0 should hold old row 5")
	// Bottom 5 rows cleared.
	for r in 19..<24 {
		c := tg.grid_get_cell(&term.grid, r, 0)
		testing.expect(t, c.content == 0, "exposed bottom rows should be cleared")
	}
	// Survivor just above exposed region holds old content.
	c18 := tg.grid_get_cell(&term.grid, 18, 0)
	testing.expect(t, c18.content == tg.Content_Handle(0x30 + 23), "row 18 should hold old row 23")
	testing.expect(t, len(term.damage.scroll_ops) == 1, "one Scroll_Op expected")
	op := term.damage.scroll_ops[0]
	testing.expect(t, op.top == 0 && op.bottom == 23 && op.rows == 5, "Scroll_Op should be {0,23,+5}")
}

@(test)
test_p9_scroll_region_partial_up_down :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)

	mark := proc(g: ^tg.Grid, r: int) {
		cell := tg.Semantic_Cell{content = tg.Content_Handle(100 + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(g, r, 0, cell)
	}
	for r in 0..<24 {
		mark(&g, r)
	}

	// Partial scroll up [5,14] by 3.
	actual := tg.scroll_up(&g, &d, 5, 14, 3)
	testing.expect(t, actual == 3, "partial scroll up should return 3")
	// Outside rows byte-identical.
	for r in 0..<5 {
		c := tg.grid_get_cell(&g, r, 0)
		testing.expect(t, c.content == tg.Content_Handle(100 + r), "rows above region unchanged")
	}
	for r in 15..<24 {
		c := tg.grid_get_cell(&g, r, 0)
		testing.expect(t, c.content == tg.Content_Handle(100 + r), "rows below region unchanged")
	}
	// Inside rotated: new row 5 holds old row 8.
	testing.expect(t, tg.grid_get_cell(&g, 5, 0).content == tg.Content_Handle(108), "region top should hold old row 8")
	testing.expect(t, tg.grid_get_cell(&g, 11, 0).content == tg.Content_Handle(114), "region row 11 should hold old row 14")
	// Exposed bottom of region cleared.
	for r in 12..<15 {
		testing.expect(t, tg.grid_get_cell(&g, r, 0).content == 0, "exposed region rows cleared")
	}
	testing.expect(t, len(d.scroll_ops) == 1, "one Scroll_Op expected")
	op := d.scroll_ops[0]
	testing.expect(t, op.top == 5 && op.bottom == 14 && op.rows == 3, "clamped Scroll_Op {5,14,+3}")

	// Partial scroll down [5,14] by 3 should restore.
	actual = tg.scroll_down(&g, &d, 5, 14, 3)
	testing.expect(t, actual == 3, "partial scroll down should return 3")
	testing.expect(t, len(d.scroll_ops) == 2, "two Scroll_Ops expected")
	op2 := d.scroll_ops[1]
	testing.expect(t, op2.top == 5 && op2.bottom == 14 && op2.rows == -3, "clamped Scroll_Op {5,14,-3}")
	// Top of region cleared after scroll down.
	for r in 5..<8 {
		testing.expect(t, tg.grid_get_cell(&g, r, 0).content == 0, "exposed top rows cleared after down")
	}
}

@(test)
test_p9_scroll_wrap_capacity :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)

	testing.expect(t, g.capacity == 32, "capacity should be 32 for 24 rows")
	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle(200 + r), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&g, r, 0, cell)
	}

	for _ in 0..<30 {
		tg.grid_scroll_up(&g, 1)
	}
	testing.expect(t, g.origin == (30 & 31), "origin should be 30&31 after 30 single scrolls")
	// After 30 scrolls (>24 rows) all original content was exposed and cleared.
	testing.expect(t, tg.grid_get_cell(&g, 0, 0).content == 0, "grid should be fully cleared after overflow scrolls")
	// Logical mapping still correct via grid_get_cell: write logical, read back.
	marker := tg.Semantic_Cell{content = 999, style = 0, width = 1, flags = .None}
	testing.expect(t, tg.grid_set_cell(&g, 0, 0, marker), "logical write should succeed after wrap")
	testing.expect(t, tg.grid_get_cell(&g, 0, 0).content == 999, "logical mapping correct after wrap")
	testing.expect(t, tg.grid_get_cell(&g, 1, 0).content == 0, "neighbor unaffected after wrap")
}

@(test)
test_p9_newline_bottom_scrolls :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 23, 10)
	tg.damage_clear(&term.damage)

	tg.terminal_newline(&term)

	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 23, "cursor should pin at bottom row")
	testing.expect(t, cur.col == 0, "cursor col should reset to 0")
	testing.expect(t, len(term.damage.scroll_ops) == 1, "newline at bottom should record Scroll_Op")
	testing.expect(t, term.damage.scroll_ops[0].rows == 1, "Scroll_Op should be +1")
}

@(test)
test_p9_su_sd_csi_defaults :: proc(t: ^testing.T) {
	feed := proc(input: []u8, rows, cols: int) -> tg.Terminal {
		term: tg.Terminal
		tg.terminal_init(&term, rows, cols)
		for r in 0..<rows {
			cell := tg.Semantic_Cell{content = tg.Content_Handle(50 + r), style = 0, width = 1, flags = .None}
			tg.grid_set_cell(&term.grid, r, 0, cell)
		}
		tg.damage_clear(&term.damage)
		parser: p.Parser
		p.parser_init(&parser)
		p.parse_chunk(&parser, &term, input)
		return term
	}

	// ESC[S -> scroll up 1.
	term1 := feed([]u8{0x1B, '[', 'S'}, 24, 80)
	defer tg.terminal_destroy(&term1)
	testing.expect(t, term1.grid.origin == 1, "ESC[S should scroll up 1")
	testing.expect(t, len(term1.damage.scroll_ops) == 1 && term1.damage.scroll_ops[0].rows == 1, "ESC[S Scroll_Op +1")

	// ESC[3S -> scroll up 3.
	term2 := feed([]u8{0x1B, '[', '3', 'S'}, 24, 80)
	defer tg.terminal_destroy(&term2)
	testing.expect(t, term2.grid.origin == 3, "ESC[3S should scroll up 3")

	// ESC[T -> scroll down 1.
	term3 := feed([]u8{0x1B, '[', 'T'}, 24, 80)
	defer tg.terminal_destroy(&term3)
	expected := (0 - 1 + term3.grid.capacity) & term3.grid.mask
	testing.expect(t, term3.grid.origin == expected, "ESC[T should scroll down 1")

	// ESC[2T -> scroll down 2.
	term4 := feed([]u8{0x1B, '[', '2', 'T'}, 24, 80)
	defer tg.terminal_destroy(&term4)
	expected4 := (0 - 2 + term4.grid.capacity) & term4.grid.mask
	testing.expect(t, term4.grid.origin == expected4, "ESC[2T should scroll down 2")
}

@(test)
test_p9_decstbm_set_reset :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Default margins.
	testing.expect(t, term.scroll_top == 0 && term.scroll_bottom == 23, "default margins should be 0..23")

	// Direct set.
	ok := tg.terminal_set_scroll_region(&term, 5, 14)
	testing.expect(t, ok, "valid set should return true")
	testing.expect(t, term.scroll_top == 5 && term.scroll_bottom == 14, "margins should update")

	// Reject top>=bottom unchanged.
	ok = tg.terminal_set_scroll_region(&term, 10, 10)
	testing.expect(t, !ok, "top>=bottom should be rejected")
	testing.expect(t, term.scroll_top == 5 && term.scroll_bottom == 14, "margins unchanged on reject")
	ok = tg.terminal_set_scroll_region(&term, 15, 5)
	testing.expect(t, !ok, "inverted region should be rejected")

	// Reject out-of-range unchanged.
	ok = tg.terminal_set_scroll_region(&term, -1, 10)
	testing.expect(t, !ok, "negative top should be rejected")
	ok = tg.terminal_set_scroll_region(&term, 0, 24)
	testing.expect(t, !ok, "bottom OOR should be rejected")

	// Reset restores full grid.
	tg.terminal_reset_scroll_region(&term)
	testing.expect(t, term.scroll_top == 0 && term.scroll_bottom == 23, "reset should restore 0..23")

	// Via CSI: ESC[2;10r sets 1-indexed -> 0-indexed 1..9.
	parser: p.Parser
	p.parser_init(&parser)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', ';', '1', '0', 'r'})
	testing.expect(t, term.scroll_top == 1 && term.scroll_bottom == 9, "DECSTBM 2;10r should set 1..9")

	// Clamp: ESC[0;100r -> [1,24] -> 0..23.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '0', ';', '1', '0', '0', 'r'})
	testing.expect(t, term.scroll_top == 0 && term.scroll_bottom == 23, "DECSTBM OOR should clamp to full")

	// Bare r resets.
	tg.terminal_set_scroll_region(&term, 5, 14)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'r'})
	testing.expect(t, term.scroll_top == 0 && term.scroll_bottom == 23, "bare r should reset margins")
}

@(test)
test_p9_scroll_with_damage_pending :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Pre-existing dirt on row 5.
	phys5 := tg._grid_physical_row(&term.grid, 5)
	gen5 := term.grid.rows[phys5].generation + 1
	term.grid.rows[phys5].generation = gen5
	tg.damage_mark_cell(&term.damage, 5, 10, gen5)

	tg.terminal_scroll_up(&term, 1)

	journal := tg.terminal_take_damage(&term)
	defer tg.damage_journal_destroy(&journal)

	testing.expect(t, len(journal.scroll_ops) == 1, "Scroll_Op should be present")
	testing.expect(t, journal.scroll_ops[0].rows == 1, "Scroll_Op rows should be +1")
	// Pre dirt preserved.
	testing.expect(t, journal.dirty_rows[5].span_count == 1, "pre dirt on row 5 should be present")
	// Exposed bottom row dirty.
	testing.expect(t, journal.dirty_rows[23].full, "exposed bottom row should be dirty")
}

@(test)
test_p9_scroll_overflow_clamps :: proc(t: ^testing.T) {
	g: tg.Grid
	tg.grid_init(&g, 24, 80)
	defer tg.grid_destroy(&g)
	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('Z'), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&g, r, 0, cell)
	}

	actual := tg.grid_scroll_up(&g, 100)
	testing.expect(t, actual == 24, "n=100 should clamp to 24")
	for r in 0..<24 {
		testing.expect(t, tg.grid_get_cell(&g, r, 0).content == 0, "all rows cleared on full overflow")
	}

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	for r in 0..<24 {
		cell := tg.Semantic_Cell{content = tg.Content_Handle('Z'), style = 0, width = 1, flags = .None}
		tg.grid_set_cell(&term.grid, r, 0, cell)
	}
	tg.damage_clear(&term.damage)
	tg.terminal_scroll_up(&term, 100)
	testing.expect(t, len(term.damage.scroll_ops) == 1, "overflow should record one Scroll_Op")
	testing.expect(t, term.damage.scroll_ops[0].rows == 24, "Scroll_Op should record actual 24")

	// Guards: n<=0, rows==0, top>bottom.
	testing.expect(t, tg.grid_scroll_up(&g, 0) == 0, "n<=0 should return 0")
	testing.expect(t, tg.grid_scroll_down(&g, -5) == 0, "negative n should return 0")
	empty: tg.Grid
	testing.expect(t, tg.grid_scroll_up(&empty, 1) == 0, "rows==0 should return 0")
	d: tg.Damage
	tg.damage_init(&d, 24, 80)
	defer tg.damage_destroy(&d)
	testing.expect(t, tg.scroll_up(&g, &d, 10, 5, 1) == 0, "top>bottom should return 0")
	testing.expect(t, len(d.scroll_ops) == 0, "guard should record no Scroll_Op")
}

@(test)
test_p9_no_memmove_audit :: proc(t: ^testing.T) {
	// GPU-side copies in damage_take_journal / upload paths are explicitly
	// excluded from this audit: only grid.odin / scroll.odin scroll paths are gated.
	paths := [2]string{"src/terminal/grid.odin", "src/terminal/scroll.odin"}
	for path in paths {
		data, err := os.read_entire_file(path, context.allocator)
		testing.expect(t, err == nil, "should read scroll source file")
		if err != nil {
			continue
		}
		defer delete(data)
		content := string(data)
		testing.expect(t, !strings.contains(content, "memmove"), "scroll path must not use memmove")
		testing.expect(t, !strings.contains(content, "memcpy"), "scroll path must not use memcpy")
		testing.expect(t, !strings.contains(content, "copy("), "scroll path must not use copy(")
	}
}

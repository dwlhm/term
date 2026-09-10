package termgrid_test

import "core:os"
import "core:strings"
import "core:testing"
import tg "../"
import p "../../parser"

// --- wcwidth spots (§6) ---

@(test)
test_p10_wcwidth_spots :: proc(t: ^testing.T) {
	testing.expect(t, tg.wcwidth(0x0041) == 1, "0041 -> 1")
	testing.expect(t, tg.wcwidth(0x00E9) == 1, "00E9 -> 1")
	testing.expect(t, tg.wcwidth(0x2603) == 1, "2603 -> 1")
	testing.expect(t, tg.wcwidth(0x4E2D) == 2, "4E2D -> 2")
	testing.expect(t, tg.wcwidth(0xFF21) == 2, "FF21 -> 2")
	testing.expect(t, tg.wcwidth(0x1F600) == 2, "1F600 -> 2")
	testing.expect(t, tg.wcwidth(0x0301) == 0, "0301 -> 0")
	testing.expect(t, tg.wcwidth(0x200D) == 0, "200D -> 0")
	testing.expect(t, tg.wcwidth(0xFFFD) == 1, "FFFD -> 1")

	// Range-edge boundaries.
	testing.expect(t, tg.wcwidth(0x02FF) == 1, "02FF below extend -> 1")
	testing.expect(t, tg.wcwidth(0x0300) == 0, "0300 extend start -> 0")
	testing.expect(t, tg.wcwidth(0x036F) == 0, "036F extend end -> 0")
	testing.expect(t, tg.wcwidth(0x0370) == 1, "0370 above extend -> 1")
	testing.expect(t, tg.wcwidth(0x2E7F) == 1, "2E7F below wide -> 1")
	testing.expect(t, tg.wcwidth(0x2E80) == 2, "2E80 wide start -> 2")
	testing.expect(t, tg.wcwidth(0x00AC) == 1, "00AC -> 1")
	testing.expect(t, tg.wcwidth(0x00AD) == 0, "00AD soft hyphen -> 0")
	testing.expect(t, tg.wcwidth(0x200B) == 0, "200B ZWSP -> 0")
	testing.expect(t, tg.wcwidth(0xFEFF) == 0, "FEFF ZWNBSP -> 0")
	testing.expect(t, tg.wcwidth(0xFE00) == 0, "FE00 VS1 -> 0")
	testing.expect(t, tg.wcwidth(0x1AB0) == 0, "1AB0 extend -> 0")
	testing.expect(t, tg.wcwidth(0x1AAF) == 1, "1AAF below extend -> 1")
	testing.expect(t, tg.wcwidth(0x20D0) == 0, "20D0 extend -> 0")
	testing.expect(t, tg.wcwidth(0x1F300) == 2, "1F300 emoji wide -> 2")
	testing.expect(t, tg.wcwidth(0x1F64F) == 2, "1F64F emoji wide end -> 2")

	testing.expect(t, tg.is_zero_width_extend(0x0301), "0301 is extend")
	testing.expect(t, tg.is_zero_width_extend(0x200D), "200D is extend")
	testing.expect(t, !tg.is_zero_width_extend(0x0041), "0041 not extend")
	testing.expect(t, !tg.is_zero_width_extend(0x4E2D), "4E2D not extend")
}

// --- Combining (MECE #6, #7) ---

@(test)
test_p10_combining_on_base :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 'e')
	tg.terminal_put_char(&term, 0x0301)

	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, tg.content_is_grapheme(cell.content), "base cell should hold grapheme handle")
	testing.expect(t, tg.grapheme_resolve_base(cell.content, &term.grapheme_store) == 'e', "resolved base should be 'e'")
	testing.expect(t, cell.width == 1, "cluster cell width stays 1")

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "combining adds +0, total +1")

	// Second cell untouched.
	cell1 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, cell1.content == 0, "no new cell written")
}

@(test)
test_p10_combining_on_empty :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// NoBase: dropped on empty col 0.
	tg.terminal_put_char(&term, 0x0301)

	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0, "combining on empty must be dropped")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 0 && cursor.row == 0, "cursor unmoved")
}

// --- Wide (MECE #4, #5, #11) ---

@(test)
test_p10_wide_mid_row :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D)

	lead := tg.terminal_get_cell(&term, 0, 0)
	cont := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, lead.content == 0x4E2D && lead.width == 2, "lead holds codepoint w=2")
	testing.expect(t, cont.flags == .Wide_Continuation && cont.width == 1, "cont marked w=1")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 2, "wide advances +2")
}

@(test)
test_p10_wide_at_edge :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 4, 5)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 0, 4)
	tg.terminal_put_char(&term, 0x4E2D)

	// RightEdgeSplit: pad blank + wrap, pair on next row.
	pad := tg.terminal_get_cell(&term, 0, 4)
	testing.expect(t, pad.content == 0, "edge cell padded blank")
	lead := tg.terminal_get_cell(&term, 1, 0)
	cont := tg.terminal_get_cell(&term, 1, 1)
	testing.expect(t, lead.content == 0x4E2D && lead.width == 2, "pair lead on next row col 0")
	testing.expect(t, cont.flags == .Wide_Continuation, "pair cont on next row col 1")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.row == 1 && cursor.col == 2, "cursor next row col 2")
}

@(test)
test_p10_emoji_wide :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x1F600)

	lead := tg.terminal_get_cell(&term, 0, 0)
	cont := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, lead.content == 0x1F600 && lead.width == 2, "emoji lead w=2")
	testing.expect(t, cont.flags == .Wide_Continuation, "emoji cont marked")
}

// --- Overwrite repair (MECE #17) ---

@(test)
test_p10_overwrite_cont_repair :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D) // cols 0..1
	tg.terminal_move_cursor(&term, 0, 1) // onto cont
	tg.terminal_put_char(&term, 0x00E9) // slow narrow, w=1

	c0 := tg.terminal_get_cell(&term, 0, 0)
	c1 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, c0.content == 0, "orphaned lead blanked")
	testing.expect(t, c1.content == 0x00E9 && c1.width == 1, "new narrow cell written")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 2, "narrow advances +1")
}

@(test)
test_p10_overwrite_lead_repair :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D) // cols 0..1
	tg.terminal_move_cursor(&term, 0, 0) // onto lead
	tg.terminal_put_char(&term, 0x00E9) // slow narrow

	c0 := tg.terminal_get_cell(&term, 0, 0)
	c1 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, c0.content == 0x00E9, "lead overwritten")
	testing.expect(t, c1.content == 0, "orphaned cont blanked")
}

// --- Backspace (MECE #12, #13) ---

@(test)
test_p10_backspace_narrow :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 'a')
	before := tg.terminal_get_cell(&term, 0, 0)
	tg.terminal_backspace(&term)
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 0, "BS over narrow -1")
	after := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, after.content == before.content, "grid untouched by BS")
}

@(test)
test_p10_backspace_wide :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D) // cursor col 2
	tg.terminal_backspace(&term)
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 0, "BS over wide -2 lands lead")
	cell := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell.content == 0x4E2D, "grid untouched by BS")
}

@(test)
test_p10_backspace_col0 :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_backspace(&term)
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 0, "BS at col 0 no-op")
}

// --- Erase repair (MECE #14) ---

@(test)
test_p10_el_split_to_end :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D) // cols 0..1
	tg.terminal_move_cursor(&term, 0, 1)
	tg.terminal_erase_line(&term, .To_End)

	c0 := tg.terminal_get_cell(&term, 0, 0)
	c1 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, c0.content == 0, "orphan lead before start blanked")
	testing.expect(t, c1.content == 0, "range cleared")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "erase never moves cursor")
}

@(test)
test_p10_el_split_to_beginning :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 0, 2)
	tg.terminal_put_char(&term, 0x4E2D) // cols 2..3, cursor col 4
	tg.terminal_move_cursor(&term, 0, 2)
	tg.terminal_erase_line(&term, .To_Beginning) // clears [0..2]

	c2 := tg.terminal_get_cell(&term, 0, 2)
	c3 := tg.terminal_get_cell(&term, 0, 3)
	testing.expect(t, c2.content == 0, "lead in range cleared")
	testing.expect(t, c3.content == 0, "orphan cont past end blanked")
}

// --- TAB with wide (MECE #15) ---

@(test)
test_p10_tab_over_wide :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 0x4E2D) // cols 0..1, cursor 2
	parser: p.Parser
	p.parser_init(&parser)
	p.parse_chunk(&parser, &term, []u8{0x09})

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 8, "TAB pure move 8-(2%8)=6 -> col 8")
	lead := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, lead.content == 0x4E2D, "grid untouched by TAB")
}

// --- Store full (MECE #16) ---

@(test)
test_p10_store_full :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 300 iterations fill the pool despite wrap drops: 'a' at col 79 wraps
	// to col 0, so the following mark (i=79,159,239,…) is dropped NoBase.
	// 300-3 drops = 297 allocs > 256 -> StoreFull path exercised.
	for i in 0..<300 {
		tg.terminal_put_char(&term, 'a')
		tg.terminal_put_char(&term, 0x0301)
	}
	testing.expect(t, term.grapheme_store.live_count == 256, "store capped at 256 live")

	// Last written cell (cursor-1) is base-only.
	cursor := tg.terminal_get_cursor(&term)
	last := tg.terminal_get_cell(&term, cursor.row, cursor.col - 1)
	testing.expect(t, last.content == 'a', "StoreFull keeps base-only")
	testing.expect(t, !tg.content_is_grapheme(last.content), "StoreFull handle is literal")
}

// --- ZWJ (policy) ---

@(test)
test_p10_zwj_sequence :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_put_char(&term, 'A')
	tg.terminal_put_char(&term, 0x200D) // ZWJ extend, +0
	tg.terminal_put_char(&term, 'B') // independent, +1

	c0 := tg.terminal_get_cell(&term, 0, 0)
	c1 := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, tg.content_is_grapheme(c0.content), "ZWJ appended to A cluster")
	testing.expect(t, tg.grapheme_resolve_base(c0.content, &term.grapheme_store) == 'A', "base stays A")
	testing.expect(t, c1.content == 'B', "B in own cell, no ligature")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 2, "ZWJ +0 then B +1")
}

// --- Parser paths (MECE #9 + §6) ---

_feed :: proc(input: []u8) -> tg.Terminal {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	parser: p.Parser
	p.parser_init(&parser)
	p.parse_chunk(&parser, &term, input)
	return term
}

@(test)
test_p10_parse_cafe :: proc(t: ^testing.T) {
	term := _feed([]u8{'c', 'a', 'f', 0xC3, 0xA9})
	defer tg.terminal_destroy(&term)

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'c', "c")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 'a', "a")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 'f', "f")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 3).content == 0x00E9, "é narrow")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 4, "café cursor 4")
}

@(test)
test_p10_parse_cjk :: proc(t: ^testing.T) {
	term := _feed([]u8{0xE4, 0xB8, 0xAD}) // U+4E2D
	defer tg.terminal_destroy(&term)

	lead := tg.grid_get_cell(&term.grid, 0, 0)
	cont := tg.grid_get_cell(&term.grid, 0, 1)
	testing.expect(t, lead.content == 0x4E2D && lead.width == 2, "CJK lead")
	testing.expect(t, cont.flags == .Wide_Continuation, "CJK cont")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 2, "CJK cursor +2")
}

@(test)
test_p10_parse_emoji :: proc(t: ^testing.T) {
	term := _feed([]u8{0xF0, 0x9F, 0x98, 0x80}) // U+1F600
	defer tg.terminal_destroy(&term)

	lead := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, lead.content == 0x1F600 && lead.width == 2, "emoji wide via parser")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 2, "emoji cursor +2")
}

@(test)
test_p10_parse_invalid_utf8 :: proc(t: ^testing.T) {
	// Bad lead (lone continuation).
	term1 := _feed([]u8{0x80})
	defer tg.terminal_destroy(&term1)
	testing.expect(t, tg.grid_get_cell(&term1.grid, 0, 0).content == 0xFFFD, "lone cont -> FFFD")

	// Overlong 2-byte.
	term2 := _feed([]u8{0xC0, 0xAF})
	defer tg.terminal_destroy(&term2)
	testing.expect(t, tg.grid_get_cell(&term2.grid, 0, 0).content == 0xFFFD, "overlong -> FFFD")

	// Surrogate U+D800.
	term3 := _feed([]u8{0xED, 0xA0, 0x80})
	defer tg.terminal_destroy(&term3)
	testing.expect(t, tg.grid_get_cell(&term3.grid, 0, 0).content == 0xFFFD, "surrogate -> FFFD")

	// Out of range U+110000.
	term4 := _feed([]u8{0xF4, 0x90, 0x80, 0x80})
	defer tg.terminal_destroy(&term4)
	testing.expect(t, tg.grid_get_cell(&term4.grid, 0, 0).content == 0xFFFD, ">10FFFF -> FFFD")
}

@(test)
test_p10_parse_new_lead_mid_seq :: proc(t: ^testing.T) {
	// C3 (pending) then C3 A9: dropped lead re-fed, never swallowed.
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	parser: p.Parser
	p.parser_init(&parser)
	p.parse_chunk(&parser, &term, []u8{0xC3})
	p.parse_chunk(&parser, &term, []u8{0xC3, 0xA9})

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 0xFFFD, "dropped lead -> FFFD")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 0x00E9, "re-fed lead completes é")
}

@(test)
test_p10_parse_split_4byte :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	parser: p.Parser
	p.parser_init(&parser)
	p.parse_chunk(&parser, &term, []u8{0xF0, 0x9F})
	p.parse_chunk(&parser, &term, []u8{0x98, 0x80})

	lead := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, lead.content == 0x1F600 && lead.width == 2, "split 4-byte completes across chunks")
}

@(test)
test_p10_parse_mixed_ascii_utf8 :: proc(t: ^testing.T) {
	term := _feed([]u8{'a', 0xC3, 0xA9, 'b'})
	defer tg.terminal_destroy(&term)

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'a', "a")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 0x00E9, "é")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 'b', "b")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 3, "mixed cursor 3")
}

@(test)
test_p10_parse_combining :: proc(t: ^testing.T) {
	term := _feed([]u8{'e', 0xCC, 0x81}) // e + U+0301
	defer tg.terminal_destroy(&term)

	c0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, tg.content_is_grapheme(c0.content), "parser combining clusters")
	testing.expect(t, tg.grapheme_resolve_base(c0.content, &term.grapheme_store) == 'e', "base e")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "combining +0 via parser")
}

@(test)
test_p10_parse_bs :: proc(t: ^testing.T) {
	term := _feed([]u8{'a', 'b', 0x08})
	defer tg.terminal_destroy(&term)

	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "BS -1 via parser")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'a', "grid untouched")
}

// --- CSI @ / P ---

@(test)
test_p10_csi_ich :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	parser: p.Parser
	p.parser_init(&parser)

	p.parse_chunk(&parser, &term, []u8{'a', 'b', 'c', 'd', 'e'})
	tg.terminal_move_cursor(&term, 0, 1)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', '@'})

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'a', "a stays")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 0, "insert blank 1")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 0, "insert blank 2")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 3).content == 'b', "b shifted")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 4).content == 'c', "c shifted")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "ICH never moves cursor")
}

@(test)
test_p10_csi_dch :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	parser: p.Parser
	p.parser_init(&parser)

	p.parse_chunk(&parser, &term, []u8{'a', 'b', 'c', 'd', 'e'})
	tg.terminal_move_cursor(&term, 0, 1)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', 'P'})

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 'a', "a stays")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 'd', "d shifted in")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 2).content == 'e', "e shifted in")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 3).content == 0, "tail blank")
	cursor := tg.terminal_get_cursor(&term)
	testing.expect(t, cursor.col == 1, "DCH never moves cursor")
}

@(test)
test_p10_csi_ich_default_1 :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)
	parser: p.Parser
	p.parser_init(&parser)

	p.parse_chunk(&parser, &term, []u8{'a', 'b', 'c'})
	tg.terminal_move_cursor(&term, 0, 0)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '@'})

	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 0).content == 0, "default ICH inserts 1")
	testing.expect(t, tg.grid_get_cell(&term.grid, 0, 1).content == 'a', "a shifted")
}

// --- ASCII-cost invariant (review grep) ---

@(test)
test_p10_ascii_cost_invariant :: proc(t: ^testing.T) {
	forbidden := [7]string{
		"wcwidth",
		"is_zero_width_extend",
		"grapheme_store_",
		"utf8_feed",
		"TRANSITION_TABLE",
		"BYTE_CLASS",
		"grid_get_cell",
	}

	// ascii_scan.odin: whole file is the fast path.
	scan_data, scan_err := os.read_entire_file("src/parser/ascii_scan.odin", context.allocator)
	testing.expect(t, scan_err == nil, "read ascii_scan.odin")
	if scan_err == nil {
		defer delete(scan_data)
		scan_src := string(scan_data)
		for f in forbidden {
			testing.expect(t, !strings.contains(scan_src, f), "ascii_scan.odin must not contain forbidden call")
		}
	}

	// terminal_put_char ASCII branch: slice from proc start to slow-path marker.
	term_data, term_err := os.read_entire_file("src/terminal/terminal.odin", context.allocator)
	testing.expect(t, term_err == nil, "read terminal.odin")
	if term_err == nil {
		defer delete(term_data)
		term_src := string(term_data)
		start := strings.index(term_src, "terminal_put_char :: proc")
		slow := strings.index(term_src, "terminal_put_char_slow :: proc")
		testing.expect(t, start >= 0 && slow > start, "both procs present in order")
		if start >= 0 && slow > start {
			branch := term_src[start:slow]
			// The ASCII branch ends at the slow call; cut there.
			call := strings.index(branch, "terminal_put_char_slow(t, c)")
			testing.expect(t, call >= 0, "ASCII guard delegates to slow path")
			if call >= 0 {
				ascii_branch := branch[:call]
				testing.expect(t, strings.contains(ascii_branch, "c < 0x80"), "single c<0x80 comparison present")
				for f in forbidden {
					testing.expect(
						t,
						!strings.contains(ascii_branch, f),
						"ASCII branch must not contain forbidden call",
					)
				}
			}
		}
	}

	// terminal_print_run: no slow-path calls.
	parser_data, parser_err := os.read_entire_file("src/parser/parser.odin", context.allocator)
	testing.expect(t, parser_err == nil, "read parser.odin")
	if parser_err == nil {
		defer delete(parser_data)
		parser_src := string(parser_data)
		start := strings.index(parser_src, "terminal_print_run :: proc")
		testing.expect(t, start >= 0, "terminal_print_run present")
		if start >= 0 {
			tail := parser_src[start:]
			end := strings.index(tail, "\n}\n")
			testing.expect(t, end > 0, "terminal_print_run body bounded")
			if end > 0 {
				body := tail[:end]
				for f in forbidden {
					testing.expect(
						t,
						!strings.contains(body, f),
						"terminal_print_run must not contain forbidden call",
					)
				}
			}
		}
	}
}

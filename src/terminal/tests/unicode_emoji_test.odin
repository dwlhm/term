package termgrid_test

import "core:testing"
import tg "../"

@(test)
test_emoji_wcwidth_modern_ranges :: proc(t: ^testing.T) {
	// 🚀 (Rocket) in Transport and Map Symbols (0x1F680..0x1F6FF)
	testing.expect(t, tg.wcwidth(0x1F680) == 2, "0x1F680 (rocket) must be wide (width 2)")

	// Emoticons and pictographs
	testing.expect(t, tg.wcwidth(0x1F600) == 2, "0x1F600 (grinning face) must be wide")
	testing.expect(t, tg.wcwidth(0x1F300) == 2, "0x1F300 (cyclone) must be wide")
	testing.expect(t, tg.wcwidth(0x1F4A9) == 2, "0x1F4A9 (pile of poo) must be wide")

	// Supplementary pictographs & extended
	testing.expect(t, tg.wcwidth(0x1F916) == 2, "0x1F916 (robot) must be wide")
	testing.expect(t, tg.wcwidth(0x1FA70) == 2, "0x1FA70 (ballet shoes) must be wide")
	testing.expect(t, tg.wcwidth(0x1FAFF) == 2, "0x1FAFF must be wide")

	// Mahjong and Playing cards
	testing.expect(t, tg.wcwidth(0x1F004) == 2, "0x1F004 (mahjong) must be wide")
	testing.expect(t, tg.wcwidth(0x1F0A1) == 2, "0x1F0A1 (playing card) must be wide")

	// Regional indicator
	testing.expect(t, tg.wcwidth(0x1F1E6) == 2, "0x1F1E6 (regional indicator A) must be wide")

	// ASCII and standard non-emoji
	testing.expect(t, tg.wcwidth('A') == 1, "'A' must be narrow (width 1)")
	testing.expect(t, tg.wcwidth('1') == 1, "'1' must be narrow (width 1)")
	testing.expect(t, tg.wcwidth(0x0020) == 1, "space must be narrow (width 1)")
}

@(test)
test_is_emoji_codepoint :: proc(t: ^testing.T) {
	testing.expect(t, tg.is_emoji_codepoint(0x1F680), "0x1F680 is emoji")
	testing.expect(t, tg.is_emoji_codepoint(0x1F600), "0x1F600 is emoji")
	testing.expect(t, tg.is_emoji_codepoint(0x231A), "0x231A (watch) is emoji")
	testing.expect(t, tg.is_emoji_codepoint(0x2728), "0x2728 (sparkles) is emoji")
	testing.expect(t, !tg.is_emoji_codepoint('A'), "'A' is not emoji")
	testing.expect(t, !tg.is_emoji_codepoint('1'), "'1' is not emoji codepoint by itself")
}

@(test)
test_grapheme_to_utf8 :: proc(t: ^testing.T) {
	store: tg.Grapheme_Store
	tg.grapheme_store_init(&store)

	buf: [64]u8

	// Literal ASCII
	s_ascii := tg.grapheme_to_utf8(tg.Content_Handle('A'), &store, buf[:])
	testing.expect(t, s_ascii == "A", "literal 'A' encodes to 'A'")

	// Literal Emoji
	s_rocket := tg.grapheme_to_utf8(tg.Content_Handle(0x1F680), &store, buf[:])
	testing.expect(t, s_rocket == "🚀", "literal 0x1F680 encodes to '🚀'")

	// Grapheme cluster: '1' + \uFE0F + \u20E3 (Keycap 1️⃣)
	h := tg.grapheme_store_append(&store, '1', 0xFE0F)
	h = tg.grapheme_store_add_mark(&store, h, 0x20E3)
	s_keycap := tg.grapheme_to_utf8(h, &store, buf[:])
	testing.expect(t, s_keycap == "1\uFE0F\u20E3", "keycap cluster encodes to 1\\uFE0F\\u20E3")

	// Grapheme cluster: 'e' + acute accent (\u0301) -> "é"
	h_e := tg.grapheme_store_append(&store, 'e', 0x0301)
	s_e := tg.grapheme_to_utf8(h_e, &store, buf[:])
	testing.expect(t, s_e == "e\u0301", "combining accent cluster encodes properly")
}

@(test)
test_terminal_keycap_sequence :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// User types '1'
	tg.terminal_put_char(&term, '1')
	testing.expect(t, term.cursor.col == 1, "cursor advanced to col 1 after '1'")
	cell0 := tg.grid_get_cell(&term.grid, 0, 0)
	testing.expect(t, cell0.width == 1, "initial '1' width is 1")

	// Combining mark \uFE0F arrives
	tg.terminal_put_combining(&term, 0xFE0F)

	// Combining mark \u20E3 (keycap) arrives
	tg.terminal_put_combining(&term, 0x20E3)

	// Now cell 0 must be widened to 2, cell 1 must be continuation, and cursor at col 2
	lead := tg.grid_get_cell(&term.grid, 0, 0)
	cont := tg.grid_get_cell(&term.grid, 0, 1)

	testing.expect(t, lead.width == 2, "keycap lead cell width must be 2")
	testing.expect(t, u8(cont.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "cell 1 must be Wide_Continuation")
	testing.expect(t, term.cursor.col == 2, "cursor must be at col 2 after keycap sequence")

	// Check grapheme cluster content
	buf: [64]u8
	cluster_str := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, cluster_str == "1\uFE0F\u20E3", "lead cell cluster content must match 1\\uFE0F\\u20E3")
}

@(test)
test_wcwidth_emoji_bmp_wide :: proc(t: ^testing.T) {
	// Emoji_Presentation=Yes (default wide, no variation selector needed).
	testing.expect(t, tg.wcwidth(0x2614) == 2, "0x2614 (umbrella+rain) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2615) == 2, "0x2615 (hot beverage) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2764) == 2, "0x2764 (red heart) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x26A1) == 2, "0x26A1 (lightning) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2728) == 2, "0x2728 (sparkles) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2702) == 2, "0x2702 (scissors) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2708) == 2, "0x2708 (airplane) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x270C) == 2, "0x270C (victory hand) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2934) == 2, "0x2934 (curved arrow) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x2B05) == 2, "0x2B05 (left arrow) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x25B6) == 2, "0x25B6 (play button) must be wide (EP)")
	testing.expect(t, tg.wcwidth(0x25FB) == 2, "0x25FB (medium white square) must be wide (EP)")
	// Emoji WITHOUT Emoji_Presentation: text-default (narrow) unless followed by U+FE0F.
	testing.expect(t, tg.wcwidth(0x2603) == 1, "0x2603 (snowman) must be narrow (text default)")
	testing.expect(t, tg.wcwidth(0x2601) == 1, "0x2601 (cloud) must be narrow (text default)")
	testing.expect(t, tg.wcwidth(0x26A0) == 1, "0x26A0 (warning sign) must be narrow (text default)")
	testing.expect(t, tg.wcwidth(0x2194) == 1, "0x2194 (left-right arrow) must be narrow (text default)")
	// Variation selectors and ZWJ must remain zero-width.
	testing.expect(t, tg.wcwidth(0xFE0F) == 0, "0xFE0F (VS16) must remain zero-width")
	testing.expect(t, tg.wcwidth(0x200D) == 0, "0x200D (ZWJ) must remain zero-width")
}

@(test)
test_zwj_sequence_absorb :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Feed: 👨 (U+1F468) — wide emoji, occupies col 0..1
	tg.terminal_put_char(&term, 0x1F468)
	testing.expect(t, term.cursor.col == 2, "after 👨 cursor at col 2")

	// Feed: ZWJ (U+200D) — zero-width extend, appended as mark to col 0 cluster
	tg.terminal_put_char(&term, 0x200D)
	testing.expect(t, term.cursor.col == 2, "ZWJ does not advance cursor")

	// Feed: 💼 (U+1F4BC) — emoji, but preceding cell has trailing ZWJ → absorbed
	tg.terminal_put_char(&term, 0x1F4BC)
	testing.expect(t, term.cursor.col == 2, "ZWJ-absorbed emoji does not advance cursor")

	// col 0: wide lead, grapheme cluster = "👨\u200D💼"
	lead := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, lead.width == 2, "ZWJ emoji lead must be wide")
	testing.expect(t, tg.content_is_grapheme(lead.content), "ZWJ emoji stored as grapheme handle")

	buf: [64]u8
	cluster_str := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, cluster_str == "👨\u200D💼", "cluster must encode full ZWJ sequence")

	// col 2 must be empty (no stray 💼 cell)
	empty_cell := tg.terminal_get_cell(&term, 0, 2)
	testing.expect(t, empty_cell.content == 0, "no stray emoji cell after ZWJ absorb")
}

@(test)
test_zwj_family_emoji :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 👨👩👦 = U+1F468 ZWJ U+1F469 ZWJ U+1F466
	tg.terminal_put_char(&term, 0x1F468) // 👨
	tg.terminal_put_char(&term, 0x200D)  // ZWJ
	tg.terminal_put_char(&term, 0x1F469) // 👩 — absorbed
	tg.terminal_put_char(&term, 0x200D)  // ZWJ — appended as mark (extending)
	tg.terminal_put_char(&term, 0x1F466) // 👦 — absorbed

	// Only one wide cell written, cursor at col 2.
	testing.expect(t, term.cursor.col == 2, "family emoji: single wide cell, cursor at col 2")

	lead := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, lead.width == 2, "family emoji lead must be wide")

	buf: [64]u8
	cluster_str := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, cluster_str == "👨\u200D👩\u200D👦", "cluster encodes full family sequence")
}

@(test)
test_uax29_classification :: proc(t: ^testing.T) {
	testing.expect(t, tg.uax29_classify(0x200D) == .ZWJ, "0x200D is ZWJ")
	testing.expect(t, tg.uax29_classify(0x1F3FB) == .Emoji_Modifier, "0x1F3FB is Emoji_Modifier")
	testing.expect(t, tg.uax29_classify(0x1F3FF) == .Emoji_Modifier, "0x1F3FF is Emoji_Modifier")
	testing.expect(t, tg.uax29_classify(0x1F1E6) == .Regional_Indicator, "0x1F1E6 is Regional_Indicator")
	testing.expect(t, tg.uax29_classify(0x1F1FF) == .Regional_Indicator, "0x1F1FF is Regional_Indicator")
	testing.expect(t, tg.uax29_classify(0x0301) == .Extend, "0x0301 is Extend")
	testing.expect(t, tg.uax29_classify(0xFE0F) == .Extend, "0xFE0F is Extend")
	testing.expect(t, tg.uax29_classify(0x1F469) == .Extended_Pictographic, "0x1F469 is Extended_Pictographic")
	testing.expect(t, tg.uax29_classify('A') == .Other, "'A' is Other")
}

@(test)
test_zwj_skin_tone_sequence :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 👩🏽‍💻 = Woman (0x1F469) + Medium Skin Tone (0x1F3FD) + ZWJ (0x200D) + Laptop (0x1F4BB)
	tg.terminal_put_char(&term, 0x1F469)
	testing.expect(t, term.cursor.col == 2, "initial woman emoji advances to col 2")
	tg.terminal_put_char(&term, 0x1F3FD)
	testing.expect(t, term.cursor.col == 2, "skin tone modifier absorbed without cursor advance")
	tg.terminal_put_char(&term, 0x200D)
	testing.expect(t, term.cursor.col == 2, "ZWJ absorbed without cursor advance")
	tg.terminal_put_char(&term, 0x1F4BB)
	testing.expect(t, term.cursor.col == 2, "laptop absorbed without cursor advance")

	lead := tg.terminal_get_cell(&term, 0, 0)
	cont := tg.terminal_get_cell(&term, 0, 1)
	empty_cell := tg.terminal_get_cell(&term, 0, 2)

	testing.expect(t, lead.width == 2, "compound emoji lead width must be 2")
	testing.expect(t, tg.content_is_grapheme(lead.content), "compound emoji stored in grapheme store")
	testing.expect(t, u8(cont.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "col 1 must be Wide_Continuation")
	testing.expect(t, empty_cell.content == 0, "col 2 must be empty")

	buf: [64]u8
	cluster_str := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, cluster_str == "👩🏽\u200D💻", "cluster encodes full woman laptop skin tone sequence")
}

@(test)
test_flag_sequence :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 🇮🇩 = Regional Indicator Symbol Letter I (0x1F1EE) + D (0x1F1E9)
	tg.terminal_put_char(&term, 0x1F1EE)
	testing.expect(t, term.cursor.col == 2, "first RI occupies wide cell at col 0..1, cursor at col 2")
	tg.terminal_put_char(&term, 0x1F1E9)
	testing.expect(t, term.cursor.col == 2, "second RI absorbed into anchor flag pair, cursor stays at col 2")

	lead := tg.terminal_get_cell(&term, 0, 0)
	cont := tg.terminal_get_cell(&term, 0, 1)
	empty_cell := tg.terminal_get_cell(&term, 0, 2)

	testing.expect(t, lead.width == 2, "flag lead width must be 2")
	testing.expect(t, tg.content_is_grapheme(lead.content), "flag pair stored in grapheme store")
	testing.expect(t, u8(cont.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "col 1 must be Wide_Continuation")
	testing.expect(t, empty_cell.content == 0, "col 2 must be empty")

	buf: [64]u8
	cluster_str := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, cluster_str == "🇮🇩", "cluster encodes full flag sequence")
}

@(test)
test_flag_triplet_break :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// 🇮🇩🇯 = 0x1F1EE + 0x1F1E9 + 0x1F1EF
	// First two complete flag pair (col 0..1); third breaks and starts new cluster (col 2..3)
	tg.terminal_put_char(&term, 0x1F1EE)
	tg.terminal_put_char(&term, 0x1F1E9)
	testing.expect(t, term.cursor.col == 2, "cursor at col 2 after first flag pair")

	tg.terminal_put_char(&term, 0x1F1EF)
	testing.expect(t, term.cursor.col == 4, "cursor at col 4 after third RI (splits into new wide cell)")

	lead0 := tg.terminal_get_cell(&term, 0, 0)
	cont0 := tg.terminal_get_cell(&term, 0, 1)
	lead1 := tg.terminal_get_cell(&term, 0, 2)
	cont1 := tg.terminal_get_cell(&term, 0, 3)
	empty4 := tg.terminal_get_cell(&term, 0, 4)

	testing.expect(t, lead0.width == 2, "first flag lead width is 2")
	testing.expect(t, u8(cont0.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "col 1 is Wide_Continuation")
	testing.expect(t, lead1.width == 2, "second RI lead width is 2")
	testing.expect(t, u8(cont1.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "col 3 is Wide_Continuation")
	testing.expect(t, empty4.content == 0, "col 4 is empty")

	buf: [64]u8
	s0 := tg.grapheme_to_utf8(lead0.content, &term.grapheme_store, buf[:])
	testing.expect(t, s0 == "🇮🇩", "first cluster is ID flag")
	s1 := tg.grapheme_to_utf8(lead1.content, &term.grapheme_store, buf[:])
	testing.expect(t, s1 == "🇯", "second cluster is single J RI")
}

@(test)
test_keycap_widening :: proc(t: ^testing.T) {
	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// '1' + 0xFE0F + 0x20E3 via terminal_put_char
	tg.terminal_put_char(&term, '1')
	testing.expect(t, term.cursor.col == 1, "col 1 after '1'")
	cell0 := tg.terminal_get_cell(&term, 0, 0)
	testing.expect(t, cell0.width == 1, "width 1 initially")

	tg.terminal_put_char(&term, 0xFE0F)
	testing.expect(t, term.cursor.col == 1, "cursor still at col 1 after VS16")

	tg.terminal_put_char(&term, 0x20E3)
	testing.expect(t, term.cursor.col == 2, "cursor advanced to col 2 after keycap widening")

	lead := tg.terminal_get_cell(&term, 0, 0)
	cont := tg.terminal_get_cell(&term, 0, 1)
	testing.expect(t, lead.width == 2, "lead width widened to 2")
	testing.expect(t, u8(cont.flags) & u8(tg.Cell_Flags.Wide_Continuation) != 0, "col 1 is continuation")

	buf: [64]u8
	s := tg.grapheme_to_utf8(lead.content, &term.grapheme_store, buf[:])
	testing.expect(t, s == "1\uFE0F\u20E3", "keycap encoded properly")
}

@(test)
test_grapheme_inline_cap_overflow :: proc(t: ^testing.T) {
	cluster := tg.grapheme_cluster_make('A')
	testing.expect_value(t, cluster.rune_count, 1)

	for i in 1..<tg.GRAPHEME_INLINE_CAP {
		ok := tg.grapheme_cluster_append(&cluster, 0x0300 + rune(i))
		testing.expect(t, ok, "append within inline cap must succeed")
	}
	testing.expect_value(t, int(cluster.rune_count), tg.GRAPHEME_INLINE_CAP)

	// 17th rune must be safely dropped and return false
	ok_overflow := tg.grapheme_cluster_append(&cluster, 0x0350)
	testing.expect(t, !ok_overflow, "17th rune must return false and clamp")
	testing.expect_value(t, int(cluster.rune_count), tg.GRAPHEME_INLINE_CAP)

	// In-store append:
	store: tg.Grapheme_Store
	tg.grapheme_store_init(&store)
	h := tg.grapheme_store_append(&store, 'A', 0x0301)
	for i in 2..<tg.GRAPHEME_INLINE_CAP + 5 {
		h = tg.grapheme_store_add_rune(&store, h, 0x0300 + rune(i))
	}
	idx := int(h - tg.CONTENT_GRAPHEME_BASE)
	testing.expect_value(t, int(store.entries[idx].rune_count), tg.GRAPHEME_INLINE_CAP)
}

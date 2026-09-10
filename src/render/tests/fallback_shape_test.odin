package render_tests

// Phase 11 tests: fallback resolver, shape cache identity, Arabic joining,
// marks/VS16/ZWJ policy, FIFO healing, tofu cracks, and the ASCII invariant.
//
// Font fixtures (macOS system fonts, coverage verified at probe time):
//   primary  Menlo.ttc           Latin, tofu U+25A1/U+FFFD, box U+2500
//   fallback GeezaPro.ttc        Arabic BEH + presentation forms + Fatha + ZWJ
//   fallback Hiragino Sans GB    CJK U+4E2D
// U+10FFFF is uncovered in all three (assumed per probe, asserted in-test).

import "core:testing"
import render "../"
import instance "../instance"
import termgrid "../../terminal"

TEST_PRIMARY_FONT :: "/System/Library/Fonts/Menlo.ttc"
TEST_ARABIC_FONT  :: "/System/Library/Fonts/GeezaPro.ttc"
TEST_CJK_FONT     :: "/System/Library/Fonts/Hiragino Sans GB.ttc"

// _fb_chain loads primary + both fallbacks; expects count == 3.
_fb_chain :: proc(t: ^testing.T, chain: ^render.Fallback_Chain, prim: ^render.Font_Rasterizer) {
	paths := [2]string{TEST_ARABIC_FONT, TEST_CJK_FONT}
	ok := render.fallback_chain_init(chain, prim, paths[:], 16.0, context.allocator)
	testing.expect(t, ok, "chain init must succeed")
	testing.expect_value(t, chain.count, 3)
}

// _fb_prim loads the primary font; expects success.
_fb_prim :: proc(t: ^testing.T, prim: ^render.Font_Rasterizer) {
	ok := render.font_rasterizer_init(prim, TEST_PRIMARY_FONT, 16.0, nil, context.allocator)
	testing.expect(t, ok, "primary font must load")
}

// _fb_lut rebuilds a LUT from a terminal's style table.
_fb_lut :: proc(term: ^termgrid.Terminal) -> render.Style_LUT {
	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &term.grid.style_table)
	return lut
}

// _fb_shaped looks up the cached Shaped_Glyph for a grid cell.
_fb_shaped :: proc(
	term: ^termgrid.Terminal,
	cache: ^render.Shape_Cache,
	row, col: int,
	form: render.Join_Form,
) -> (render.Shaped_Glyph, bool) {
	cell := termgrid.grid_get_cell(&term.grid, row, col)
	key := render.cluster_key_from_handle(cell.content, &term.grapheme_store, form)
	return render.shape_cache_lookup(cache, key)
}

@(test)
test_fallback_probe_order :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)

	// Missing files reduce the count, never fail.
	bogus: render.Fallback_Chain
	bogus_paths := [1]string{"/nonexistent/font.ttf"}
	testing.expect(t, render.fallback_chain_init(&bogus, &prim, bogus_paths[:], 16.0, context.allocator))
	testing.expect_value(t, bogus.count, 1)
	render.fallback_chain_destroy(&bogus)

	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	counters: render.Fallback_Counters
	fi, cov := render.fallback_resolve(&chain, 0xE9, &counters)
	testing.expect(t, cov && fi == 0, "e-acute must resolve at slot 0")
	fi, cov = render.fallback_resolve(&chain, 0x0628, &counters)
	testing.expect(t, cov && fi == 1, "BEH must resolve at slot 1")
	fi, cov = render.fallback_resolve(&chain, 0x4E2D, &counters)
	testing.expect(t, cov && fi == 2, "CJK must resolve at slot 2")
	testing.expect_value(t, counters.probe_miss, u64(2))
	testing.expect_value(t, counters.fallback_hit[0], u64(1))
	testing.expect_value(t, counters.fallback_hit[1], u64(1))
	testing.expect_value(t, counters.fallback_hit[2], u64(1))

	_, cov = render.fallback_resolve(&chain, 0x10FFFF, &counters)
	testing.expect(t, !cov, "U+10FFFF must exhaust the chain")
	testing.expect_value(t, counters.fallback_miss, u64(1))

	// Row 7: tofu itself missing (empty chain) → bg-only skip, never panic.
	empty: render.Fallback_Chain
	defer render.fallback_chain_destroy(&empty)
	ecounters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 3)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, rune(0x4E2D))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 3)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	ecache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &empty, &ecache, &atlas, &ecounters)
	content, _, _, _, _ := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, content, u32(0))
	testing.expect_value(t, ecounters.tofu_missing, u64(1))
	testing.expect_value(t, ecounters.fallback_miss, u64(3))
	lut := _fb_lut(&term)
	bg, glyph: instance.Instance_Data
	_, emit_glyph := render.render_cell_expand_instance(frame.cells[0], &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_glyph, "tofu-missing must emit no glyph")
}

@(test)
test_prewarm_through_chain :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	// Simulate a primary gap, then fill through the chain.
	atlas.slots[95].valid = false
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	render.atlas_prewarm_chain(&atlas, &chain)
	testing.expect(t, atlas.slots[95].valid, "box slot must refill through chain")
	testing.expect_value(t, atlas.pinned_count, render.PINNED_TOTAL)

	// Dynamic tags survive prewarm; an empty chain fills nothing.
	atlas.slots[95].valid = false
	atlas.fallback_tag[0] = (u64(2) << 32) | u64(0x4E2D)
	empty: render.Fallback_Chain
	defer render.fallback_chain_destroy(&empty)
	render.atlas_prewarm_chain(&atlas, &empty)
	testing.expect(t, !atlas.slots[95].valid, "empty chain must fill nothing")
	testing.expect_value(t, atlas.fallback_tag[0], (u64(2) << 32) | u64(0x4E2D))
}

@(test)
test_arabic_join_forms :: proc(t: ^testing.T) {
	testing.expect(t, render.arabic_join_type(0x0628) == .Dual_Joining, "BEH dual")
	testing.expect(t, render.arabic_join_type(0x0627) == .Right_Joining, "ALEF right")
	testing.expect(t, render.arabic_join_type(0x064B) == .Transparent, "Fatha transparent")
	testing.expect(t, render.arabic_join_type(0x200D) == .Join_Causing_ZWJ, "ZWJ causing")
	testing.expect(t, render.arabic_join_type(0x200C) == .Non_Joining, "ZWNJ non-joining")
	testing.expect(t, render.arabic_join_type(0x41) == .Non_Joining, "Latin non-joining")
	testing.expect_value(t, render.ARABIC_ZWNJ, rune(0x200C))

	// Dual truth table.
	testing.expect(t, render.arabic_join_form(true, true, .Dual_Joining) == .Medial)
	testing.expect(t, render.arabic_join_form(true, false, .Dual_Joining) == .Final)
	testing.expect(t, render.arabic_join_form(false, true, .Dual_Joining) == .Initial)
	testing.expect(t, render.arabic_join_form(false, false, .Dual_Joining) == .Isolated)
	// Right joins backward only.
	testing.expect(t, render.arabic_join_form(true, true, .Right_Joining) == .Final)
	testing.expect(t, render.arabic_join_form(false, true, .Right_Joining) == .Isolated)
	testing.expect(t, render.arabic_join_form(true, false, .Right_Joining) == .Final)
	testing.expect(t, render.arabic_join_form(false, false, .Right_Joining) == .Isolated)
	// The rest are always isolated.
	testing.expect(t, render.arabic_join_form(true, true, .Non_Joining) == .Isolated)
	testing.expect(t, render.arabic_join_form(true, true, .Transparent) == .Isolated)
	testing.expect(t, render.arabic_join_form(true, true, .Join_Causing_ZWJ) == .Isolated)
	// Neighbors are transparent only for marks.
	testing.expect(t, render.arabic_left_joins(0x0628, .Dual_Joining), "dual links forward")
	testing.expect(t, !render.arabic_left_joins(0x0627, .Right_Joining), "right never links forward")
	testing.expect(t, !render.arabic_left_joins(0x200D, .Join_Causing_ZWJ), "ZWJ never links")
}

@(test)
test_presentation_fallback :: proc(t: ^testing.T) {
	// Pure table: medial BEH, inapplicable ALEF-initial, unknown base.
	shaped, ok := render.arabic_presentation_form(0x0628, .Medial)
	testing.expect(t, ok && shaped == 0xFE92, "BEH medial is FE92")
	_, ok = render.arabic_presentation_form(0x0627, .Initial)
	testing.expect(t, !ok, "ALEF has no initial form")
	_, ok = render.arabic_presentation_form(0x0041, .Isolated)
	testing.expect(t, !ok, "Latin has no presentation form")

	// Row 6 end-to-end: uncovered anywhere → tofu box, never panic.
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, rune(0x10FFFF))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)
	testing.expect(t, counters.fallback_miss >= 1, "uncovered codepoint must miss")
	g, hit := _fb_shaped(&term, &cache, 0, 0, .Isolated)
	testing.expect(t, hit, "tofu must be cached")
	testing.expect_value(t, g.shaped_codepoint, u32(render.FALLBACK_TOFU_PRIMARY))
	testing.expect(t, atlas.slots[g.atlas_slot].valid, "tofu slot must be valid")
	lut := _fb_lut(&term)
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph := render.render_cell_expand_instance(frame.cells[0], &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "tofu must emit bg+glyph")
}

@(test)
test_zwj_no_ligature :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 4)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, rune(0x0628))
	termgrid.terminal_put_char(&term, rune(0x0628))
	termgrid.terminal_put_char(&term, rune(0x200D)) // attaches to cell 1
	termgrid.terminal_put_char(&term, rune(0x0628))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 4)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)

	// Cell 0 (row start): initial. Cell 1 carries the ZWJ: left joins, own
	// ZWJ forces a right boundary → final. Never merges: 3 narrow cells.
	g0, hit0 := _fb_shaped(&term, &cache, 0, 0, .Initial)
	testing.expect(t, hit0, "lead BEH must cache initial")
	testing.expect_value(t, g0.shaped_codepoint, u32(0xFE91))
	g1, hit1 := _fb_shaped(&term, &cache, 0, 1, .Final)
	testing.expect(t, hit1, "ZWJ cell must cache final, never merge")
	testing.expect_value(t, g1.shaped_codepoint, u32(0xFE90))
	testing.expect(t, g0.atlas_slot != g1.atlas_slot, "cells must hold separate slots")
	for col in 0..<3 {
		_, _, w, _, slot := render.render_cell_unpack_v2(frame.cells[col])
		testing.expect_value(t, w, render.RENDER_CELL_V2_WIDTH_NARROW)
		testing.expect(t, slot != render.RENDER_CELL_V2_SLOT_UNRESOLVED, "cell must resolve")
	}
	testing.expect_value(t, counters.mark_drop, u64(0))
}

@(test)
test_vs16_mark_wide :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 4)
	defer termgrid.terminal_destroy(&term)
	// Store-direct: terminal combining attaches to col-1, which is the
	// continuation cell for wide bases, so wide+mark clusters are built
	// in the pool (the shaping under test, not input policy).
	h := termgrid.grapheme_store_append(&term.grapheme_store, rune(0x4E2D), rune(0xFE0F))
	termgrid.grid_set_cell(&term.grid, 0, 0, termgrid.Semantic_Cell{content = h, style = 0, width = 2})
	termgrid.grid_set_cell(&term.grid, 0, 1, termgrid.Semantic_Cell{content = 0, style = 0, width = 1, flags = .Wide_Continuation})
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 4)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)

	// Key carries VS16 as mark0; the probe uses the base only.
	cell := termgrid.grid_get_cell(&term.grid, 0, 0)
	key := render.cluster_key_from_handle(cell.content, &term.grapheme_store, .Isolated)
	testing.expect_value(t, key.mark0, rune(0xFE0F))
	g, hit := render.shape_cache_lookup(&cache, key)
	testing.expect(t, hit, "CJK+VS16 must cache")
	testing.expect_value(t, g.shaped_codepoint, u32(0x4E2D))
	testing.expect(t, g.wide, "CJK base must flag wide")
	testing.expect_value(t, counters.mark_drop, u64(1))

	// Wide lead + continuation pair; monochrome base slot, no variant switch.
	_, _, w0, _, slot0 := render.render_cell_unpack_v2(frame.cells[0])
	_, _, w1, _, _ := render.render_cell_unpack_v2(frame.cells[1])
	testing.expect_value(t, w0, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD)
	testing.expect_value(t, w1, render.RENDER_CELL_V2_WIDTH_CONTINUATION)
	testing.expect(t, slot0 != render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	lut := _fb_lut(&term)
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph := render.render_cell_expand_instance(frame.cells[0], &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "wide lead must emit")
	testing.expect(t, glyph.cw == 16.0, "wide lead spans double width")
	emit_bg1, emit_glyph1 := render.render_cell_expand_instance(frame.cells[1], &lut, &atlas, 8, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_bg1 && !emit_glyph1, "continuation emits nothing")
}

@(test)
test_cross_font_composite :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 4)
	defer termgrid.terminal_destroy(&term)

	// Base 'A' lives in the primary, Fatha only in the Arabic fallback:
	// independent probes, ONE composited slot (boundary invisible).
	// Puts go through the cursor; store clusters are placed directly.
	termgrid.terminal_put_char(&term, rune(0x0628)) // col 0
	termgrid.terminal_move_cursor(&term, 0, 2)
	termgrid.terminal_put_char(&term, rune(0x0628)) // col 2
	h := termgrid.grapheme_store_append(&term.grapheme_store, rune(0x41), rune(0x064B))
	termgrid.grid_set_cell(&term.grid, 0, 3, termgrid.Semantic_Cell{content = h, style = 0, width = 1})
	// Fatha look-through: BEH+Fatha between joining BEHs still takes medial.
	h2 := termgrid.grapheme_store_append(&term.grapheme_store, rune(0x0628), rune(0x064B))
	termgrid.grid_set_cell(&term.grid, 0, 1, termgrid.Semantic_Cell{content = h2, style = 0, width = 1})

	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 4)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)

	g, hit := _fb_shaped(&term, &cache, 0, 3, .Isolated)
	testing.expect(t, hit, "cross-font cluster must cache")
	testing.expect_value(t, g.font_index, u8(0))
	testing.expect_value(t, g.shaped_codepoint, u32(0x41))
	testing.expect(t, atlas.slots[g.atlas_slot].valid, "composited slot must be valid")
	testing.expect_value(t, counters.mark_drop, u64(0))
	testing.expect_value(t, cache.live, 4)

	g0, hit0 := _fb_shaped(&term, &cache, 0, 0, .Initial)
	testing.expect(t, hit0 && g0.shaped_codepoint == 0xFE91, "lead BEH must be initial")
	g2, hit2 := _fb_shaped(&term, &cache, 0, 1, .Medial)
	testing.expect(t, hit2, "Fatha must not break the join")
	testing.expect_value(t, g2.shaped_codepoint, u32(0xFE92))
	gf, hitf := _fb_shaped(&term, &cache, 0, 2, .Final)
	testing.expect(t, hitf && gf.shaped_codepoint == 0xFE90, "BEH before Latin must be final")
}

@(test)
test_mark_drop :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	// U+034F is combining (terminal-attached) but covered nowhere.
	_, cov := render.fallback_resolve(&chain, 0x034F, nil)
	testing.expect(t, !cov, "test mark must be uncovered everywhere")
	termgrid.terminal_put_char(&term, rune(0xE9))
	termgrid.terminal_put_char(&term, rune(0x034F))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)

	// Base never sacrificed: base-only slot, drop counted once.
	testing.expect_value(t, counters.mark_drop, u64(1))
	g, hit := _fb_shaped(&term, &cache, 0, 0, .Isolated)
	testing.expect(t, hit, "base must cache without its mark")
	testing.expect_value(t, g.shaped_codepoint, u32(0xE9))
	testing.expect(t, atlas.slots[g.atlas_slot].valid, "base-only slot must be valid")
}

@(test)
test_cache_identity_not_handle :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, rune(0x0628))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache

	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)
	_, _, _, _, slot_a := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, cache.live, 1)
	hits_before := counters.fallback_hit

	// Second frame: identical slot, no new probes (row 4).
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)
	_, _, _, _, slot_b := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, slot_a, slot_b)
	testing.expect_value(t, cache.live, 1)
	testing.expect(t, counters.fallback_hit == hits_before, "cache hit must probe nothing")

	// Same value in a fresh handle shares the entry; a new join form does not.
	term2: termgrid.Terminal
	termgrid.terminal_init(&term2, 1, 2)
	defer termgrid.terminal_destroy(&term2)
	termgrid.terminal_put_char(&term2, rune(0x0628))
	frame2: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame2, 1, 2)
	defer render.render_compiler_destroy_v2(&frame2)
	render.render_compile_full_v2(&frame2, &term2, &chain, &cache, &atlas, &counters)
	_, _, _, _, slot_edge := render.render_cell_unpack_v2(frame2.cells[0])
	testing.expect_value(t, slot_edge, slot_a)
	testing.expect_value(t, cache.live, 1)

	term3: termgrid.Terminal
	termgrid.terminal_init(&term3, 1, 4)
	defer termgrid.terminal_destroy(&term3)
	termgrid.terminal_put_char(&term3, rune(0x0628))
	termgrid.terminal_put_char(&term3, rune(0x0628))
	termgrid.terminal_put_char(&term3, rune(0x0628))
	frame3: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame3, 1, 4)
	defer render.render_compiler_destroy_v2(&frame3)
	render.render_compile_full_v2(&frame3, &term3, &chain, &cache, &atlas, &counters)
	gm, hitm := _fb_shaped(&term3, &cache, 0, 1, .Medial)
	testing.expect(t, hitm, "medial BEH must cache separately")
	testing.expect_value(t, gm.shaped_codepoint, u32(0xFE92))
	testing.expect(t, gm.atlas_slot != slot_a, "join form changes identity")
}

@(test)
test_cache_evict_bounded :: proc(t: ^testing.T) {
	cache: render.Shape_Cache
	for i in 0..<(render.SHAPE_CACHE_CAP + 1) {
		k := render.Cluster_Key{base = rune(0x200 + i), join_form = .Isolated}
		g := render.Shaped_Glyph{font_index = 0, shaped_codepoint = u32(0x200 + i), atlas_slot = u16(271 + (i % 241))}
		render.shape_cache_insert(&cache, k, g)
	}
	testing.expect_value(t, cache.live, render.SHAPE_CACHE_CAP)
	testing.expect(t, cache.evictions >= 1, "overflow must count a bounded eviction")
}

@(test)
test_fifo_evict_heals :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	paths := [0]string{}
	testing.expect(t, render.fallback_chain_init(&chain, &prim, paths[:], 16.0, context.allocator))
	testing.expect_value(t, chain.count, 1)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, rune(0xE9))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache

	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)
	g0, hit0 := _fb_shaped(&term, &cache, 0, 0, .Isolated)
	testing.expect(t, hit0, "e-acute must cache")
	testing.expect_value(t, int(g0.atlas_slot), render.FALLBACK_SLOT_BASE)

	// Simulate a FIFO eviction of that slot by a newer glyph.
	atlas.fallback_tag[0] = (u64(0) << 32) | u64(0x41)
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)
	g1, hit1 := _fb_shaped(&term, &cache, 0, 0, .Isolated)
	testing.expect(t, hit1, "stale entry must lazily re-resolve")
	testing.expect(t, int(g1.atlas_slot) != render.FALLBACK_SLOT_BASE, "healed slot must advance FIFO")
	testing.expect_value(t, atlas.fallback_tag[int(g1.atlas_slot) - render.FALLBACK_SLOT_BASE], u64(0xE9))
	lut := _fb_lut(&term)
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph := render.render_cell_expand_instance(frame.cells[0], &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "healed cell must emit")
}

@(test)
test_ascii_invariant :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 2, 8)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_string(&term, "Hello, World! 123")

	legacy: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&legacy, 2, 8)
	defer render.render_compiler_destroy_v2(&legacy)
	render.render_compile_full_v2(&legacy, &term)

	shaped: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&shaped, 2, 8)
	defer render.render_compiler_destroy_v2(&shaped)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&shaped, &term, &chain, &cache, &atlas, &counters)

	testing.expect(t, len(legacy.cells) == len(shaped.cells), "frame sizes must match")
	for i in 0..<len(legacy.cells) {
		if legacy.cells[i] != shaped.cells[i] {
			testing.expect(t, false, "ASCII frames must be bit-identical")
			break
		}
	}
	testing.expect_value(t, cache.live, 0)
	testing.expect_value(t, counters.probe_miss, u64(0))
	testing.expect_value(t, counters.fallback_miss, u64(0))
	testing.expect_value(t, counters.mark_drop, u64(0))
	testing.expect_value(t, counters.tofu_missing, u64(0))
	testing.expect_value(t, counters.fallback_hit[0], u64(0))
	testing.expect_value(t, atlas.fallback_cursor, 0)
	for i in 0..<render.FALLBACK_SLOT_COUNT {
		if atlas.fallback_tag[i] != 0 {
			testing.expect(t, false, "ASCII frames must write no dynamic tags")
			break
		}
	}
}

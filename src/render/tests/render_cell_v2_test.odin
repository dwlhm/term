package render_tests

// Tests for Render_Cell_V2 pack/unpack, overflow cracks, continuation,
// empty skip, SoA/AoS equivalence, and LUT rebuild parity.

import "core:testing"
import render "../"
import instance "../instance"
import termgrid "../../terminal"

// _test_atlas builds a CPU-only atlas with valid pinned ASCII slots.
_test_atlas :: proc() -> render.Atlas {
	atlas: render.Atlas
	atlas.slot_count = render.ATLAS_SLOT_COUNT
	for cp in 32..<127 {
		if idx, ok := render.atlas_pinned_slot_index(u32(cp)); ok {
			atlas.slots[idx] = render.Atlas_Slot{u0 = 0, v0 = 0, u1 = 1, v1 = 1, advance = 8, valid = true}
		}
	}
	return atlas
}

// _test_lut builds a 2-entry LUT: entry 0 white-on-black, entry 1 red-on-blue.
_test_lut :: proc() -> render.Style_LUT {
	lut: render.Style_LUT
	lut.fg_r5g6b5[0] = render.color_to_r5g6b5(0xFFFFFFFF)
	lut.bg_r5g6b5[0] = render.color_to_r5g6b5(0xFF000000)
	lut.fg_r5g6b5[1] = render.color_to_r5g6b5(0xFFFF0000)
	lut.bg_r5g6b5[1] = render.color_to_r5g6b5(0xFF0000FF)
	lut.selection_fg_r5g6b5 = render.color_to_r5g6b5(0xFF00FF00)
	lut.selection_bg_r5g6b5 = render.color_to_r5g6b5(0xFF663399)
	lut.count = 2
	return lut
}

@(test)
test_pack_unpack_roundtrip :: proc(t: ^testing.T) {
	// Happy narrow printable.
	v := render.render_cell_pack_v2(0x41, 7, 1, 0, 33)
	content, style, width, cflags, slot := render.render_cell_unpack_v2(v)
	testing.expect_value(t, content, u32(0x41))
	testing.expect_value(t, style, u16(7))
	testing.expect_value(t, width, u8(1))
	testing.expect_value(t, cflags, u8(0))
	testing.expect_value(t, slot, u16(33))

	// Field extremes roundtrip.
	v2 := render.render_cell_pack_v2(0x1FFFFF, 1023, 2, 0x7F, 511)
	c2, s2, w2, cf2, sl2 := render.render_cell_unpack_v2(v2)
	testing.expect_value(t, c2, u32(0x1FFFFF))
	testing.expect_value(t, s2, u16(1023))
	testing.expect_value(t, w2, u8(2))
	testing.expect_value(t, cf2, u8(0x7F))
	testing.expect_value(t, sl2, u16(511))

	// from_semantic roundtrip on a printable cell.
	sem := termgrid.Semantic_Cell{content = 0x48, style = 5, width = 1, flags = .None}
	v3 := render.render_cell_from_semantic(sem)
	c3, s3, w3, _, sl3 := render.render_cell_unpack_v2(v3)
	testing.expect_value(t, c3, u32(0x48))
	testing.expect_value(t, s3, u16(5))
	testing.expect_value(t, w3, u8(1))
	testing.expect_value(t, sl3, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
}

@(test)
test_pack_overflow_truncation :: proc(t: ^testing.T) {
	// CodepointOverflow → truncate to 21 bits (0x200000 & 0x1FFFFF == 0).
	v := render.render_cell_pack_v2(0x200000, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	content, _, _, _, _ := render.render_cell_unpack_v2(v)
	testing.expect_value(t, content, u32(0))

	// FlagsReserved → masked to 7 bits.
	vf := render.render_cell_pack_v2(0x41, 0, 1, 0xFF, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, _, cf, _ := render.render_cell_unpack_v2(vf)
	testing.expect_value(t, cf, u8(0x7F))

	// WidthReserved (3) → normalized to 1.
	vw := render.render_cell_pack_v2(0x41, 0, 3, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, w, _, _ := render.render_cell_unpack_v2(vw)
	testing.expect_value(t, w, u8(1))

	// Codepoint 0 (CELL_DEFAULT NUL) packs to content 0.
	vz := render.render_cell_pack_v2(0, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	cz, _, _, _, _ := render.render_cell_unpack_v2(vz)
	testing.expect_value(t, cz, u32(0))
}

@(test)
test_style_overflow_fallback :: proc(t: ^testing.T) {
	// StyleOverflow → mask to 10 bits at pack (2000 & 0x3FF == 464).
	v := render.render_cell_pack_v2(0x41, 2000, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, style, _, _, _ := render.render_cell_unpack_v2(v)
	testing.expect_value(t, style, u16(2000 & 0x3FF))

	// StyleIdStale → entry-0 fallback at expand (464 >= lut.count == 2).
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg, "stale style must keep bg")
	testing.expect(t, emit_glyph, "valid 'A' slot must emit glyph")
	er, eg, eb := instance.unpack_r5g6b5(lut.bg_r5g6b5[0])
	testing.expect(t, bg.r == er && bg.g == eg && bg.b == eb, "bg must use LUT entry 0")

	// Style 1023 (max valid) packs exactly.
	vmax := render.render_cell_pack_v2(0x41, 1023, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, smax, _, _, _ := render.render_cell_unpack_v2(vmax)
	testing.expect_value(t, smax, u16(1023))
}

@(test)
test_slot_overflow_unresolved :: proc(t: ^testing.T) {
	// SlotOverflow (>=512) → UNRESOLVED at pack.
	v := render.render_cell_pack_v2(0x41, 0, 1, 0, 700)
	_, _, _, _, slot := render.render_cell_unpack_v2(v)
	testing.expect_value(t, slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)

	// Expand resolves UNRESOLVED via atlas fallback → glyph emitted for valid 'A'.
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "atlas fallback must emit bg+glyph")

	// Invalid slot (valid bit clear) → skip glyph, keep bg.
	if a_idx, a_ok := render.atlas_pinned_slot_index(0x41); a_ok {
		atlas.slots[a_idx] = render.Atlas_Slot{valid = false}
	}
	emit_bg2, emit_glyph2, _, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg2 && !emit_glyph2, "invalid slot must skip glyph and keep bg")
}

@(test)
test_wide_continuation_pair :: proc(t: ^testing.T) {
	lead := render.render_cell_pack_v2(0x57, 1, 2, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	cont := render.render_cell_pack_v2(0, 1, 0, render.RENDER_CELL_V2_CFLAG_WIDE_CONT, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, lw, _, _ := render.render_cell_unpack_v2(lead)
	_, _, cw, ccf, _ := render.render_cell_unpack_v2(cont)
	testing.expect_value(t, lw, u8(2))
	testing.expect_value(t, cw, u8(0))
	testing.expect_value(t, ccf, render.RENDER_CELL_V2_CFLAG_WIDE_CONT)

	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	// Lead emits a double-width glyph.
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(lead, &lut, &atlas, 8, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "wide lead must emit bg+glyph")
	testing.expect(t, glyph.cw == 16.0, "wide lead glyph must span double width")

	// Continuation emits nothing.
	emit_bg2, emit_glyph2, _, _ := render.render_cell_expand_instance(cont, &lut, &atlas, 16, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_bg2 && !emit_glyph2, "continuation must emit nothing")
}

@(test)
test_continuation_orphan :: proc(t: ^testing.T) {
	// Orphan continuation packs width 0 and is written verbatim.
	v := render.render_cell_pack_v2(0x41, 1, 0, render.RENDER_CELL_V2_CFLAG_WIDE_CONT, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, w, _, _ := render.render_cell_unpack_v2(v)
	testing.expect_value(t, w, u8(0))

	// Expand emits nothing and never indexes col-1.
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_bg && !emit_glyph, "orphan continuation must emit nothing")
}

@(test)
test_empty_skip :: proc(t: ^testing.T) {
	lut := _test_lut() // entry 0 bg is black
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	// Space + black bg → 0 instances.
	space := render.render_cell_pack_v2(0x20, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb, eg, _, _ := render.render_cell_expand_instance(space, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !eb && !eg, "space+black must be skipped")

	// NUL + black bg → 0 instances.
	nul := render.render_cell_pack_v2(0, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb2, eg2, _, _ := render.render_cell_expand_instance(nul, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !eb2 && !eg2, "NUL+black must be skipped")

	// Printable with style 1 (blue bg) → bg+glyph.
	cell := render.render_cell_pack_v2(0x41, 1, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb3, eg3, _, _ := render.render_cell_expand_instance(cell, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, eb3 && eg3, "printable must emit bg+glyph")
}

@(test)
test_selected_cflag_overrides_lut_colors :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	selected := render.render_cell_pack_v2(
		0x41, 1, render.RENDER_CELL_V2_WIDTH_NARROW,
		render.RENDER_CELL_V2_CFLAG_SELECTED,
		render.RENDER_CELL_V2_SLOT_UNRESOLVED,
	)
	_, _, _, cflags, _ := render.render_cell_unpack_v2(selected)
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "selected cflag must round-trip")
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(selected, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "selected printable cell must emit both instances")
	br, bgc, bb := instance.unpack_r5g6b5(lut.selection_bg_r5g6b5)
	fr, fgc, fb := instance.unpack_r5g6b5(lut.selection_fg_r5g6b5)
	testing.expect(t, bg.r == br && bg.g == bgc && bg.b == bb, "selection bg must override style bg")
	testing.expect(t, glyph.r == fr && glyph.g == fgc && glyph.b == fb, "selection fg must override style fg")

	continuation := render.render_cell_pack_v2(
		0, 1, render.RENDER_CELL_V2_WIDTH_CONTINUATION,
		render.RENDER_CELL_V2_CFLAG_WIDE_CONT | render.RENDER_CELL_V2_CFLAG_SELECTED,
		render.RENDER_CELL_V2_SLOT_UNRESOLVED,
	)
	emit_bg, emit_glyph, _, _ = render.render_cell_expand_instance(continuation, &lut, &atlas, 8, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_bg && !emit_glyph, "selected continuation must preserve wide skip semantics")
}

@(test)
test_compiler_view_marks_selection :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, 'A')

	view := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			anchor = termgrid.Terminal_Point{row = 0, col = 0},
			focus = termgrid.Terminal_Point{row = 0, col = 0},
		},
	}
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)
	testing.expect(t, termgrid.terminal_view_selection_contains(&term, &view, termgrid.Terminal_Point{row = 0, col = 0}), "view selection must contain live cell")
	testing.expect_value(t, termgrid.terminal_view_document_row(&term, &view, 0), 0)
	direct := render.render_cell_from_semantic(termgrid.terminal_view_get_cell(&term, &view, 0, 0), true)
	_, _, _, direct_flags, _ := render.render_cell_unpack_v2(direct)
	testing.expect(t, direct_flags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "direct selected pack must mark the cell")
	render.render_compile_full_v2(&frame, &term, nil, nil, nil, nil, nil, &view)
	_, _, _, cflags, _ := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "view selection must mark the compiled cell")
}

@(test)
test_soa_aos_equivalence :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()

	// Same logical cell through both layouts.
	aos := render.render_cell_pack_v2(0x42, 9, 1, 0, 12)
	sf := u32(9) | (u32(1) << 10) | (u32(0) << 12) | (u32(12) << 19)
	soa := render.Render_Cells_SoA{
		codepoints   = []u32{0x42},
		styles_flags = []u32{sf},
	}
	rebuilt := render.render_cell_pack_v2(
		soa.codepoints[0],
		u16(soa.styles_flags[0] & 0x3FF),
		u8((soa.styles_flags[0] >> 10) & 0x3),
		u8((soa.styles_flags[0] >> 12) & 0x7F),
		u16((soa.styles_flags[0] >> 19) & 0x1FF),
	)
	testing.expect(t, aos == rebuilt, "SoA and AoS must produce identical triples")

	// Expansion must be byte-identical.
	bg_a, glyph_a: instance.Instance_Data
	bg_b, glyph_b: instance.Instance_Data
	eba, ega, _, _ := render.render_cell_expand_instance(aos, &lut, &atlas, 0, 0, 8, 16, &bg_a, &glyph_a)
	ebb, egb, _, _ := render.render_cell_expand_instance(rebuilt, &lut, &atlas, 0, 0, 8, 16, &bg_b, &glyph_b)
	testing.expect(t, eba == ebb && ega == egb, "emit flags must match")
	testing.expect(t, bg_a == bg_b, "bg instances must be byte-identical")
	testing.expect(t, glyph_a == glyph_b, "glyph instances must be byte-identical")
}

@(test)
test_lut_rebuild_parity :: proc(t: ^testing.T) {
	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	termgrid.style_table_insert(&table, termgrid.Style{fg = 0xFFFF0000, bg = 0xFF00FF00})
	termgrid.style_table_insert(&table, termgrid.Style{fg = 0xFF0000FF, bg = 0xFFFFFF00})

	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)

	testing.expect_value(t, lut.count, table.count)
	for i in 0..<int(table.count) {
		style := termgrid.style_table_get(&table, u16(i))
		testing.expect_value(t, lut.fg_r5g6b5[i], render.color_to_r5g6b5(style.fg))
		testing.expect_value(t, lut.bg_r5g6b5[i], render.color_to_r5g6b5(style.bg))
	}

	table.theme.selection_foreground = 0xFF123456
	table.theme.selection_background = 0xFF654321
	render.style_lut_rebuild(&lut, &table)
	testing.expect_value(t, lut.selection_fg_r5g6b5, render.color_to_r5g6b5(table.theme.selection_foreground))
	testing.expect_value(t, lut.selection_bg_r5g6b5, render.color_to_r5g6b5(table.theme.selection_background))
}

@(test)
test_emoji_cell_semantic_pack :: proc(t: ^testing.T) {
	sem := termgrid.Semantic_Cell{content = 0x1F680, width = 2, flags = .None}
	v := render.render_cell_from_semantic(sem)
	content, _, width, cflags, _ := render.render_cell_unpack_v2(v)
	testing.expect_value(t, content, u32(0x1F680))
	testing.expect_value(t, width, u8(2))
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_EMOJI != 0, "emoji flag must be set for 0x1F680")
}

@(test)
test_nerd_font_symbols_resolve :: proc(t: ^testing.T) {
	font_path := "assets/fonts/SymbolsNerdFontMono-Regular.ttf"
	rasterizer: render.Font_Rasterizer
	if !render.font_rasterizer_init(&rasterizer, font_path, 16.0) {
		// If running from a directory where assets/ is not local, skip gracefully
		return
	}
	defer render.font_rasterizer_destroy(&rasterizer)

	// Powerlevel10k commonly used Nerd Font glyphs:
	// 0xF179: Apple logo
	// 0xF07B: Folder
	// 0xF126: Git branch
	// 0xE0A0: Powerline branch symbol
	glyphs := [?]rune{0xF179, 0xF07B, 0xF126, 0xE0A0}
	for g in glyphs {
		glyph_idx := render.font_rasterizer_find_glyph_index(&rasterizer, u32(g))
		testing.expect(t, glyph_idx > 0, "Nerd Font symbol must exist in SymbolsNerdFontMono")
	}
}

@(test)
test_lut_sgr_inverse :: proc(t: ^testing.T) {
	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	termgrid.style_table_insert(&table, termgrid.Style{
		fg = 0xFFFF0000,
		bg = 0xFF0000FF,
		flags = termgrid.STYLE_FLAG_INVERSE,
	})

	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)

	testing.expect_value(t, lut.fg_r5g6b5[1], render.color_to_r5g6b5(0xFF0000FF))
	testing.expect_value(t, lut.bg_r5g6b5[1], render.color_to_r5g6b5(0xFFFF0000))
	testing.expect(t, lut.flags[1] & termgrid.STYLE_FLAG_INVERSE != 0, "inverse flag must be preserved in lut")
}

@(test)
test_lut_sgr_bold :: proc(t: ^testing.T) {
	brightened := render._style_lut_brighten_argb(0xFF646464)
	testing.expect_value(t, brightened, u32(0xFF828282))
	clamped := render._style_lut_brighten_argb(0xFFFFFFFF)
	testing.expect_value(t, clamped, u32(0xFFFFFFFF))

	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	termgrid.style_table_insert(&table, termgrid.Style{
		fg = 0xFF646464,
		bg = 0xFF000000,
		flags = termgrid.STYLE_FLAG_BOLD,
	})

	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)

	testing.expect_value(t, lut.fg_r5g6b5[1], render.color_to_r5g6b5(0xFF828282))
	testing.expect(t, lut.flags[1] & termgrid.STYLE_FLAG_BOLD != 0, "bold flag must be preserved in lut")
}

@(test)
test_lut_sgr_underline_color :: proc(t: ^testing.T) {
	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	termgrid.style_table_insert(&table, termgrid.Style{
		fg = 0xFFFF0000,
		bg = 0xFF000000,
		underline = 0,
		flags = termgrid.STYLE_FLAG_UNDERLINE,
	})
	termgrid.style_table_insert(&table, termgrid.Style{
		fg = 0xFFFF0000,
		bg = 0xFF000000,
		underline = 0xFF00FF00,
		flags = termgrid.STYLE_FLAG_UNDERLINE,
	})

	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)

	testing.expect_value(t, lut.ul_r5g6b5[1], render.color_to_r5g6b5(0xFFFF0000))
	testing.expect_value(t, lut.ul_r5g6b5[2], render.color_to_r5g6b5(0xFF00FF00))
	testing.expect(t, lut.flags[1] & termgrid.STYLE_FLAG_UNDERLINE != 0, "underline flag preserved in entry 1")
	testing.expect(t, lut.flags[2] & termgrid.STYLE_FLAG_UNDERLINE != 0, "underline flag preserved in entry 2")
}

@(test)
test_expand_instance_decor_underline_and_strike :: proc(t: ^testing.T) {
	lut := _test_lut()
	lut.flags[1] = termgrid.STYLE_FLAG_UNDERLINE
	lut.ul_r5g6b5[1] = render.color_to_r5g6b5(0xFF00FF00)

	atlas := _test_atlas()
	bg, glyph, decor: instance.Instance_Data

	cell1 := render.render_cell_pack_v2(0x41, 1, render.RENDER_CELL_V2_WIDTH_NARROW, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	emit_bg, emit_glyph, _, emit_decor := render.render_cell_expand_instance(
		cell1, &lut, &atlas, 10, 20, 8, 16,
		&bg, &glyph, nil, nil, nil, &decor,
	)
	testing.expect(t, emit_bg, "underline cell emits bg")
	testing.expect(t, emit_glyph, "underline cell emits glyph")
	testing.expect(t, emit_decor, "underline cell must emit decor")

	testing.expect_value(t, decor.x, f32(10))
	testing.expect_value(t, decor.y, f32(34))
	testing.expect_value(t, decor.cw, f32(8))
	testing.expect_value(t, decor.ch, f32(1))
	testing.expect_value(t, decor.u0, f32(0))
	testing.expect_value(t, decor.v0, f32(0))
	testing.expect_value(t, decor.u1, f32(0))
	testing.expect_value(t, decor.v1, f32(0))
	dr, dg, db := instance.unpack_r5g6b5(lut.ul_r5g6b5[1])
	testing.expect_value(t, decor.r, dr)
	testing.expect_value(t, decor.g, dg)
	testing.expect_value(t, decor.b, db)

	cell2 := render.render_cell_pack_v2(0x41, 1, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, _, emit_decor2 := render.render_cell_expand_instance(
		cell2, &lut, &atlas, 10, 20, 8, 16,
		&bg, &glyph, nil, nil, nil, &decor,
	)
	testing.expect(t, emit_decor2, "wide underline cell emits decor")
	testing.expect_value(t, decor.cw, f32(16))

	lut.flags[1] = termgrid.STYLE_FLAG_STRIKE
	lut.fg_r5g6b5[1] = render.color_to_r5g6b5(0xFFFF0000)
	cell3 := render.render_cell_pack_v2(0x41, 1, render.RENDER_CELL_V2_WIDTH_NARROW, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	_, _, _, emit_decor3 := render.render_cell_expand_instance(
		cell3, &lut, &atlas, 10, 20, 8, 16,
		&bg, &glyph, nil, nil, nil, &decor,
	)
	testing.expect(t, emit_decor3, "strike cell emits decor")
	testing.expect_value(t, decor.x, f32(10))
	testing.expect_value(t, decor.y, f32(28))
	testing.expect_value(t, decor.cw, f32(8))
	testing.expect_value(t, decor.ch, f32(1))
	sdr, sdg, sdb := instance.unpack_r5g6b5(lut.fg_r5g6b5[1])
	testing.expect_value(t, decor.r, sdr)
	testing.expect_value(t, decor.g, sdg)
	testing.expect_value(t, decor.b, sdb)
}

@(test)
test_render_cell_direct_color :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	dc := termgrid.Direct_Color_Channel{
		fg = 0xFFFF8020,
		bg = 0xFF104080,
	}

	cell := render.render_cell_pack_v2(0x41, 0, render.RENDER_CELL_V2_WIDTH_NARROW, render.RENDER_CELL_V2_CFLAG_DIRECT_COLOR, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	emit_bg, emit_glyph, _, _ := render.render_cell_expand_instance(
		cell, &lut, &atlas, 0, 0, 8, 16,
		&bg, &glyph, direct_color = &dc,
	)
	testing.expect(t, emit_bg, "direct color cell emits bg")
	testing.expect(t, emit_glyph, "direct color cell emits glyph")

	want_bg_r := f32(0x10) / 255.0
	want_bg_g := f32(0x40) / 255.0
	want_bg_b := f32(0x80) / 255.0
	testing.expect(t, abs(bg.r - want_bg_r) < 0.001, "bg.r must match direct ARGB")
	testing.expect(t, abs(bg.g - want_bg_g) < 0.001, "bg.g must match direct ARGB")
	testing.expect(t, abs(bg.b - want_bg_b) < 0.001, "bg.b must match direct ARGB")

	want_fg_r := f32(0xFF) / 255.0
	want_fg_g := f32(0x80) / 255.0
	want_fg_b := f32(0x20) / 255.0
	testing.expect(t, abs(glyph.r - want_fg_r) < 0.001, "glyph.r must match direct ARGB")
	testing.expect(t, abs(glyph.g - want_fg_g) < 0.001, "glyph.g must match direct ARGB")
	testing.expect(t, abs(glyph.b - want_fg_b) < 0.001, "glyph.b must match direct ARGB")
}

@(test)
test_prepare_pane_instances_v2_dimming :: proc(t: ^testing.T) {
	lut := _test_lut()
	r := new(render.Renderer)
	defer free(r)
	r.cell_width = 8.0
	r.cell_height = 16.0
	r.atlas = _test_atlas()
	max_inst: u32 = 128
	r.instances.max_instances = max_inst
	r.instances.instance_data = make([]instance.Instance_Data, int(max_inst))
	defer delete(r.instances.instance_data)

	// Two dummy terminals
	t1, t2: termgrid.Terminal
	defer termgrid.terminal_destroy(&t1)
	defer termgrid.terminal_destroy(&t2)
	termgrid.terminal_init(&t1, 2, 2)
	termgrid.terminal_init(&t2, 2, 2)

	style := termgrid.Style{fg = 0xFFFF0000, bg = 0xFF0000FF}
	_ = termgrid.style_table_insert(&t1.grid.style_table, style)
	_ = termgrid.style_table_insert(&t2.grid.style_table, style)

	// Set a character with style 1 (red fg, blue bg) in both terminals
	termgrid.grid_set_cell(&t1.grid, 0, 0, termgrid.Semantic_Cell{content = 'A', style = 1, width = 1})
	termgrid.grid_set_cell(&t2.grid, 0, 0, termgrid.Semantic_Cell{content = 'B', style = 1, width = 1})

	panes := []render.Pane_Viewport{
		{
			terminal   = &t1,
			x          = 0,
			y          = 28,
			w          = 400,
			h          = 300,
			rows       = 2,
			cols       = 2,
			dim_factor = 1.0,
			is_active  = true,
		},
		{
			terminal   = &t2,
			x          = 400,
			y          = 28,
			w          = 400,
			h          = 300,
			rows       = 2,
			cols       = 2,
			dim_factor = 0.75,
			is_active  = false,
		},
	}

	compiled_panes := make([]render.Compiled_Frame_V2, 2)
	defer {
		for &cf in compiled_panes do render.render_compiler_destroy_v2(&cf)
		delete(compiled_panes)
	}
	render.render_compiler_init_v2(&compiled_panes[0], 2, 2)
	render.render_compiler_init_v2(&compiled_panes[1], 2, 2)
	render.render_compile_full_v2(&compiled_panes[0], &t1)
	render.render_compile_full_v2(&compiled_panes[1], &t2)

	bg_count, glyph_count, _, _ := render._prepare_pane_instances_v2(r, &lut, panes, compiled_panes)
	testing.expect(t, bg_count >= 2, "must have at least 2 backgrounds")
	testing.expect(t, glyph_count >= 2, "must have at least 2 glyphs")

	// Pane 1 background: active (offset x=0, y=28, 100% color)
	bg1 := r.instances.instance_data[1]
	testing.expect_value(t, bg1.x, f32(0))
	testing.expect_value(t, bg1.y, f32(28))

	// Pane 2 background: inactive (offset x=400, y=28, 75% dimmed color)
	bg2 := r.instances.instance_data[3]
	testing.expect_value(t, bg2.x, f32(400))
	testing.expect_value(t, bg2.y, f32(28))
	testing.expect(t, abs(bg2.b - bg1.b * 0.75) < 0.01, "inactive bg.b must be dimmed to 75%")

	// Pane 1 glyph: active (offset x=0, y=28, 100% color)
	g1 := r.instances.instance_data[bg_count]
	testing.expect_value(t, g1.x, f32(0))
	testing.expect_value(t, g1.y, f32(28))

	// Pane 2 glyph: inactive (offset x=400, y=28, 75% dimmed color)
	g2 := r.instances.instance_data[bg_count + 1]
	testing.expect_value(t, g2.x, f32(400))
	testing.expect_value(t, g2.y, f32(28))
	testing.expect(t, abs(g2.r - g1.r * 0.75) < 0.01, "inactive glyph.r must be dimmed to 75%")
}

@(test)
test_pane_viewport_clipping :: proc(t: ^testing.T) {
	clip := [4]f32{10, 10, 100, 100}

	// 1. Instance completely inside
	inst_inside := instance.Instance_Data{x = 20, y = 20, cw = 10, ch = 20, u0 = 0.1, u1 = 0.9}
	ok := render._clip_instance_rect(&inst_inside, clip, true)
	testing.expect(t, ok, "inside quad must stay valid")
	testing.expect_value(t, inst_inside.cw, f32(10))
	testing.expect_value(t, inst_inside.ch, f32(20))

	// 2. Wide instance extending past right boundary (x = 95, cw = 20, boundary at 100)
	inst_right := instance.Instance_Data{x = 95, y = 20, cw = 20, ch = 20, u0 = 0.0, u1 = 1.0}
	ok = render._clip_instance_rect(&inst_right, clip, true)
	testing.expect(t, ok, "partially visible quad must stay valid")
	testing.expect_value(t, inst_right.cw, f32(5))
	testing.expect(t, abs(inst_right.u1 - 0.25) < 0.001, "u1 must be scaled to 5/20 = 0.25")

	// 3. Instance completely outside to the right (x = 105, cw = 20)
	inst_outside := instance.Instance_Data{x = 105, y = 20, cw = 20, ch = 20}
	ok = render._clip_instance_rect(&inst_outside, clip, false)
	testing.expect(t, !ok, "outside quad must be dropped")
}


@(test)
test_pane_style_ids_are_terminal_local :: proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	r.cell_width, r.cell_height = 8, 16
	r.atlas = _test_atlas()
	r.instances.max_instances = 16
	r.instances.instance_data = make([]instance.Instance_Data, 16)
	defer delete(r.instances.instance_data)
	terms := make([]termgrid.Terminal, 2)
	defer delete(terms)
	compiled := make([]render.Compiled_Frame_V2, 2)
	defer delete(compiled)
	defer {
		for i in 0 ..< len(terms) {
			render.render_compiler_destroy_v2(&compiled[i])
			termgrid.terminal_destroy(&terms[i])
		}
	}
	colors := [2]u32{0xFFFF0000, 0xFF00FF00}
	panes := make([]render.Pane_Viewport, 2)
	defer delete(panes)
	for i in 0 ..< len(terms) {
		termgrid.terminal_init(&terms[i], 1, 1)
		id := termgrid.style_table_insert(&terms[i].grid.style_table, termgrid.Style{fg = colors[i], bg = colors[i]})
		termgrid.grid_set_cell(&terms[i].grid, 0, 0, termgrid.Semantic_Cell{content = 'A', style = id, width = 1})
		render.render_compiler_init_v2(&compiled[i], 1, 1)
		render.render_compile_full_v2(&compiled[i], &terms[i])
		panes[i] = render.Pane_Viewport{terminal = &terms[i], x = f32(i)*8, w = 8, h = 16, rows = 1, cols = 1, dim_factor = 1}
	}
	lut: render.Style_LUT
	bg, glyph, _, _ := render._prepare_pane_instances_v2(r, &lut, panes, compiled)
	testing.expect_value(t, bg, u32(4))
	testing.expect_value(t, glyph, u32(2))
	testing.expect(t, r.instances.instance_data[1].r > 0.9 && r.instances.instance_data[3].g > 0.9, "same local style ID must retain independent backgrounds")
	testing.expect(t, r.instances.instance_data[bg].r > 0.9 && r.instances.instance_data[bg+1].g > 0.9, "same local style ID must retain independent glyph colors")
	panes[0].clip_rect = {4, 0, 8, 16}
	bg, glyph, _, _ = render._prepare_pane_instances_v2(r, &lut, panes, compiled)
	testing.expect_value(t, r.instances.instance_data[1].x, f32(4))
	testing.expect_value(t, r.instances.instance_data[1].cw, f32(4))
	testing.expect(t, abs(r.instances.instance_data[bg].u0 - 0.5) < 0.001, "pane clipping must crop glyph UVs")
	// Empty panes still publish independent theme backgrounds.
	for i in 0 ..< len(terms) {
		terms[i].grid.style_table.theme.background = colors[i]
		termgrid.grid_set_cell(&terms[i].grid, 0, 0, termgrid.Semantic_Cell{content = ' ', width = 1})
		render.render_compile_full_v2(&compiled[i], &terms[i])
	}
	bg, glyph, _, _ = render._prepare_pane_instances_v2(r, &lut, panes, compiled)
	testing.expect_value(t, bg, u32(2))
	testing.expect_value(t, glyph, u32(0))
	testing.expect(t, r.instances.instance_data[0].r > 0.9 && r.instances.instance_data[1].g > 0.9, "empty panes must retain their own theme background")
	panes[0].cols = 0
	panes[1].w = 0
	bg, glyph, _, _ = render._prepare_pane_instances_v2(r, &lut, panes, compiled)
	testing.expect_value(t, bg, u32(0))
	testing.expect_value(t, glyph, u32(0))
}

@(test)
test_pane_clip_left_top_and_invalid :: proc(t: ^testing.T) {
	quad := instance.Instance_Data{x = 0, y = 0, cw = 20, ch = 40, u0 = 0.2, u1 = 0.8, v0 = 0.1, v1 = 0.9}
	testing.expect(t, render._clip_instance_rect(&quad, {10, 20, 20, 40}, true))
	testing.expect(t, abs(quad.u0 - 0.5) < 0.001 && abs(quad.v0 - 0.5) < 0.001)
	testing.expect_value(t, quad.x, f32(10))
	testing.expect_value(t, quad.y, f32(20))
	testing.expect(t, !render._clip_instance_rect(&quad, {20, 20, 10, 40}, true))
	quad.cw = 0
	testing.expect(t, !render._clip_instance_rect(&quad, {0, 0, 40, 40}, true))
}

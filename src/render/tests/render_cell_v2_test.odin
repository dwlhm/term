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
	emit_bg, emit_glyph := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
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
	emit_bg, emit_glyph := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "atlas fallback must emit bg+glyph")

	// Invalid slot (valid bit clear) → skip glyph, keep bg.
	if a_idx, a_ok := render.atlas_pinned_slot_index(0x41); a_ok {
		atlas.slots[a_idx] = render.Atlas_Slot{valid = false}
	}
	emit_bg2, emit_glyph2 := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
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
	emit_bg, emit_glyph := render.render_cell_expand_instance(lead, &lut, &atlas, 8, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "wide lead must emit bg+glyph")
	testing.expect(t, glyph.cw == 16.0, "wide lead glyph must span double width")

	// Continuation emits nothing.
	emit_bg2, emit_glyph2 := render.render_cell_expand_instance(cont, &lut, &atlas, 16, 0, 8, 16, &bg, &glyph)
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
	emit_bg, emit_glyph := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !emit_bg && !emit_glyph, "orphan continuation must emit nothing")
}

@(test)
test_empty_skip :: proc(t: ^testing.T) {
	lut := _test_lut() // entry 0 bg is black
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	// Space + black bg → 0 instances.
	space := render.render_cell_pack_v2(0x20, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb, eg := render.render_cell_expand_instance(space, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !eb && !eg, "space+black must be skipped")

	// NUL + black bg → 0 instances.
	nul := render.render_cell_pack_v2(0, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb2, eg2 := render.render_cell_expand_instance(nul, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, !eb2 && !eg2, "NUL+black must be skipped")

	// Printable with style 1 (blue bg) → bg+glyph.
	cell := render.render_cell_pack_v2(0x41, 1, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb3, eg3 := render.render_cell_expand_instance(cell, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, eb3 && eg3, "printable must emit bg+glyph")
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
	eba, ega := render.render_cell_expand_instance(aos, &lut, &atlas, 0, 0, 8, 16, &bg_a, &glyph_a)
	ebb, egb := render.render_cell_expand_instance(rebuilt, &lut, &atlas, 0, 0, 8, 16, &bg_b, &glyph_b)
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
}

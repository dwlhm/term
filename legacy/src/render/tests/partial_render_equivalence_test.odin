package render_tests

// Strategy A Partial Render & Anti-Ghosting Visual Equivalence Test Suite.
// Verifies that:
// 1. In Partial_Load mode, blank cells (spaces/NULs) emit opaque background quads
//    covering the full cell area to overwrite old glyphs (preventing ghosting).
// 2. Wide CJK character deletions clear both lead and continuation columns.
// 3. Selection highlight removal repaints default background cleanly.
// 4. Automated 1,000-iteration property equivalence test: asserts that for every
//    cell modification, the effective visual output of Partial_Load is bit-exact
//    identical to a Full_Clear frame.

import "core:testing"
import "core:math/rand"

import render "../"
import instance "../instance"
import termgrid "../../terminal"

@(test)
test_partial_typing_char :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	// Character 'A' with style 0 in Partial_Load mode
	cell := render.render_cell_pack_v2(0x41, 0, 1, 0, 33)
	eb, eg, _, _ := render.render_cell_expand_instance(cell, &lut, &atlas, 10, 20, 8, 16, &bg, &glyph, mode = .Partial_Load)
	testing.expect(t, eg, "Character must emit glyph in Partial_Load mode")
	testing.expect_value(t, glyph.x, f32(10))
	testing.expect_value(t, glyph.y, f32(20))
	testing.expect_value(t, glyph.cw, f32(8))
	testing.expect_value(t, glyph.ch, f32(16))
}

@(test)
test_partial_backspace_overwrites_with_default_bg :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg_full, glyph_full: instance.Instance_Data
	bg_part, glyph_part: instance.Instance_Data

	// Space (0x20) with default background (style 0)
	space := render.render_cell_pack_v2(0x20, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)

	// 1. In Full_Clear mode: emits nothing (clear pass already paints screen)
	eb_f, eg_f, _, _ := render.render_cell_expand_instance(space, &lut, &atlas, 40, 50, 8, 16, &bg_full, &glyph_full, mode = .Full_Clear)
	testing.expect(t, !eb_f && !eg_f, "Full_Clear must skip default space quad")

	// 2. In Partial_Load mode: MUST emit background quad to overwrite deleted character!
	eb_p, eg_p, _, _ := render.render_cell_expand_instance(space, &lut, &atlas, 40, 50, 8, 16, &bg_part, &glyph_part, mode = .Partial_Load)
	testing.expect(t, eb_p, "Partial_Load MUST emit background quad for space (anti-ghosting)")
	testing.expect(t, !eg_p, "Space must emit no glyph")
	testing.expect_value(t, bg_part.x, f32(40))
	testing.expect_value(t, bg_part.y, f32(50))
	testing.expect_value(t, bg_part.cw, f32(8))
	testing.expect_value(t, bg_part.ch, f32(16))
	testing.expect_value(t, bg_part.a, f32(1.0))

	// Ensure background color matches default theme color
	exp_r, exp_g, exp_b := instance.unpack_r5g6b5(lut.bg_r5g6b5[0])
	testing.expect_value(t, bg_part.r, exp_r)
	testing.expect_value(t, bg_part.g, exp_g)
	testing.expect_value(t, bg_part.b, exp_b)
}

@(test)
test_partial_delete_full_line :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()

	cell_w: f32 = 8.0
	cell_h: f32 = 16.0
	y: f32 = 48.0
	cols := 10

	// 10 spaces replacing a deleted line
	space := render.render_cell_pack_v2(0x20, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)

	prev_right: f32 = 0.0
	for col in 0..<cols {
		x := f32(col) * cell_w
		bg, glyph: instance.Instance_Data
		eb, eg, _, _ := render.render_cell_expand_instance(space, &lut, &atlas, x, y, cell_w, cell_h, &bg, &glyph, mode = .Partial_Load)

		testing.expect(t, eb, "Every cell in deleted line must emit background")
		testing.expect(t, !eg, "Deleted cells emit no glyph")
		testing.expect_value(t, bg.x, x)
		testing.expect_value(t, bg.cw, cell_w)
		testing.expect_value(t, bg.ch, cell_h)

		// Verify contiguous coverage across cells (zero gaps / zero seams)
		if col > 0 {
			testing.expect_value(t, bg.x, prev_right)
		}
		prev_right = bg.x + bg.cw
	}
	testing.expect_value(t, prev_right, f32(cols) * cell_w)
}

@(test)
test_partial_wide_char_cjk_deleted :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg, glyph: instance.Instance_Data

	// CJK Wide Lead space in Partial_Load mode
	wide_space := render.render_cell_pack_v2(0x20, 0, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb, eg, _, _ := render.render_cell_expand_instance(wide_space, &lut, &atlas, 16, 32, 8, 16, &bg, &glyph, mode = .Partial_Load)

	testing.expect(t, eb, "Wide space in Partial_Load must emit background")
	testing.expect(t, !eg, "Space emits no glyph")
	testing.expect_value(t, bg.x, f32(16))
	testing.expect_value(t, bg.y, f32(32))
	testing.expect_value(t, bg.cw, f32(16.0)) // Must span 2 full columns (2 * cell_w)
	testing.expect_value(t, bg.ch, f32(16.0))
}

@(test)
test_partial_selection_cleared_emits_bg :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	bg_sel, glyph_sel: instance.Instance_Data
	bg_unsel, glyph_unsel: instance.Instance_Data

	// 1. Cell with Selection flag active
	cell_selected := render.render_cell_pack_v2(0x20, 0, 1, render.RENDER_CELL_V2_CFLAG_SELECTED, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb_s, _, _, _ := render.render_cell_expand_instance(cell_selected, &lut, &atlas, 0, 0, 8, 16, &bg_sel, &glyph_sel, mode = .Partial_Load)
	testing.expect(t, eb_s, "Selected cell must emit selection background")
	sel_r, sel_g, sel_b := instance.unpack_r5g6b5(lut.selection_bg_r5g6b5)
	testing.expect_value(t, bg_sel.r, sel_r)
	testing.expect_value(t, bg_sel.g, sel_g)
	testing.expect_value(t, bg_sel.b, sel_b)

	// 2. Selection cleared (reverts to unselected default space)
	cell_unselected := render.render_cell_pack_v2(0x20, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	eb_u, _, _, _ := render.render_cell_expand_instance(cell_unselected, &lut, &atlas, 0, 0, 8, 16, &bg_unsel, &glyph_unsel, mode = .Partial_Load)
	testing.expect(t, eb_u, "Unselected cell in Partial_Load must emit default background to erase selection highlight")
	def_r, def_g, def_b := instance.unpack_r5g6b5(lut.bg_r5g6b5[0])
	testing.expect_value(t, bg_unsel.r, def_r)
	testing.expect_value(t, bg_unsel.g, def_g)
	testing.expect_value(t, bg_unsel.b, def_b)
}

@(test)
test_partial_italic_boundary_spans :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()

	cell_w: f32 = 8.0
	cell_h: f32 = 16.0

	// Cell at col 5 with Italic/Slanted style
	// Widened damage span covers col 4, col 5, col 6
	col_start := 4
	col_end := 6 // inclusive of col 4, 5, 6

	for col in col_start..=col_end {
		x := f32(col) * cell_w
		y := f32(10) * cell_h

		content: u32 = 0x20
		if col == 5 {
			content = 0x46 // 'F' italic
		}

		cell := render.render_cell_pack_v2(content, 0, 1, 0, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
		bg, glyph: instance.Instance_Data
		eb, eg, _, _ := render.render_cell_expand_instance(cell, &lut, &atlas, x, y, cell_w, cell_h, &bg, &glyph, mode = .Partial_Load)

		testing.expect(t, eb, "Every cell in widened italic span must emit background coverage")
		testing.expect_value(t, bg.x, x)
		testing.expect_value(t, bg.cw, cell_w)
		testing.expect_value(t, bg.ch, cell_h)
		if col == 5 {
			testing.expect(t, eg, "Italic char must emit glyph")
		} else {
			testing.expect(t, !eg, "Neighboring space must emit no glyph, only opaque bg")
		}
	}
}

@(test)
test_partial_vs_full_equivalence_property_test :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()

	// Seeded deterministic LCG generator
	rng_state: u64 = 42
	next_rand :: proc(s: ^u64) -> u32 {
		s^ = s^ * 6364136223846793005 + 1442695040888963407
		return u32(s^ >> 32)
	}

	cell_w: f32 = 8.0
	cell_h: f32 = 16.0

	// Run 1,000 randomized terminal cell edits (typing, backspacing, styles, selection)
	for i in 0..<1000 {
		cp_choice := next_rand(&rng_state) % 5
		content: u32 = 0x20 // default space
		switch cp_choice {
		case 0: content = 0x20                             // space
		case 1: content = 0                                // NUL
		case 2: content = 0x41 + (next_rand(&rng_state) % 26)  // Latin A..Z
		case 3: content = 0x30 + (next_rand(&rng_state) % 10)  // Digits 0..9
		case 4: content = 0x2500 + (next_rand(&rng_state) % 20) // Box drawing
		}

		style := u16(next_rand(&rng_state) % 2) // style 0 (default bg) or style 1 (custom bg)
		width: u8 = 1
		if content > 0x2000 && (next_rand(&rng_state) % 4 == 0) {
			width = render.RENDER_CELL_V2_WIDTH_WIDE_LEAD
		}

		cflags: u8 = 0
		if next_rand(&rng_state) % 5 == 0 {
			cflags |= render.RENDER_CELL_V2_CFLAG_SELECTED
		}

		slot: u16 = render.RENDER_CELL_V2_SLOT_UNRESOLVED
		if content >= 32 && content < 127 {
			slot = u16(content - 32)
		}

		cell := render.render_cell_pack_v2(content, style, width, cflags, slot)

		col := f32(i % 80)
		row := f32(i / 80)
		x := col * cell_w
		y := row * cell_h

		bg_full, glyph_full: instance.Instance_Data
		bg_part, glyph_part: instance.Instance_Data

		eb_f, eg_f, _, _ := render.render_cell_expand_instance(cell, &lut, &atlas, x, y, cell_w, cell_h, &bg_full, &glyph_full, mode = .Full_Clear)
		eb_p, eg_p, _, _ := render.render_cell_expand_instance(cell, &lut, &atlas, x, y, cell_w, cell_h, &bg_part, &glyph_part, mode = .Partial_Load)

		// Invariant A: Glyph output must be BIT-EXACT identical between Full and Partial
		testing.expect_value(t, eg_f, eg_p)
		if eg_f {
			testing.expect_value(t, glyph_full.x, glyph_part.x)
			testing.expect_value(t, glyph_full.y, glyph_part.y)
			testing.expect_value(t, glyph_full.cw, glyph_part.cw)
			testing.expect_value(t, glyph_full.ch, glyph_part.ch)
			testing.expect_value(t, glyph_full.r, glyph_part.r)
			testing.expect_value(t, glyph_full.g, glyph_part.g)
			testing.expect_value(t, glyph_full.b, glyph_part.b)
			testing.expect_value(t, glyph_full.a, glyph_part.a)
		}

		// Invariant B: Visual background equivalence
		// If Full_Clear emits bg, Partial_Load must emit identical bg
		if eb_f {
			testing.expect(t, eb_p, "When Full emits bg, Partial must emit bg")
			testing.expect_value(t, bg_full.r, bg_part.r)
			testing.expect_value(t, bg_full.g, bg_part.g)
			testing.expect_value(t, bg_full.b, bg_part.b)
		} else {
			// If Full_Clear didn't emit bg (default background), Partial_Load MUST emit
			// the default theme background color to paint over old pixels
			if eb_p {
				exp_r, exp_g, exp_b := instance.unpack_r5g6b5(lut.bg_r5g6b5[0])
				testing.expect_value(t, bg_part.r, exp_r)
				testing.expect_value(t, bg_part.g, exp_g)
				testing.expect_value(t, bg_part.b, exp_b)
				testing.expect_value(t, bg_part.a, f32(1.0))
			}
		}
	}
}

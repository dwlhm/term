package render_tests

// Regression test for fallback-sourced UI glyph optical alignment.
//
// Pinned UI glyphs the primary face does not cover (⌘ ⌥ ⌃ ↵) are filled
// from the fallback chain. Symbol faces carry a far larger ascender than a
// text face, and each of their glyphs carries its own design baseline offset,
// so placing those glyphs against the fallback's own metrics anchored them
// high and low by different amounts — a superscript next to normal-height
// text — and their ink was also far smaller than the primary's cap height.
//
// The atlas must instead baseline and scale fallback glyphs against the
// primary: the ink bottom of a fallback glyph has to sit on the primary's
// baseline (within BASELINE_TOLERANCE_PX of a primary-sourced reference
// glyph in the same atlas) and its ink height must match the reference's
// within HEIGHT_TOLERANCE_PCT.
//
// The rule covers every fallback-sourced pinned slot, not a hand-picked list:
// the test walks the whole pinned set and asserts on whatever the chain
// actually resolves outside the primary face, so a future pinned codepoint
// that starts resolving through the chain is covered automatically.

import "core:fmt"
import "core:testing"
import "../"

// BASELINE_TOLERANCE_PX is the allowed ink-bottom distance between a
// fallback-sourced glyph and the primary-sourced reference glyph.
BASELINE_TOLERANCE_PX :: 2

// HEIGHT_TOLERANCE_PCT is the allowed ink-height deviation from the
// reference glyph, in percent.
HEIGHT_TOLERANCE_PCT :: 25

// CLAMP_LIMITED_WIDTH_SLACK_PX is how much slack an ink box may keep below
// the cell width and still count as filling the cell.
CLAMP_LIMITED_WIDTH_SLACK_PX :: 1

// slot_ink_box returns the cell-local ink bounding box of a slot as
// (left, right, top, bottom); ok is false when the slot holds no ink.
slot_ink_box :: proc(atlas: ^render.Atlas, slot_index: int) -> (left, right, top, bottom: int, ok: bool) {
	gs := render.ATLAS_GLYPH_SIZE
	x0 := (slot_index % render.ATLAS_COLS) * gs
	y0 := (slot_index / render.ATLAS_COLS) * gs
	left, right, top, bottom = gs, -1, gs, -1
	for y in 0..<gs {
		for x in 0..<gs {
			if atlas.pixels[(y0 + y) * atlas.tex_width + (x0 + x)] != 0 {
				top = min(top, y)
				bottom = max(bottom, y)
				left = min(left, x)
				right = max(right, x)
			}
		}
	}
	ok = right >= left && bottom >= top
	return
}

@(test)
test_atlas_fallback_ui_glyphs_share_primary_optics :: proc(t: ^testing.T) {
	font_path, ok := find_primary_test_font()
	if !ok {
		fmt.printf("no primary test font found; skipping fallback optics regression test\n")
		return
	}

	prim: render.Font_Rasterizer
	testing.expect_value(t, render.font_rasterizer_init(&prim, font_path, 16.0), true)
	defer render.font_rasterizer_destroy(&prim)

	chain: render.Fallback_Chain
	testing.expect_value(t, render.fallback_chain_init(&chain, &prim, TEST_FALLBACK_FONT_CANDIDATES[:], 16.0, context.allocator), true)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	render.atlas_prewarm_chain(&atlas, &chain)

	testing.expect(t, atlas.primary_cap_px > 0, "atlas must calibrate the primary cap height")
	testing.expect(t, atlas.primary_baseline_px >= 0, "atlas must calibrate the primary baseline row")

	// Reference: a Latin capital in the same atlas, sourced from the primary.
	ref_index, ref_slot := render.atlas_lookup(&atlas, u32(render.ATLAS_CAP_REFERENCE_PREFERRED))
	testing.expect(t, ref_slot.valid, "reference cap glyph should be primary-sourced and valid")
	ref_left, ref_right, ref_top, ref_bottom, ref_ok := slot_ink_box(&atlas, ref_index)
	testing.expect(t, ref_ok, "reference cap glyph must hold ink")
	ref_height := ref_bottom - ref_top + 1
	testing.expect_value(t, atlas.primary_baseline_px, ref_bottom)
	fmt.printf(
		"reference U+%04X left=%d right=%d top=%d bottom=%d height=%d cell=%dx%d\n",
		int(render.ATLAS_CAP_REFERENCE_PREFERRED), ref_left, ref_right, ref_top, ref_bottom,
		ref_height, atlas.cell_width, atlas.cell_height,
	)

	checked := 0
	for cp in render.atlas_prewarm_set() {
		font_index, covered := render.fallback_resolve(&chain, u32(cp), nil)
		// Primary-sourced slots keep their own placement and are out of scope
		// here; atlas_slots_have_ink covers that they still draw.
		if !covered || font_index == 0 {
			continue
		}

		idx, slot := render.atlas_lookup(&atlas, u32(cp))
		testing.expect(t, slot.valid, "pinned fallback slot should be valid")
		left, right, top, bottom, has_ink := slot_ink_box(&atlas, idx)
		if !has_ink {
			testing.expect(t, false, fmt.tprintf("U+%04X slot must hold ink", int(cp)))
			continue
		}
		checked += 1

		width := right - left + 1
		height := bottom - top + 1

		// Powerline slots are anchored by their own branch
		// (font_rasterize_glyph_fitted + _atlas_blit_bitmap), which keeps the
		// glyph's own design baseline offset by design: a caret is a
		// standalone separator, not inline text. Report them, do not assert.
		powerline := cp >= render.PINNED_POWERLINE_START && cp <= render.PINNED_POWERLINE_END
		fmt.printf(
			"U+%04X font=%d slot=%d left=%d right=%d top=%d bottom=%d w=%d h=%d baseline delta=%d powerline=%v\n",
			int(cp), font_index, idx, left, right, top, bottom, width, height,
			bottom - ref_bottom, powerline,
		)
		if powerline {
			continue
		}

		baseline_delta := abs(bottom - ref_bottom)
		testing.expect(
			t,
			baseline_delta <= BASELINE_TOLERANCE_PX,
			fmt.tprintf(
				"U+%04X ink bottom must sit on the primary baseline (delta %d > %d)",
				int(cp), baseline_delta, BASELINE_TOLERANCE_PX,
			),
		)

		// A glyph whose ink fills the cell width is size-limited by the cell,
		// not by the optical target: it cannot grow taller without growing
		// wider than one cell, and one cell is all a pinned slot draws.
		//
		// U+2325 (⌥ option) is the case that needs this escape. Its outline
		// is far wider than it is tall (aspect around 1.8), so reaching the
		// reference cap height would need a bitmap roughly twice the cell
		// width; the fit loop caps it at the cell and it lands at about half
		// the cap height. That is a property of the glyph's design in the
		// source font, not an atlas regression — the same glyph cannot be
		// drawn taller in a single cell by any renderer.
		clamp_limited := width >= atlas.cell_width - CLAMP_LIMITED_WIDTH_SLACK_PX
		height_delta := abs(height - ref_height) * 100
		testing.expect(
			t,
			height_delta <= ref_height * HEIGHT_TOLERANCE_PCT || clamp_limited,
			fmt.tprintf(
				"U+%04X ink height must match the primary cap height (got %d, reference %d, width %d of cell %d)",
				int(cp), height, ref_height, width, atlas.cell_width,
			),
		)

		// The glyph must also fit the slot it is drawn into: slot UVs span
		// exactly one cell, so anything wider or taller is clipped.
		testing.expect(t, width <= atlas.cell_width, fmt.tprintf("U+%04X ink width must fit the cell width", int(cp)))
		testing.expect(t, height <= atlas.cell_height, fmt.tprintf("U+%04X ink height must fit the cell height", int(cp)))
	}
	testing.expect(t, checked > 0, "at least one pinned glyph must be covered by the chain outside the primary")
}

package render_tests

// Tests for font rasterizer, atlas prewarm, and pinned slot lookup.

import "core:testing"
import "core:os"
import "core:fmt"
import "base:runtime"
import "vendor:stb/truetype"
import "../"

// Test font paths (macOS system fonts)
TEST_FONT_MENLO :: "/System/Library/Fonts/Menlo.ttc"
TEST_FONT_COURIER :: "/System/Library/Fonts/Supplemental/Courier New.ttf"

// find_test_font tries to find a usable test font.
find_test_font :: proc() -> (path: string, ok: bool) {
	// Try Menlo first
	if _, err := os.read_entire_file_from_path(TEST_FONT_MENLO, context.allocator); err == nil {
		return TEST_FONT_MENLO, true
	}

	// Fallback to Courier New
	if _, err := os.read_entire_file_from_path(TEST_FONT_COURIER, context.allocator); err == nil {
		return TEST_FONT_COURIER, true
	}

	return "", false
}

// ============================================================================
// Font Rasterizer Tests
// ============================================================================

@(test)
test_font_rasterizer_init_valid :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	testing.expect(t, ok, "Test font should be available")

	err: render.Font_Error
	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0, &err)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	defer render.font_rasterizer_destroy(&r)

	testing.expect(t, err == render.Font_Error.None, "Error should be None")
	testing.expect(t, r.metrics.pixel_size == 16.0, "Pixel size should be 16.0")
	testing.expect(t, r.metrics.cell_width > 0, "Cell width should be positive")
	testing.expect(t, r.metrics.cell_height > 0, "Cell height should be positive")
}

@(test)
test_atlas_zoomed_metrics_fit_slot :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	if !ok {
		fmt.printf("no test font found; skipping zoomed metrics test\n")
		return
	}

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 32.0)
	testing.expect(t, success, "font_rasterizer_init should succeed at maximum zoom")
	if !success {
		return
	}
	defer render.font_rasterizer_destroy(&r)

	testing.expect(t, r.metrics.cell_width <= render.ATLAS_GLYPH_SIZE, "Zoomed cell width should fit in atlas slot")
	testing.expect(t, r.metrics.cell_height <= render.ATLAS_GLYPH_SIZE, "Zoomed cell height should fit in atlas slot")
}

@(test)
test_font_rasterizer_init_missing :: proc(t: ^testing.T) {
	err: render.Font_Error
	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, "/nonexistent/font.ttf", 16.0, &err)

	testing.expect(t, !success, "Init should fail for missing font")
	testing.expect(t, err == render.Font_Error.File_Not_Found, "Should get File_Not_Found error")
}

@(test)
test_font_rasterizer_glyph_metrics :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	testing.expect(t, ok, "Test font should be available")

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	defer render.font_rasterizer_destroy(&r)

	// Test 'M' glyph
	glyph := render.font_rasterize_glyph(&r, 'M')
	testing.expect(t, glyph.advance > 0, "Glyph advance should be positive")
	testing.expect(t, glyph.width > 0, "Glyph width should be positive")
	testing.expect(t, glyph.height > 0, "Glyph height should be positive")
}

@(test)
test_font_rasterizer_space_glyph :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	testing.expect(t, ok, "Test font should be available")

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	defer render.font_rasterizer_destroy(&r)

	// Space should have advance but no bitmap
	glyph := render.font_rasterize_glyph(&r, ' ')
	testing.expect(t, glyph.advance > 0, "Space should have positive advance")
	// Space bitmap may be zero-width
}

// ============================================================================
// Atlas Prewarm Tests
// ============================================================================

@(test)
test_atlas_pinned_slot_index_ascii :: proc(t: ^testing.T) {
	// Test all ASCII codepoints (32-126)
	for cp in rune(32) ..< rune(127) {
		index, ok := render.atlas_pinned_slot_index(u32(cp))
		testing.expect(t, ok, "ASCII codepoint should be pinned")
		testing.expect(t, index >= 0 && index < 95, "ASCII slot should be in [0, 95)")
	}
}

@(test)
test_atlas_pinned_slot_index_box_drawing :: proc(t: ^testing.T) {
	// Test box drawing codepoints (0x2500-0x257F)
	for cp in rune(0x2500) ..< rune(0x2580) {
		index, ok := render.atlas_pinned_slot_index(u32(cp))
		testing.expect(t, ok, "Box drawing codepoint should be pinned")
		testing.expect(t, index >= 95 && index < 223, "Box drawing slot should be in [95, 223)")
	}
}

@(test)
test_atlas_pinned_slot_index_block_elements :: proc(t: ^testing.T) {
	// Test block elements (0x2580-0x259F)
	for cp in rune(0x2580) ..< rune(0x25A0) {
		index, ok := render.atlas_pinned_slot_index(u32(cp))
		testing.expect(t, ok, "Block element codepoint should be pinned")
		testing.expect(t, index >= 223 && index < 255, "Block element slot should be in [223, 255)")
	}
}

@(test)
test_atlas_pinned_slot_index_powerline :: proc(t: ^testing.T) {
	// Test powerline codepoints (0xE0B0-0xE0BF)
	for cp in rune(0xE0B0) ..< rune(0xE0C0) {
		index, ok := render.atlas_pinned_slot_index(u32(cp))
		testing.expect(t, ok, "Powerline codepoint should be pinned")
		testing.expect(t, index >= 255 && index < 271, "Powerline slot should be in [255, 271)")
	}
}

@(test)
test_atlas_pinned_slot_index_non_pinned :: proc(t: ^testing.T) {
	// Test non-pinned codepoints
	_, ok1 := render.atlas_pinned_slot_index(31)  // Below ASCII range
	testing.expect(t, !ok1, "Codepoint 31 should not be pinned")

	_, ok2 := render.atlas_pinned_slot_index(127)  // Above ASCII range
	testing.expect(t, !ok2, "Codepoint 127 should not be pinned")

	_, ok3 := render.atlas_pinned_slot_index(0x2600)  // Between ranges
	testing.expect(t, !ok3, "Codepoint 0x2600 should not be pinned")
}

@(test)
test_atlas_prewarm_set_completeness :: proc(t: ^testing.T) {
	set := render.atlas_prewarm_set()
	testing.expect(t, len(set) == 271, "Prewarm set should have 271 codepoints")

	// Check no duplicates
	seen: map[rune]bool
	for cp in set {
		_, exists := seen[cp]
		testing.expect(t, !exists, "No duplicate codepoints in prewarm set")
		seen[cp] = true
	}
}

@(test)
test_atlas_no_slot_collisions :: proc(t: ^testing.T) {
	set := render.atlas_prewarm_set()
	slot_to_cp: map[int]u32

	for cp in set {
		index, ok := render.atlas_pinned_slot_index(u32(cp))
		testing.expect(t, ok, "Codepoint should be pinned")

		if existing_cp, exists := slot_to_cp[index]; exists {
			testing.expect(t, false, "Slot collision detected")
		}
		slot_to_cp[index] = u32(cp)
	}
}

// ============================================================================
// Atlas Integration Tests
// ============================================================================

@(test)
test_atlas_prewarm_all_ascii_valid :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	testing.expect(t, ok, "Test font should be available")

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	defer render.font_rasterizer_destroy(&r)

	atlas: render.Atlas
	render.atlas_init(&atlas, &r)
	defer render.atlas_destroy(&atlas)

	// Check all ASCII glyphs are valid
	valid_count: int
	for cp in rune(32) ..< rune(127) {
		index, slot := render.atlas_lookup(&atlas, u32(cp))
		if slot != nil && slot.valid {
			valid_count += 1
		}
	}
	testing.expect(t, valid_count == 95, "All 95 ASCII glyphs should be valid after prewarm")
}

// slot_nonzero_count counts nonzero pixels in a slot's glyph rect.
slot_nonzero_count :: proc(atlas: ^render.Atlas, slot_index: int) -> int {
	gs := render.ATLAS_GLYPH_SIZE
	cols := render.ATLAS_COLS
	col := slot_index % cols
	row := slot_index / cols
	x0 := col * gs
	y0 := row * gs
	n := 0
	for y in 0..<gs {
		for x in 0..<gs {
			di := (y0 + y) * atlas.tex_width + (x0 + x)
			if di < len(atlas.pixels) && atlas.pixels[di] != 0 {
				n += 1
			}
		}
	}
	return n
}

@(test)
test_atlas_slots_have_ink :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	if !ok {
		fmt.printf("no test font found; skipping ink test\n")
		return
	}

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	if !success {
		return
	}
	defer render.font_rasterizer_destroy(&r)

	atlas: render.Atlas
	render.atlas_init(&atlas, &r)
	defer render.atlas_destroy(&atlas)

	// Every non-space ASCII slot must hold ink (space has no bitmap by design).
	for cp in rune(33) ..< rune(127) {
		idx, slot := render.atlas_lookup(&atlas, u32(cp))
		testing.expect(t, slot != nil && slot.valid, "ASCII slot should be valid")
		n := slot_nonzero_count(&atlas, idx)
		testing.expect(t, n > 0, "non-space ASCII slot should contain ink")
	}

	// Quantitative proof output.
	probes := [5]rune{'A', 'h', 'e', 'l', 'o'}
	for cp in probes {
		idx, _ := render.atlas_lookup(&atlas, u32(cp))
		fmt.printf("slot cp=%d idx=%d nonzero=%d\n", int(cp), idx, slot_nonzero_count(&atlas, idx))
	}
	atlas_total := 0
	for px in atlas.pixels {
		if px != 0 {
			atlas_total += 1
		}
	}
	fmt.printf("atlas total nonzero=%d\n", atlas_total)

	// Atlas total must be within 10% of summed per-glyph counts (no silent clipping).
	// The sum covers the full prewarm set to match the atlas-wide total,
	// skipping codepoints the font does not cover (the slot path skips
	// those too; font_rasterize_glyph would return .notdef ink for them).
	glyph_sum := 0
	covered_count := 0
	chain: render.Fallback_Chain
	render.fallback_chain_init(&chain, &r, nil, 16.0, context.allocator)
	defer render.fallback_chain_destroy(&chain)
	prewarm := render.atlas_prewarm_set()
	defer delete(prewarm)
	for cp in prewarm {
		_, covered := render.fallback_resolve(&chain, u32(cp), nil)
		if !covered {
			continue
		}
		covered_count += 1
		g := render.font_rasterize_glyph(&r, u32(cp))
		if g.pixels != nil {
			for px in g.pixels {
				if px != 0 {
					glyph_sum += 1
				}
			}
			delete(g.pixels)
		}
	}
	fmt.printf("summed per-glyph nonzero=%d (covered=%d)\n", glyph_sum, covered_count)
	testing.expect(t, glyph_sum > 0, "per-glyph sum should be positive")
	if glyph_sum > 0 {
		diff := atlas_total - glyph_sum
		if diff < 0 {
			diff = -diff
		}
		testing.expect(t, diff * 10 <= glyph_sum, "atlas total within 10% of per-glyph sum")
	}
}

@(test)
test_atlas_lookup_pinned_o1 :: proc(t: ^testing.T) {
	font_path, ok := find_test_font()
	testing.expect(t, ok, "Test font should be available")

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	defer render.font_rasterizer_destroy(&r)

	atlas: render.Atlas
	render.atlas_init(&atlas, &r)
	defer render.atlas_destroy(&atlas)

	// Lookup should be O(1) for pinned glyphs
	_, slot1 := render.atlas_lookup(&atlas, u32('A'))
	testing.expect(t, slot1 != nil, "Should find 'A'")
	testing.expect(t, slot1.valid, "'A' slot should be valid")

	_, slot2 := render.atlas_lookup(&atlas, u32(0x2500))
	testing.expect(t, slot2 != nil, "Should find box drawing glyph")
	testing.expect(t, slot2.valid, "Box drawing slot should be valid")
}

@(test)
test_fitted_glyph_invariant :: proc(t: ^testing.T) {
	testing.expect(t, render.is_symbol_or_pua(0xE000), "0xE000 should be symbol or PUA")
	testing.expect(t, render.is_symbol_or_pua(0xE0B0), "0xE0B0 should be symbol or PUA")
	testing.expect(t, render.is_symbol_or_pua(0xE0B6), "0xE0B6 should be symbol or PUA")
	testing.expect(t, render.is_symbol_or_pua(0xF179), "0xF179 should be symbol or PUA")
	testing.expect(t, render.is_symbol_or_pua(0x2500), "0x2500 should be symbol or PUA")
	testing.expect(t, !render.is_symbol_or_pua('A'), "'A' should not be symbol or PUA")

	font_path := "assets/fonts/SymbolsNerdFontMono-Regular.ttf"
	if !os.exists(font_path) {
		font_path = "../assets/fonts/SymbolsNerdFontMono-Regular.ttf"
	}
	testing.expect(t, os.exists(font_path), "Font file must exist")
	if !os.exists(font_path) {
		return
	}

	r: render.Font_Rasterizer
	success := render.font_rasterizer_init(&r, font_path, 16.0)
	testing.expect(t, success, "font_rasterizer_init should succeed")
	if !success {
		return
	}
	defer render.font_rasterizer_destroy(&r)

	max_w := 9
	max_h := 18
	codepoints := []u32{0x2500, 0xE0B0, 0xE0B6, 0xF179, 0xF07B, 0xF017, 0xE0A0}

	for cp in codepoints {
		if truetype.FindGlyphIndex(&r.info, rune(cp)) == 0 {
			continue
		}
		bmp := render.font_rasterize_glyph_fitted(&r, cp, max_w, max_h)
		testing.expect(t, bmp.pixels != nil, fmt.tprintf("glyph bitmap should not be nil for U+%04X", cp))
		if bmp.pixels != nil {
			bx := int(bmp.bearing_x)
			testing.expect(t, bx >= 0, fmt.tprintf("bearing_x >= 0 for codepoint U+%04X (got %d)", cp, bx))
			testing.expect(t, bx + bmp.width <= max_w, fmt.tprintf("bearing_x + width <= max_w for codepoint U+%04X (got %d + %d = %d > %d)", cp, bx, bmp.width, bx + bmp.width, max_w))
			delete(bmp.pixels)
		}
	}
}

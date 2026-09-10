package render_tests

// Tests for font rasterizer, atlas prewarm, and pinned slot lookup.

import "core:testing"
import "core:os"
import "core:fmt"
import "base:runtime"
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

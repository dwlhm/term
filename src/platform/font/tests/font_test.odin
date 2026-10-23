package platform_font_tests

import "core:os"
import "core:testing"
import font "../"

@test
test_resolve_font_path :: proc(t: ^testing.T) {
	resolved, ok := font.resolve_font_path("assets/fonts/MapleMono-NF-Regular.ttf", context.temp_allocator)
	testing.expect(t, ok, "assets/fonts/MapleMono-NF-Regular.ttf should resolve")
	testing.expect(t, os.is_file(resolved), "resolved font path must exist on disk")

	fallback_res, fok := font.resolve_font_path("assets/fonts/SymbolsNerdFontMono-Regular.ttf", context.temp_allocator)
	testing.expect(t, fok, "assets/fonts/SymbolsNerdFontMono-Regular.ttf should resolve")
	testing.expect(t, os.is_file(fallback_res), "resolved symbols font must exist on disk")

	_, nok := font.resolve_font_path("assets/fonts/NonExistentFont-xyz.ttf", context.temp_allocator)
	testing.expect(t, !nok, "non-existent font must return false")
}

@test
test_font_context_lifecycle :: proc(t: ^testing.T) {
	fc: font.Font_Context
	ok := font.font_context_init(&fc, 24.0)
	testing.expect(t, ok, "font_context_init should succeed with bundled/system fonts")
	testing.expect(t, fc.has_font, "font_context must have primary font")
	testing.expect(t, len(fc.active_path) > 0, "active_path must be populated")
	defer font.font_context_destroy(&fc)

	// Verify primary font has standard ASCII codepoints
	testing.expect(t, font.font_has_codepoint(&fc, 'A'), "font must have ASCII 'A'")
	testing.expect(t, font.font_has_codepoint(&fc, 'z'), "font must have ASCII 'z'")
}

@test
test_os_font_discovery_and_cascade :: proc(t: ^testing.T) {
	// 1. Operating system fixed-pitch font
	fixed_path, ok := font.platform_query_os_fixed_pitch_font(context.temp_allocator)
	testing.expect(t, ok, "platform_query_os_fixed_pitch_font must resolve on this OS")
	testing.expect(t, os.is_file(fixed_path), "resolved OS fixed pitch font must exist on disk")

	// 2. Operating system cascade list
	cascades := font.platform_query_os_cascade_fonts(12, context.temp_allocator)
	testing.expect(t, len(cascades) > 0, "platform_query_os_cascade_fonts must return at least 1 font")
	for p in cascades {
		testing.expect(t, os.is_file(p), "each cascade font path must exist on disk")
	}
}

@test
test_arabic_coverage_via_os_cascade :: proc(t: ^testing.T) {
	fc: font.Font_Context
	ok := font.font_context_init(&fc, 24.0)
	testing.expect(t, ok, "font_context_init must succeed")
	defer font.font_context_destroy(&fc)

	// Arabic BEH (U+0628) and NOON (U+0646) must resolve via the OS cascade (e.g. Geeza Pro)
	testing.expect(t, font.font_has_codepoint(&fc, 0x0628), "Arabic BEH must be covered via dynamic fallback")
	testing.expect(t, font.font_has_codepoint(&fc, 0x0646), "Arabic NOON must be covered via dynamic fallback")

	// Arabic presentation forms (e.g. BEH isolated / initial U+FE8F / U+FE91)
	testing.expect(t, font.font_has_codepoint(&fc, 0xFE8F), "Arabic presentation form must be covered")
}

@test
test_arabic_harfbuzz_shaping :: proc(t: ^testing.T) {
	fc: font.Font_Context
	ok := font.font_context_init(&fc, 24.0)
	testing.expect(t, ok, "font_context_init must succeed")
	defer font.font_context_destroy(&fc)

	// Find the font rasterizer covering Arabic BEH
	r := font._font_face_for_codepoint(&fc, 0x0628)
	testing.expect(t, r != nil, "must have a font face covering Arabic")
	if r == nil do return

	// Shape a 2-letter Arabic connected sequence: BEH (0x0628) + YEH (0x064A)
	pair := []rune{0x0628, 0x064A}
	cluster, shaped_ok := font.font_shape_cluster(r, pair)
	testing.expect(t, shaped_ok, "HarfBuzz shaping must succeed for Arabic sequence")
	testing.expect(t, cluster.glyph_count > 0, "shaped cluster must produce glyphs")

	// Verify contextual joining: the shaped glyph ID for initial BEH must differ from raw unshaped BEH
	unshaped_beh := font.font_rasterizer_find_glyph_index(r, 0x0628)
	testing.expect(t, cluster.glyphs[0].glyph_id != unshaped_beh || cluster.glyph_count != 2,
		"HarfBuzz must shape connected Arabic contextual forms instead of isolated glyphs")
}

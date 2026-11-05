package platform_font_tests

import "core:os"
import "core:strings"
import "core:testing"
import font "../"

@test
test_resolve_font_path :: proc(t: ^testing.T) {
	geist_mono, gm_ok := font.resolve_font_path("assets/fonts/GeistMonoNerdFont-Regular.otf", context.temp_allocator)
	testing.expect(t, gm_ok, "assets/fonts/GeistMonoNerdFont-Regular.otf should resolve")
	testing.expect(t, os.is_file(geist_mono), "resolved GeistMonoNerdFont path must exist on disk")

	geist_sans, gs_ok := font.resolve_font_path("assets/fonts/Geist-Regular.ttf", context.temp_allocator)
	testing.expect(t, gs_ok, "assets/fonts/Geist-Regular.ttf should resolve")
	testing.expect(t, os.is_file(geist_sans), "resolved Geist-Regular path must exist on disk")

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
	ok := font.font_context_init(&fc, 24.0, .Mono)
	testing.expect(t, ok, "font_context_init should succeed with bundled/system fonts")
	testing.expect(t, fc.has_font, "font_context must have primary font")
	testing.expect(t, strings.has_suffix(fc.active_path, "GeistMonoNerdFont-Regular.otf"), "primary terminal font must be GeistMonoNerdFont-Regular.otf")
	defer font.font_context_destroy(&fc)

	// Verify primary font has standard ASCII codepoints and Nerd Font PUA
	testing.expect(t, font.font_has_codepoint(&fc, 'A'), "font must have ASCII 'A'")
	testing.expect(t, font.font_has_codepoint(&fc, 'z'), "font must have ASCII 'z'")
	testing.expect(t, font.font_has_codepoint(&fc, 0xE0B0), "font must have Powerline PUA U+E0B0")

	ui_fc: font.Font_Context
	ui_ok := font.font_context_init(&ui_fc, 24.0, .Sans)
	testing.expect(t, ui_ok, "UI font_context_init (.Sans) should succeed")
	testing.expect(t, strings.has_suffix(ui_fc.active_path, "Geist-Regular.ttf"), "primary UI font must be Geist-Regular.ttf")
	defer font.font_context_destroy(&ui_fc)
	testing.expect(t, font.font_has_codepoint(&ui_fc, 'M'), "UI font must have ASCII 'M'")
	testing.expect(t, font.font_has_codepoint(&ui_fc, 0x2715), "UI font chain must cover U+2715 close glyph")

	ui_gam: font.Glyph_Atlas_Manager
	testing.expect(t, font.glyph_atlas_init(&ui_gam, &ui_fc), "UI glyph_atlas_init must succeed")
	defer font.glyph_atlas_destroy(&ui_gam)
	slot_i, _ := font.glyph_atlas_lookup_slot('i')
	slot_w, _ := font.glyph_atlas_lookup_slot('W')
	testing.expect(t, ui_gam.atlas.slots[slot_i].advance < ui_gam.atlas.slots[slot_w].advance,
		"Geist Sans UI atlas must record proportional advance ('i' < 'W')")
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

@test
test_lazy_codepoint_discovery :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	fc: font.Font_Context
	testing.expect(t, font.font_context_init(&fc, 24.0), "font_context_init must succeed")
	defer font.font_context_destroy(&fc)
	testing.expect(t, fc.fallback_count <= font.FALLBACK_INIT_LIMIT, "startup cascade must leave slots for lazy discovery")

	// Media-control glyphs (U+23F4..23FA) live only in STIXTwoMath, outside the startup cascade.
	for cp in ([]u32{0x23F5, 0x23F4, 0x23FA, 0x23BF}) {
		testing.expectf(t, font.font_has_codepoint(&fc, cp), "U+%04X must resolve via per-codepoint discovery", cp)
	}

	pixels := make([]u8, 128 * 128)
	defer delete(pixels)
	font.font_rasterize_codepoint(&fc, 0x23F5, pixels, 128, 0, 0, 128, 128)
	inked := false
	for p in pixels do if p > 0 { inked = true; break }
	testing.expect(t, inked, "U+23F5 must rasterize visible ink")
}

@test
test_unresolvable_codepoint_is_cached_miss :: proc(t: ^testing.T) {
	fc: font.Font_Context
	testing.expect(t, font.font_context_init(&fc, 24.0), "font_context_init must succeed")
	defer font.font_context_destroy(&fc)

	before := fc.fallback_count
	// U+0378 is unassigned: no font may claim it, and repeated lookups must not grow the chain.
	for _ in 0..<3 {
		testing.expect(t, !font.font_has_codepoint(&fc, 0x0378), "unassigned codepoint must miss")
	}
	testing.expect(t, !font.font_has_codepoint(&fc, 0xD800), "lone surrogate must miss")
	testing.expect_value(t, fc.fallback_count, before)
	testing.expect_value(t, fc.miss_cache[0x0378 % font.FONT_MISS_CACHE_SIZE], u32(0x0378 + 1))

	// Cluster whose base has no face falls through to the codepoint path without re-locking.
	pixels := make([]u8, 64 * 64)
	defer delete(pixels)
	font.font_rasterize_cluster_into(&fc, []rune{0x0378, 0x0301}, pixels, 64, 0, 0, 64, 64, false)
}

@test
test_text_chain_excludes_color_faces :: proc(t: ^testing.T) {
	fc: font.Font_Context
	testing.expect(t, font.font_context_init(&fc, 24.0), "font_context_init must succeed")
	defer font.font_context_destroy(&fc)

	// Text-default symbols (⏺ ➡) must resolve to an outline face: sbix glyphs rasterize blank.
	pixels := make([]u8, 128 * 128)
	defer delete(pixels)
	for cp in ([]u32{0x23FA, 0x27A1}) {
		testing.expectf(t, font.font_has_codepoint(&fc, cp), "U+%04X must resolve", cp)
		for &p in pixels do p = 0
		font.font_rasterize_codepoint(&fc, cp, pixels, 128, 0, 0, 128, 128)
		inked := false
		for p in pixels do if p > 0 { inked = true; break }
		testing.expectf(t, inked, "U+%04X must rasterize visible ink", cp)
	}
	for i in 0..<fc.fallback_count {
		testing.expectf(t, fc.fallbacks[i].face.face_flags & font.FT_FACE_FLAG_COLOR == 0, "color face in text chain: %s", fc.fallback_paths[i])
	}
}

@test
test_emoji_cluster_presentation :: proc(t: ^testing.T) {
	testing.expect(t, font.is_emoji_cluster([]rune{0x23FA, 0xFE0F}), "VS16 requests emoji presentation")
	testing.expect(t, !font.is_emoji_cluster([]rune{0x231A, 0xFE0E}), "VS15 forces text presentation on ⌚")
	testing.expect(t, !font.is_emoji_cluster([]rune{0x00A9, 0x0301}), "© with a combining mark stays text")
	testing.expect(t, font.is_emoji_cluster([]rune{0x1F3F3, 0xFE0F, 0x200D, 0x1F308}), "ZWJ flag sequence is emoji")
}

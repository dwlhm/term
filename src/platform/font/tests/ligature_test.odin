package platform_font_tests

// Behavioral unit tests for OpenType programming ligatures and Ligature_Cache.

import "core:os"
import "core:testing"
import font "../"

@test
test_ligature_candidates :: proc(t: ^testing.T) {
	candidates := []u8{'=', '>', '<', '-', '+', '!', '*', '&', '|', '/', ':', '~', '^', '.', '?'}
	for c in candidates {
		testing.expect(t, font.is_ligature_candidate(c), "symbol must be a ligature candidate")
	}

	non_candidates := []u8{'a', 'Z', '0', '9', ' ', '_', '\n', '\t', '(', ')', '[', ']', '{', '}'}
	for nc in non_candidates {
		testing.expect(t, !font.is_ligature_candidate(nc), "alphanumeric/whitespace must not be candidate")
	}
}

@test
test_ligature_cache_lookup_and_sentinel :: proc(t: ^testing.T) {
	path, ok := font.resolve_font_path("assets/fonts/MapleMono-NF-Regular.ttf", context.temp_allocator)
	if !ok do return

	r: font.Font_Rasterizer
	err: font.Font_Error
	init_ok := font.font_rasterizer_init(&r, path, 24.0, &err)
	testing.expect(t, init_ok, "Maple Mono NF should load")
	defer font.font_rasterizer_destroy(&r)

	cache: font.Ligature_Cache
	font.ligature_cache_init(&cache)

	// Programming ligatures in Maple Mono NF: "!=", "==", "->", "=>"
	test_cases := []string{"!=", "==", "->", "=>", "<="}
	for s in test_cases {
		bytes := transmute([]u8)s
		glyphs, is_lig := font.ligature_cache_lookup(&cache, &r, bytes)
		testing.expect(t, is_lig, "Maple Mono must form a ligature for sequence")
		testing.expect(t, len(glyphs) == len(s), "glyph count must match monospace run length")

		// Second lookup must be a cache hit
		glyphs_cached, is_cached := font.ligature_cache_lookup(&cache, &r, bytes)
		testing.expect(t, is_cached, "cached lookup must be a hit")
		testing.expect_value(t, len(glyphs_cached), len(glyphs))
		for i in 0..<len(glyphs) {
			testing.expect_value(t, glyphs_cached[i], glyphs[i])
		}
	}

	// Non-ligature symbol pair
	non_lig := []u8{'?', '!'}
	_, is_non := font.ligature_cache_lookup(&cache, &r, non_lig)
	testing.expect(t, !is_non, "non-ligature pair must return false")

	// Verify sentinel hit in cache
	_, is_sentinel := font.ligature_cache_lookup(&cache, &r, non_lig)
	testing.expect(t, !is_sentinel, "sentinel hit must return false without re-shaping")
}

@test
test_ligature_glyph_rasterization :: proc(t: ^testing.T) {
	path, ok := font.resolve_font_path("assets/fonts/MapleMono-NF-Regular.ttf", context.temp_allocator)
	if !ok do return

	r: font.Font_Rasterizer
	err: font.Font_Error
	init_ok := font.font_rasterizer_init(&r, path, 24.0, &err)
	testing.expect(t, init_ok)
	defer font.font_rasterizer_destroy(&r)

	cache: font.Ligature_Cache
	font.ligature_cache_init(&cache)

	glyphs, is_lig := font.ligature_cache_lookup(&cache, &r, transmute([]u8)string("!="))
	testing.expect(t, is_lig && len(glyphs) > 0)
	if !is_lig || len(glyphs) == 0 do return

	// FreeType should rasterize the ligature glyph index directly into pixels
	buf: [64 * 64]u8
	font.font_rasterize_glyph_index_into(&r, glyphs[0], buf[:], 64, 0, 0, 64, 64)
	font.font_rasterize_glyph_index_into(&r, glyphs[1], buf[:], 64, 0, 0, 64, 64)

	ink_count := 0
	for b in buf {
		if b > 0 do ink_count += 1
	}
	testing.expect(t, ink_count > 0, "rasterized ligature glyphs must produce non-zero ink")
}

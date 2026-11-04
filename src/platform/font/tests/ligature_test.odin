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

@(private = "file")
_load_maple :: proc(t: ^testing.T, r: ^font.Font_Rasterizer) -> bool {
	path, ok := font.resolve_font_path("assets/fonts/MapleMono-NF-Regular.ttf", context.temp_allocator)
	if !ok do return false
	err: font.Font_Error
	init_ok := font.font_rasterizer_init(r, path, 24.0, &err)
	testing.expect(t, init_ok, "Maple Mono NF should load")
	return init_ok
}

@test
test_ligature_cache_lookup_and_sentinel :: proc(t: ^testing.T) {
	r: font.Font_Rasterizer
	if !_load_maple(t, &r) do return
	defer font.font_rasterizer_destroy(&r)

	cache := new(font.Ligature_Cache)
	defer free(cache)

	// Programming ligatures in Maple Mono NF, shaped as whole runs
	test_cases := []string{"!=", "==", "->", "=>", "<=", "===", "-->", "<!--"}
	for s in test_cases {
		bytes := transmute([]u8)s
		glyphs, is_lig := font.ligature_cache_lookup(cache, &r, bytes)
		testing.expectf(t, is_lig, "Maple Mono must form a ligature for %q", s)
		testing.expect(t, len(glyphs) == len(s), "glyph count must match monospace run length")

		glyphs_cached, is_cached := font.ligature_cache_lookup(cache, &r, bytes)
		testing.expect(t, is_cached, "cached lookup must be a hit")
		testing.expect_value(t, len(glyphs_cached), len(glyphs))
		for i in 0..<min(len(glyphs), len(glyphs_cached)) {
			testing.expect_value(t, glyphs_cached[i], glyphs[i])
		}
	}

	non_lig := []u8{'?', '!'}
	_, is_non := font.ligature_cache_lookup(cache, &r, non_lig)
	testing.expect(t, !is_non, "non-ligature pair must return false")
	_, is_sentinel := font.ligature_cache_lookup(cache, &r, non_lig)
	testing.expect(t, !is_sentinel, "sentinel hit must return false without re-shaping")
}

// A ligature belongs to the whole run: a longer run that the font leaves plain
// must not be split into a ligature prefix (the "≡ ≡ ≡ ==" separator bug).
@test
test_ligature_whole_run_context :: proc(t: ^testing.T) {
	r: font.Font_Rasterizer
	if !_load_maple(t, &r) do return
	defer font.font_rasterizer_destroy(&r)

	cache := new(font.Ligature_Cache)
	defer free(cache)

	plain := []string{"====", "==========", "=====>", "<-->", "......", "----------", "|||||"}
	for s in plain {
		_, is_lig := font.ligature_cache_lookup(cache, &r, transmute([]u8)s)
		testing.expectf(t, !is_lig, "run %q must render as plain characters", s)
	}

	separator: [font.LIGATURE_RUN_MAX]u8
	for &b in separator do b = '='
	_, sep_lig := font.ligature_cache_lookup(cache, &r, separator[:])
	testing.expect(t, !sep_lig, "a full-width '=' separator must stay plain")

	too_long: [font.LIGATURE_RUN_MAX + 1]u8
	for &b in too_long do b = '='
	_, long_lig := font.ligature_cache_lookup(cache, &r, too_long[:])
	testing.expect(t, !long_lig, "runs beyond LIGATURE_RUN_MAX are rejected")

	// The spacer cells of "===" keep their glyph slots, the ligature sits last.
	glyphs, is_lig := font.ligature_cache_lookup(cache, &r, transmute([]u8)string("==="))
	testing.expect(t, is_lig && len(glyphs) == 3 && glyphs[2] != 0)
}

// Filling the pool resets the cache instead of overflowing it, and lookups stay correct.
@test
test_ligature_cache_pool_reset :: proc(t: ^testing.T) {
	r: font.Font_Rasterizer
	if !_load_maple(t, &r) do return
	defer font.font_rasterizer_destroy(&r)

	cache := new(font.Ligature_Cache)
	defer free(cache)

	run: [font.LIGATURE_RUN_MAX]u8
	for &b in run do b = '-'
	for n in 2..=font.LIGATURE_RUN_MAX {
		font.ligature_cache_lookup(cache, &r, run[:n])
		testing.expect(t, cache.pool_used <= font.LIGATURE_POOL_CAP)
		testing.expect(t, cache.count <= font.LIGATURE_CACHE_CAP * 3 / 4)
	}

	_, is_lig := font.ligature_cache_lookup(cache, &r, transmute([]u8)string("->"))
	testing.expect(t, is_lig, "lookups must stay correct after a reset")
}

@test
test_ligature_glyph_rasterization :: proc(t: ^testing.T) {
	r: font.Font_Rasterizer
	if !_load_maple(t, &r) do return
	defer font.font_rasterizer_destroy(&r)

	cache := new(font.Ligature_Cache)
	defer free(cache)

	glyphs, is_lig := font.ligature_cache_lookup(cache, &r, transmute([]u8)string("!="))
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

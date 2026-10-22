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

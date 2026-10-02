package render_tests

// Regression tests for atlas prewarm validity semantics.
//
// atlas_prewarm must not claim `valid` for codepoints the primary face does
// not cover: FreeType rasterizes glyph index 0 (.notdef) for those, which is
// blank, and the false flag permanently blocks atlas_prewarm_chain /
// atlas_pin_audit from promoting the slot from the fallback chain.

import "core:fmt"
import "core:os"
import "core:testing"
import "../"

// Production primary font candidates (mirrors src/app FONT_PATHS).
TEST_PRIMARY_FONT_CANDIDATES := []string{
	"assets/fonts/MapleMono-NF-Regular.ttf",
	"../assets/fonts/MapleMono-NF-Regular.ttf",
	"../../assets/fonts/MapleMono-NF-Regular.ttf",
	"assets/fonts/MapleMono-Regular.ttf",
	TEST_FONT_COURIER,
}

// Production fallback font candidates (mirrors src/app FALLBACK_FONT_PATHS).
// Missing files are tolerated by fallback_chain_init: they just shrink the
// chain, exactly as in production.
TEST_FALLBACK_FONT_CANDIDATES := []string{
	"assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"../assets/fonts/SymbolsNerdFontMono-Regular.ttf",
	"~/Library/Fonts/SymbolsNerdFontMono-Regular.ttf",
	"~/Library/Fonts/MesloLGS NF Regular.ttf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Supplemental/STIXGeneral.otf",
}

// find_primary_test_font returns the first candidate primary font that exists.
find_primary_test_font :: proc() -> (path: string, ok: bool) {
	for c in TEST_PRIMARY_FONT_CANDIDATES {
		if os.exists(c) {
			return c, true
		}
	}
	return "", false
}

@(test)
test_atlas_prewarm_chain_fills_uncovered_pinned_glyphs :: proc(t: ^testing.T) {
	font_path, ok := find_primary_test_font()
	if !ok {
		fmt.printf("no primary test font found; skipping prewarm validity regression test\n")
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

	// Pinned UI-action codepoints that a Nerd Font primary is not required to
	// cover; every one of them must end up drawn, not left as a blank cell.
	codepoints := []rune{'⌘', '⌥', '⌃', '↵'}
	checked := 0
	for r in codepoints {
		cp := u32(r)
		fi, covered := render.fallback_resolve(&chain, cp, nil)
		if !covered {
			fmt.printf("U+%04X covered by no chain font; skipping assertion for it\n", int(cp))
			continue
		}
		checked += 1

		idx, slot := render.atlas_lookup(&atlas, cp)
		testing.expect(t, slot != nil, "pinned slot should resolve")
		ink := slot_nonzero_count(&atlas, idx)
		fmt.printf(
			"U+%04X chain_font=%d valid=%v ink=%d\n",
			int(cp), fi, slot.valid, ink,
		)
		testing.expect(t, slot.valid, "pinned slot should be valid after atlas_prewarm_chain")
		testing.expect(t, ink > 0, "pinned slot must hold ink, not a blank .notdef cell")
	}
	testing.expect(t, checked > 0, "at least one pinned UI symbol must be covered by the chain")
}
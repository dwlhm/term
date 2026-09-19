package render_tests

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"
import render "../"
import termgrid "../../terminal"

find_maple_mono_font :: proc() -> (path: string, ok: bool) {
	candidates := []string{
		"assets/fonts/MapleMono-NF-Regular.ttf",
		"../assets/fonts/MapleMono-NF-Regular.ttf",
		"../../assets/fonts/MapleMono-NF-Regular.ttf",
		"/Users/dwlhm/project/term/assets/fonts/MapleMono-NF-Regular.ttf",
	}
	for c in candidates {
		if os.exists(c) {
			return c, true
		}
	}
	return "", false
}

// 1. Test candidate check proc
@(test)
test_ligature_candidate_check :: proc(t: ^testing.T) {
	candidates := []u8{'=', '>', '<', '-', '+', '!', '*', '&', '|', '/', ':', '~', '^', '.', '?'}
	for c in candidates {
		testing.expect(t, render._is_ligature_candidate(c), "Candidate check failed for symbol")
	}

	non_candidates := []u8{'a', 'Z', '0', '9', ' ', '_', '\n', '\t', '(', ')', '[', ']', '{', '}'}
	for nc in non_candidates {
		testing.expect(t, !render._is_ligature_candidate(nc), "Non-candidate character should return false")
	}
}

// 2. Test ligature cache initialization
@(test)
test_ligature_cache_initialization :: proc(t: ^testing.T) {
	c: render.Ligature_Cache
	render.ligature_cache_init(&c)

	for i in 0..<render.LIGATURE_CACHE_CAP {
		testing.expect(t, !c.entries[i].valid, "Cache entry must be invalid on init")
		testing.expect(t, c.entries[i].glyph_count == 0, "Glyph count must be 0 on init")
	}
}

// 3. Test ligature cache lookup with Maple Mono
@(test)
test_ligature_cache_lookup_and_sentinel :: proc(t: ^testing.T) {
	font_path, ok := find_maple_mono_font()
	if !ok {
		return // skip if font not present in test environment
	}

	rasterizer: render.Font_Rasterizer
	err: render.Font_Error
	init_ok := render.font_rasterizer_init(&rasterizer, font_path, 16.0, &err)
	testing.expect(t, init_ok, "Font rasterizer init failed")
	defer render.font_rasterizer_destroy(&rasterizer)

	lig_cache: render.Ligature_Cache
	render.ligature_cache_init(&lig_cache)

	// Test a programming ligature: "!="
	text_lig := []u8{'!', '='}
	glyphs, is_lig := render.ligature_cache_lookup(&lig_cache, &rasterizer, text_lig)
	testing.expect(t, is_lig, "Maple Mono should form a ligature for '!='")
	testing.expect(t, len(glyphs) > 0, "Ligature glyphs should not be empty")

	// Test cache hit for "!="
	glyphs_cached, is_lig_cached := render.ligature_cache_lookup(&lig_cache, &rasterizer, text_lig)
	testing.expect(t, is_lig_cached, "Cached lookup should be a hit")
	testing.expect(t, len(glyphs_cached) == len(glyphs), "Cached glyphs length must match")
	for i in 0..<len(glyphs) {
		testing.expect(t, glyphs_cached[i] == glyphs[i], "Cached glyph ID must match")
	}

	// Find non-ligature sequence in this font:
	candidates := []u8{'=', '>', '<', '-', '+', '!', '*', '&', '|', '/', ':', '~', '^', '.', '?'}
	found_non_lig := false
	non_pair: [2]u8
	for a in candidates {
		for b in candidates {
			pair := []u8{a, b}
			un_a := render.FT_Get_Char_Index(rasterizer.face, render.FT_ULong(a))
			un_b := render.FT_Get_Char_Index(rasterizer.face, render.FT_ULong(b))

			buf := render.hb_buffer_create()
			render.hb_buffer_add_utf8(buf, raw_data(pair), 2, 0, 2)
			render.hb_buffer_guess_segment_properties(buf)
			render.hb_shape(rasterizer.hb_font, buf, nil, 0)
			cnt: c.uint
			inf := render.hb_buffer_get_glyph_infos(buf, &cnt)
			if cnt == 2 && inf[0].codepoint == u32(un_a) && inf[1].codepoint == u32(un_b) {
				non_pair = [2]u8{a, b}
				found_non_lig = true
				render.hb_buffer_destroy(buf)
				break
			}
			render.hb_buffer_destroy(buf)
		}
		if found_non_lig do break
	}

	testing.expect(t, found_non_lig, "Must find at least one non-ligature candidate pair in font")

	text_non := non_pair[:]
	_, is_non_lig := render.ligature_cache_lookup(&lig_cache, &rasterizer, text_non)
	testing.expect(t, !is_non_lig, "Non-ligature sequence should return false")

	// Verify sentinel hit in cache
	_, is_sentinel_cached := render.ligature_cache_lookup(&lig_cache, &rasterizer, text_non)
	testing.expect(t, !is_sentinel_cached, "Sentinel hit must return false without re-shaping")
}

// 4. Test render compilation with ligatures in _compile_row_range
@(test)
test_compile_row_range_with_ligatures :: proc(t: ^testing.T) {
	font_path, ok := find_maple_mono_font()
	if !ok {
		return
	}

	rasterizer: render.Font_Rasterizer
	init_ok := render.font_rasterizer_init(&rasterizer, font_path, 16.0)
	testing.expect(t, init_ok, "Font rasterizer init failed")
	defer render.font_rasterizer_destroy(&rasterizer)

	c: render.Ligature_Cache
	render.ligature_cache_init(&c)

	terminal := new(termgrid.Terminal)
	defer free(terminal)
	termgrid.terminal_init(terminal, 2, 10)
	defer termgrid.terminal_destroy(terminal)

	// Write "a != b" into row 0
	row_text := "a != b"
	for ch, col in row_text {
		cell := termgrid.Semantic_Cell{
			content = u32(ch),
			style = 0,
			width = 1,
			flags = .None,
		}
		termgrid.grid_set_cell(&terminal.grid, 0, col, cell)
	}

	style_table: termgrid.Style_Table
	termgrid.style_table_init(&style_table)

	frame: render.Compiled_Frame
	render.render_compiler_init(&frame, 2, 10)
	defer render.render_compiler_destroy(&frame)

	render._compile_row_range(&frame, terminal, &style_table, 0, 0, 10, &c, &rasterizer)

	// Cell 0: 'a' -> unchanged
	cp0, _, _, _ := render.render_cell_unpack(frame.cells[0])
	testing.expect(t, cp0 == u32('a'), "Cell 0 ('a') must retain regular codepoint")

	// Cell 1: ' ' -> unchanged
	cp1, _, _, _ := render.render_cell_unpack(frame.cells[1])
	testing.expect(t, cp1 == u32(' '), "Cell 1 (' ') must retain space")

	// Cells 2 and 3: "!=" -> replaced with CONTENT_LIGATURE_BASE + glyph_id
	cp2, _, _, _ := render.render_cell_unpack(frame.cells[2])
	cp3, _, _, _ := render.render_cell_unpack(frame.cells[3])
	testing.expect(t, cp2 >= render.CONTENT_LIGATURE_BASE, "Cell 2 ('!') must receive ligature base codepoint")
	testing.expect(t, cp3 >= render.CONTENT_LIGATURE_BASE, "Cell 3 ('=') must receive ligature base codepoint")

	// Cell 4: ' ' -> unchanged
	cp4, _, _, _ := render.render_cell_unpack(frame.cells[4])
	testing.expect(t, cp4 == u32(' '), "Cell 4 (' ') must retain space")

	// Cell 5: 'b' -> unchanged
	cp5, _, _, _ := render.render_cell_unpack(frame.cells[5])
	testing.expect(t, cp5 == u32('b'), "Cell 5 ('b') must retain regular codepoint")
}

// 5. Test font_rasterize_glyph_index_into and font_rasterize_glyph_index_fitted
@(test)
test_font_rasterize_glyph_index :: proc(t: ^testing.T) {
	font_path, ok := find_maple_mono_font()
	if !ok {
		return
	}

	rasterizer: render.Font_Rasterizer
	init_ok := render.font_rasterizer_init(&rasterizer, font_path, 16.0)
	testing.expect(t, init_ok, "Font rasterizer init failed")
	defer render.font_rasterizer_destroy(&rasterizer)

	// Glyph index 1 is usually valid in TrueType fonts
	glyph_idx: u32 = 1

	// Test rasterize fitted
	bmp := render.font_rasterize_glyph_index_fitted(&rasterizer, glyph_idx, 16, 16)
	defer if bmp.pixels != nil do delete(bmp.pixels)
	testing.expect(t, bmp.advance > 0, "Glyph advance should be positive")

	// Test rasterize into buffer
	stride := 64
	buf := make([]u8, stride * 64)
	defer delete(buf)

	render.font_rasterize_glyph_index_into(&rasterizer, glyph_idx, buf, stride, 0, 0, 64, 64)
}

// 6. Test atlas rasterization into slot for ligature codepoint
@(test)
test_atlas_rasterize_ligature_slot :: proc(t: ^testing.T) {
	font_path, ok := find_maple_mono_font()
	if !ok {
		return
	}

	rasterizer: render.Font_Rasterizer
	init_ok := render.font_rasterizer_init(&rasterizer, font_path, 16.0)
	testing.expect(t, init_ok, "Font rasterizer init failed")
	defer render.font_rasterizer_destroy(&rasterizer)

	atlas: render.Atlas
	render.atlas_init(&atlas, &rasterizer)
	defer render.atlas_destroy(&atlas)

	lig_cp := render.CONTENT_LIGATURE_BASE + 1
	idx, slot := render.atlas_lookup(&atlas, lig_cp)
	testing.expect(t, idx >= 0 && idx < render.ATLAS_SLOT_COUNT, "Slot index within bounds")

	render._atlas_rasterize_into_slot(&atlas, &rasterizer, lig_cp, idx)
	testing.expect(t, slot.valid, "Atlas slot must be valid after rasterization")
	testing.expect(t, slot.advance > 0, "Slot advance must be positive")
}

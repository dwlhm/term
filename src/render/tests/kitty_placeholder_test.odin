package render_tests

import "core:testing"
import render ".."
import instance "../instance"
import termgrid "../../terminal"

KITTY_UNCOVERED_CODEPOINT :: rune(0x10FFFF)

@(test)
test_kitty_placeholder_v1_suppresses_glyph :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 1)
	defer termgrid.terminal_destroy(&term)
	termgrid.grid_set_cell(&term.grid, 0, 0, termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(termgrid.KITTY_GRAPHICS_PLACEHOLDER),
		style = 0,
		width = 2,
	})

	frame: render.Compiled_Frame
	render.render_compiler_init(&frame, 1, 1)
	defer render.render_compiler_destroy(&frame)
	render._compile_row_range(&frame, &term, &term.grid.style_table, 0, 0, 1)

	content, fg, bg, flags := render.render_cell_unpack(frame.cells[0])
	style := termgrid.style_table_get(&term.grid.style_table, 0)
	testing.expect_value(t, content, u32(' '))
	testing.expect_value(t, fg, render.color_to_r5g6b5(style.fg))
	testing.expect_value(t, bg, render.color_to_r5g6b5(style.bg))
	testing.expect_value(t, flags, render.Render_Cell_Flags(2))
}

@(test)
test_kitty_placeholder_semantic_pack_is_blank :: proc(t: ^testing.T) {
	cell := termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(termgrid.KITTY_GRAPHICS_PLACEHOLDER),
		style = 7,
		width = 2,
		flags = .Direct_Color,
	}
	packed := render.render_cell_from_semantic(cell, true)
	content, style, width, cflags, slot := render.render_cell_unpack_v2(packed)

	testing.expect_value(t, content, u32(0))
	testing.expect_value(t, style, u16(7))
	testing.expect_value(t, width, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD)
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "direct semantic placeholder must preserve selection")
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_DIRECT_COLOR != 0, "direct semantic placeholder must preserve direct color")
	testing.expect_value(t, slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
}

@(test)
test_kitty_placeholder_expander_suppresses_raw_glyph :: proc(t: ^testing.T) {
	lut := _test_lut()
	atlas := _test_atlas()
	slot, ok := render.atlas_pinned_slot_index(u32('A'))
	testing.expect(t, ok, "test atlas must provide a pinned glyph slot")

	cell := render.render_cell_pack_v2(
		u32(termgrid.KITTY_GRAPHICS_PLACEHOLDER),
		1,
		render.RENDER_CELL_V2_WIDTH_NARROW,
		0,
		u16(slot),
	)
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph, emit_emoji, emit_decor := render.render_cell_expand_instance(
		cell, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph,
	)

	testing.expect(t, emit_bg, "raw placeholder must retain its non-default background")
	testing.expect(t, !emit_glyph, "raw placeholder must not emit a glyph")
	testing.expect(t, !emit_emoji && !emit_decor, "raw placeholder must emit neither emoji nor decoration")
	testing.expect(t, glyph == instance.Instance_Data{}, "raw placeholder must leave the glyph instance unwritten")
}

@(test)
test_kitty_placeholder_v2_preserves_selection_and_direct_color :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 1)
	defer termgrid.terminal_destroy(&term)
	termgrid.grid_set_cell(&term.grid, 0, 0, termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(termgrid.KITTY_GRAPHICS_PLACEHOLDER),
		style = 0,
		width = 2,
		flags = .Direct_Color,
	})

	view := termgrid.Terminal_View{
		selection = termgrid.Terminal_Selection{
			active = true,
			anchor = termgrid.Terminal_Point{row = 0, col = 0},
			focus = termgrid.Terminal_Point{row = 0, col = 0},
		},
	}
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 1)
	defer render.render_compiler_destroy_v2(&frame)
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	render.raster_queue_init(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	chain: render.Fallback_Chain
	cache: render.Shape_Cache
	atlas: render.Atlas
	fcounters: render.Fallback_Counters
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q, &view)

	content, style, width, cflags, slot := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, content, u32(0))
	testing.expect_value(t, style, u16(0))
	testing.expect_value(t, width, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD)
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "placeholder must preserve selection")
	testing.expect(t, cflags & render.RENDER_CELL_V2_CFLAG_DIRECT_COLOR != 0, "placeholder must preserve direct color")
	testing.expect_value(t, slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	testing.expect_value(t, fcounters.fallback_miss, u64(0))
	testing.expect_value(t, rcounters.enqueued, u64(0))
	testing.expect_value(t, rcounters.coalesced, u64(0))
	testing.expect_value(t, rcounters.overflow, u64(0))
}

@(test)
test_kitty_placeholder_grapheme_suppresses_marks_and_requests :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 1)
	defer termgrid.terminal_destroy(&term)
	h := termgrid.grapheme_store_append(
		&term.grapheme_store,
		termgrid.KITTY_GRAPHICS_PLACEHOLDER,
		rune(0x0301),
	)
	termgrid.grid_set_cell(&term.grid, 0, 0, termgrid.Semantic_Cell{content = h, width = 1})

	shaped := render.shaped_cell_from_cluster(
		termgrid.Semantic_Cell{content = h, style = 3, width = 2, flags = .Direct_Color},
		0, 0, &term.grapheme_store, nil, nil, nil, nil, nil,
		termgrid.Damage_Target{}, nil, true)
	shaped_content, shaped_style, shaped_width, shaped_flags, shaped_slot := render.render_cell_unpack_v2(shaped)
	testing.expect_value(t, shaped_content, u32(0))
	testing.expect_value(t, shaped_style, u16(3))
	testing.expect_value(t, shaped_width, render.RENDER_CELL_V2_WIDTH_WIDE_LEAD)
	testing.expect(t, shaped_flags & render.RENDER_CELL_V2_CFLAG_SELECTED != 0, "shaped placeholder must preserve selection")
	testing.expect(t, shaped_flags & render.RENDER_CELL_V2_CFLAG_DIRECT_COLOR != 0, "shaped placeholder must preserve direct color")
	testing.expect_value(t, shaped_slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)

	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 1)
	defer render.render_compiler_destroy_v2(&frame)
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	render.raster_queue_init(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	chain: render.Fallback_Chain
	cache: render.Shape_Cache
	atlas: render.Atlas
	fcounters: render.Fallback_Counters
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)

	content, _, width, _, slot := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, content, u32(0))
	testing.expect_value(t, width, render.RENDER_CELL_V2_WIDTH_NARROW)
	testing.expect_value(t, slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	testing.expect_value(t, fcounters.fallback_miss, u64(0))
	testing.expect_value(t, fcounters.mark_drop, u64(0))
	testing.expect_value(t, rcounters.enqueued, u64(0))
	testing.expect(t, termgrid.grid_get_cell(&term.grid, 0, 0).content == h, "semantic grapheme must remain unchanged")
}

@(test)
test_kitty_placeholder_keeps_uncovered_tofu_path :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	counters: render.Fallback_Counters
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 1)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_char(&term, KITTY_UNCOVERED_CODEPOINT)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 1)
	defer render.render_compiler_destroy_v2(&frame)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &counters)

	testing.expect(t, counters.fallback_miss >= 1, "ordinary uncovered codepoint must still miss")
	g, hit := _fb_shaped(&term, &cache, 0, 0)
	testing.expect(t, hit, "ordinary uncovered codepoint must use tofu")
	testing.expect_value(t, g.shaped_codepoint, u32(render.FALLBACK_TOFU_PRIMARY))
}

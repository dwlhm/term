package render_tests

import "core:testing"
import render "../"
import instance "../instance"
import tg "../../terminal"
import p "../../parser"

@(test)
test_codex_composer_erase_background_instances :: proc(t: ^testing.T) {
	term := new(tg.Terminal)
	tg.terminal_init(term, 3, 12)
	defer free(term)
	defer tg.terminal_destroy(term)
	parser: p.Parser
	p.parser_init(&parser)
	// Each composer row is erased, then sparse animation cells are updated.
	p.parse_chunk(&parser, term, transmute([]u8)string("\x1b[48;2;57;57;71m\x1b[1;1H\x1b[K\x1b[2;1H\x1b[K\x1b[3;1H\x1b[K\x1b[1;3Hx\x1b[2;5Hy\x1b[3;7Hz\x1b[1;3H \x1b[2;5H \x1b[3;7H "))
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 3, 12)
	defer render.render_compiler_destroy_v2(&frame)
	render.render_compile_full_v2(&frame, term)
	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &term.grid.style_table)
	atlas := _test_atlas()
	er, eg, eb := render.unpack_argb_float(0xFF393947)
	for row in 0..<3 { for col in 0..<12 {
		packed := frame.cells[row * 12 + col]
		bg, glyph: instance.Instance_Data
		dc := tg.terminal_view_get_direct_color(term, nil, row, col)
		emit_bg, emit_glyph, emit_emoji, emit_decor := render.render_cell_expand_instance(packed, &lut, &atlas, f32(col * 8), f32(row * 16), 8, 16, &bg, &glyph, direct_color = dc)
		testing.expect(t, emit_bg && !emit_glyph && !emit_emoji && !emit_decor)
		testing.expect(t, bg.r == er && bg.g == eg && bg.b == eb)
		testing.expect(t, bg.x == f32(col * 8) && bg.y == f32(row * 16))
		testing.expect(t, bg.cw == 8 && bg.ch == 16 && bg.a == 1)
	}}
}

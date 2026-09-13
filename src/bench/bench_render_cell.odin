package bench

// Render cell V2 benchmark matrix: packs the P64/P48/P96 candidate layouts,
// full V2 compile, AoS vs SoA expand, and 1-cell / 1-row / full upload rungs.
//
// Byte-count rule: bytes_uploaded counts instance bytes (instances × 48),
// NOT the compile buffer. Compile footprint (6/8/12) is reported separately.

import "core:fmt"
import render "../render"
import instance "../render/instance"
import termgrid "../terminal"

RENDER_CELL_BENCH_ROWS :: 24
RENDER_CELL_BENCH_COLS :: 80
RENDER_CELL_BENCH_FULL :: 1920

// Render_Cell_Bench_Grid is a deterministic 24x80 semantic cell fixture.
Render_Cell_Bench_Grid :: struct {
	cells: [RENDER_CELL_BENCH_FULL]termgrid.Semantic_Cell,
}

// render_cell_bench_fixture builds the deterministic fixture:
// ASCII + box drawing + wide-pair + orphan continuation + style extremes.
render_cell_bench_fixture :: proc() -> Render_Cell_Bench_Grid {
	grid: Render_Cell_Bench_Grid
	for i in 0..<RENDER_CELL_BENCH_FULL {
		grid.cells[i] = termgrid.Semantic_Cell{
			content = u32(32 + (i % 95)),
			style   = u16(i % 8),
			width   = 1,
			flags   = .None,
		}
		if i % 37 == 0 {
			grid.cells[i].content = u32(0x2500 + (i % 128))
		}
	}
	// Wide pair (lead + continuation).
	grid.cells[500] = termgrid.Semantic_Cell{content = 0x4E2D, style = 3, width = 2, flags = .None}
	grid.cells[501] = termgrid.Semantic_Cell{content = 0, style = 3, width = 0, flags = .Wide_Continuation}
	// Orphan continuation.
	grid.cells[1000] = termgrid.Semantic_Cell{content = 0x41, style = 1, width = 0, flags = .Wide_Continuation}
	// Style extremes + empty + overflow rows.
	grid.cells[1001] = termgrid.Semantic_Cell{content = 0x42, style = 1023, width = 1, flags = .None}
	grid.cells[1002] = termgrid.Semantic_Cell{content = 0x43, style = 2000, width = 1, flags = .None}
	grid.cells[1003] = termgrid.Semantic_Cell{content = 0, style = 0, width = 1, flags = .None}
	grid.cells[1004] = termgrid.Semantic_Cell{content = 0x20, style = 0, width = 1, flags = .None}
	grid.cells[1005] = termgrid.Semantic_Cell{content = 0x200000, style = 5, width = 1, flags = .None}
	return grid
}

// _bench_width_cflags maps semantic width/flags to V2 width/cflags.
_bench_width_cflags :: proc(cell: termgrid.Semantic_Cell) -> (u8, u8) {
	if u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) != 0 {
		return render.RENDER_CELL_V2_WIDTH_CONTINUATION, render.RENDER_CELL_V2_CFLAG_WIDE_CONT
	}
	if cell.width == 2 {
		return render.RENDER_CELL_V2_WIDTH_WIDE_LEAD, 0
	}
	return render.RENDER_CELL_V2_WIDTH_NARROW, 0
}

// _bench_lut builds a LUT from a small deterministic style table.
_bench_lut :: proc() -> render.Style_LUT {
	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	termgrid.style_table_insert(&table, termgrid.Style{fg = 0xFFFF0000, bg = 0xFF000000})
	termgrid.style_table_insert(&table, termgrid.Style{fg = 0xFF00FF00, bg = 0xFF111111})
	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)
	return lut
}

// _bench_atlas_stub builds a CPU-only atlas with valid pinned ASCII + box slots.
_bench_atlas_stub :: proc() -> render.Atlas {
	atlas: render.Atlas
	atlas.slot_count = render.ATLAS_SLOT_COUNT
	for cp in 32..<127 {
		if idx, ok := render.atlas_pinned_slot_index(u32(cp)); ok {
			atlas.slots[idx] = render.Atlas_Slot{u0 = 0, v0 = 0, u1 = 1, v1 = 1, advance = 8, valid = true}
		}
	}
	for cp in 0x2500..<0x2580 {
		if idx, ok := render.atlas_pinned_slot_index(u32(cp)); ok {
			atlas.slots[idx] = render.Atlas_Slot{u0 = 0, v0 = 0, u1 = 1, v1 = 1, advance = 8, valid = true}
		}
	}
	return atlas
}

// bench_pack_p64 packs the fixture via render_cell_from_semantic.
bench_pack_p64 :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	checksum: u64 = 0
	for i in 0..<RENDER_CELL_BENCH_FULL {
		v := render.render_cell_from_semantic(grid.cells[i])
		checksum ~= u64(v)
	}
	ctx.allocation_count += RENDER_CELL_BENCH_FULL + int(checksum & 1)
}

// bench_pack_p48 fills the 6-byte candidate layout from the fixture.
bench_pack_p48 :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	cells: [RENDER_CELL_BENCH_FULL]render.Render_Cell_P48
	for i in 0..<RENDER_CELL_BENCH_FULL {
		w, cf := _bench_width_cflags(grid.cells[i])
		cells[i] = render.Render_Cell_P48{
			codepoint = grid.cells[i].content,
			style     = u16(grid.cells[i].style),
			packed    = u16(w) | (u16(cf) << 2),
		}
	}
	ctx.allocation_count += RENDER_CELL_BENCH_FULL + int(cells[0].packed & 1)
}

// bench_pack_p96 fills the 12-byte candidate layout from the fixture.
bench_pack_p96 :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	cells: [RENDER_CELL_BENCH_FULL]render.Render_Cell_P96
	for i in 0..<RENDER_CELL_BENCH_FULL {
		cells[i] = render.Render_Cell_P96{
			v2   = render.render_cell_from_semantic(grid.cells[i]),
			slot = u32(render.RENDER_CELL_V2_SLOT_UNRESOLVED),
		}
	}
	ctx.allocation_count += RENDER_CELL_BENCH_FULL + int(cells[0].slot & 1)
}

// bench_compile_full_v2 compiles a 24x80 terminal grid into a V2 frame.
bench_compile_full_v2 :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	term: termgrid.Terminal
	termgrid.terminal_init(&term, RENDER_CELL_BENCH_ROWS, RENDER_CELL_BENCH_COLS)
	defer termgrid.terminal_destroy(&term)

	for i in 0..<RENDER_CELL_BENCH_FULL {
		termgrid.grid_set_cell(&term.grid, i / RENDER_CELL_BENCH_COLS, i % RENDER_CELL_BENCH_COLS, grid.cells[i])
	}

	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, RENDER_CELL_BENCH_ROWS, RENDER_CELL_BENCH_COLS)
	defer render.render_compiler_destroy_v2(&frame)

	render.render_compile_full_v2(&frame, &term)
	ctx.allocation_count += int(frame.cell_count)
}

// bench_expand_aos expands packed V2 cells (AoS) into instances; bytes = n × 48.
bench_expand_aos :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	lut := _bench_lut()
	atlas := _bench_atlas_stub()

	instances: int = 0
	for i in 0..<RENDER_CELL_BENCH_FULL {
		v := render.render_cell_from_semantic(grid.cells[i])
		bg, glyph: instance.Instance_Data
		emit_bg, emit_glyph, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
		if emit_bg {
			instances += 1
		}
		if emit_glyph {
			instances += 1
		}
	}
	ctx.gpu_stats.bytes_uploaded += instances * instance.INSTANCE_STRIDE
	ctx.allocation_count += instances
}

// bench_expand_soa expands the SoA candidate layout into instances; bytes = n × 48.
bench_expand_soa :: proc(ctx: ^Benchmark_Context) {
	grid := render_cell_bench_fixture()
	lut := _bench_lut()
	atlas := _bench_atlas_stub()

	codepoints: [RENDER_CELL_BENCH_FULL]u32
	styles_flags: [RENDER_CELL_BENCH_FULL]u32
	for i in 0..<RENDER_CELL_BENCH_FULL {
		w, cf := _bench_width_cflags(grid.cells[i])
		codepoints[i] = grid.cells[i].content
		styles_flags[i] = u32(u16(grid.cells[i].style) & 0x3FF) | (u32(w & 3) << 10) | (u32(cf & 0x7F) << 12) | (u32(render.RENDER_CELL_V2_SLOT_UNRESOLVED & 0x1FF) << 19)
	}
	soa := render.Render_Cells_SoA{codepoints = codepoints[:], styles_flags = styles_flags[:]}

	instances: int = 0
	for i in 0..<RENDER_CELL_BENCH_FULL {
		sf := soa.styles_flags[i]
		v := render.render_cell_pack_v2(
			soa.codepoints[i],
			u16(sf & 0x3FF),
			u8((sf >> 10) & 0x3),
			u8((sf >> 12) & 0x7F),
			u16((sf >> 19) & 0x1FF),
		)
		bg, glyph: instance.Instance_Data
		emit_bg, emit_glyph, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
		if emit_bg {
			instances += 1
		}
		if emit_glyph {
			instances += 1
		}
	}
	ctx.gpu_stats.bytes_uploaded += instances * instance.INSTANCE_STRIDE
	ctx.allocation_count += instances
}

// _bench_upload_prefix expands the first n fixture cells and counts clamped instance bytes.
_bench_upload_prefix :: proc(ctx: ^Benchmark_Context, n: int) {
	grid := render_cell_bench_fixture()
	lut := _bench_lut()
	atlas := _bench_atlas_stub()

	instances: int = 0
	for i in 0..<n {
		v := render.render_cell_from_semantic(grid.cells[i])
		bg, glyph: instance.Instance_Data
		emit_bg, emit_glyph, _ := render.render_cell_expand_instance(v, &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
		if emit_bg {
			instances += 1
		}
		if emit_glyph {
			instances += 1
		}
	}
	bytes := instances * instance.INSTANCE_STRIDE
	if bytes > render.RENDER_UPLOAD_CAPACITY {
		bytes = render.RENDER_UPLOAD_CAPACITY
	}
	ctx.gpu_stats.bytes_uploaded += bytes
	ctx.gpu_stats.draw_calls += 2
	ctx.allocation_count += instances
}

// bench_upload_1cell uploads a single cell (bytes = n × 48, draws = 2).
bench_upload_1cell :: proc(ctx: ^Benchmark_Context) {
	_bench_upload_prefix(ctx, 1)
}

// bench_upload_1row uploads one 80-cell row.
bench_upload_1row :: proc(ctx: ^Benchmark_Context) {
	_bench_upload_prefix(ctx, RENDER_CELL_BENCH_COLS)
}

// bench_upload_full uploads the full 1920-cell grid.
bench_upload_full :: proc(ctx: ^Benchmark_Context) {
	_bench_upload_prefix(ctx, RENDER_CELL_BENCH_FULL)
}

// render_cell_bench_all returns the full V2 benchmark matrix.
render_cell_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 9)
	benches[0] = Benchmark{name = "pack_p64", run = bench_pack_p64, iterations = 1000}
	benches[1] = Benchmark{name = "pack_p48", run = bench_pack_p48, iterations = 1000}
	benches[2] = Benchmark{name = "pack_p96", run = bench_pack_p96, iterations = 1000}
	benches[3] = Benchmark{name = "compile_full_v2", run = bench_compile_full_v2, iterations = 50}
	benches[4] = Benchmark{name = "expand_aos", run = bench_expand_aos, iterations = 100}
	benches[5] = Benchmark{name = "expand_soa", run = bench_expand_soa, iterations = 100}
	benches[6] = Benchmark{name = "upload_1cell", run = bench_upload_1cell, iterations = 200}
	benches[7] = Benchmark{name = "upload_1row", run = bench_upload_1row, iterations = 200}
	benches[8] = Benchmark{name = "upload_full", run = bench_upload_full, iterations = 50}
	return benches
}

// render_cell_bench_report formats a comparison table over the matrix results.
// The caller owns the returned string.
render_cell_bench_report :: proc(results: []Benchmark_Result) -> string {
	out := fmt.aprintf(
		"Render_Cell_V2 layout comparison (compile footprint vs instance bytes):\n" +
		"  P64 pack: 8B/cell | P48 pack: 6B/cell | P96 pack: 12B/cell | instances: 48B each\n",
	)
	for &r in results {
		line := fmt.aprintf("  %-16s mean %8.1fns p95 %8.1fns iters %d\n", r.name, r.stats.mean, r.stats.p95, r.iterations)
		next := fmt.aprintf("%s%s", out, line)
		delete(out)
		delete(line)
		out = next
	}
	return out
}

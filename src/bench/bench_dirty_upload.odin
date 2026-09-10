package bench

// Phase 8 dirty-upload benchmark rungs: 1-cell / 1-row / fullscreen rebase.
// Byte-count rule: bytes_uploaded counts instance bytes written (ranges x 48),
// draws stay constant at 2 per frame regardless of dirty extent.

import render "../render"
import instance "../render/instance"
import termgrid "../terminal"

DIRTY_BENCH_ROWS :: 24
DIRTY_BENCH_COLS :: 80
DIRTY_BENCH_N :: DIRTY_BENCH_ROWS * DIRTY_BENCH_COLS
DIRTY_BENCH_FULLSCREEN_BYTES :: 2 * DIRTY_BENCH_N * instance.INSTANCE_STRIDE

// _dirty_bench_setup builds a CPU-only renderer + terminal with a live dirty upload.
_dirty_bench_setup :: proc(term: ^termgrid.Terminal, r: ^render.Renderer, d: ^render.Dirty_Upload, lut: ^render.Style_LUT) {
	termgrid.terminal_init(term, DIRTY_BENCH_ROWS, DIRTY_BENCH_COLS)
	r.rows = DIRTY_BENCH_ROWS
	r.cols = DIRTY_BENCH_COLS
	r.cell_width = 8
	r.cell_height = 16
	r.instances.max_instances = render.RENDER_MAX_INSTANCES
	r.atlas = _bench_atlas_stub()
	render.render_compiler_init_v2(&r.compiled_v2, DIRTY_BENCH_ROWS, DIRTY_BENCH_COLS)
	render.dirty_upload_init(d, r)
	render.style_lut_rebuild(lut, &term.grid.style_table)
}

// _dirty_bench_teardown releases setup resources.
_dirty_bench_teardown :: proc(term: ^termgrid.Terminal, r: ^render.Renderer, d: ^render.Dirty_Upload) {
	render.dirty_upload_destroy(d)
	render.render_compiler_destroy_v2(&r.compiled_v2)
	termgrid.terminal_destroy(term)
}

// bench_dirty_expand_1cell frames a single dirty cell (widened to 3 cols = 288B).
bench_dirty_expand_1cell :: proc(ctx: ^Benchmark_Context) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	_dirty_bench_setup(&term, &r, &d, &lut)
	defer _dirty_bench_teardown(&term, &r, &d)

	termgrid.terminal_move_cursor(&term, 12, 40)
	termgrid.terminal_put_char(&term, 'Q')
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, fell_back := render.dirty_upload_frame(&d, &r, &term, &journal, &lut, &ranges)
	_ = fell_back
	ctx.gpu_stats.bytes_uploaded += int(bytes)
	ctx.gpu_stats.draw_calls += 2
	ctx.allocation_count += flushed + int(bytes & 1)
}

// bench_dirty_expand_1row frames one fully dirty row (2 ranges = 2*80*48B).
bench_dirty_expand_1row :: proc(ctx: ^Benchmark_Context) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	_dirty_bench_setup(&term, &r, &d, &lut)
	defer _dirty_bench_teardown(&term, &r, &d)

	termgrid.damage_mark_row(&term.damage, 12, 0)
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, _ := render.dirty_upload_frame(&d, &r, &term, &journal, &lut, &ranges)
	ctx.gpu_stats.bytes_uploaded += int(bytes)
	ctx.gpu_stats.draw_calls += 2
	ctx.allocation_count += flushed
}

// bench_dirty_rebase_fullscreen rebases the full 24x80 grid (2N*48B, one upload).
bench_dirty_rebase_fullscreen :: proc(ctx: ^Benchmark_Context) {
	term: termgrid.Terminal
	r: render.Renderer
	d: render.Dirty_Upload
	lut: render.Style_LUT
	_dirty_bench_setup(&term, &r, &d, &lut)
	defer _dirty_bench_teardown(&term, &r, &d)

	grid := render_cell_bench_fixture()
	for i in 0..<DIRTY_BENCH_N {
		termgrid.grid_set_cell(&term.grid, i / DIRTY_BENCH_COLS, i % DIRTY_BENCH_COLS, grid.cells[i])
	}
	render.render_compile_full_v2(&r.compiled_v2, &term)
	render.dirty_upload_rebase(&d, &r, &lut)

	ctx.gpu_stats.bytes_uploaded += DIRTY_BENCH_FULLSCREEN_BYTES
	ctx.gpu_stats.draw_calls += 2
	ctx.allocation_count += DIRTY_BENCH_N
}

// dirty_upload_bench_all returns the Phase 8 dirty-upload benchmark rungs.
dirty_upload_bench_all :: proc() -> []Benchmark {
	benches := make([]Benchmark, 3)
	benches[0] = Benchmark{name = "dirty_expand_1cell", run = bench_dirty_expand_1cell, iterations = 200}
	benches[1] = Benchmark{name = "dirty_expand_1row", run = bench_dirty_expand_1row, iterations = 200}
	benches[2] = Benchmark{name = "rebase_fullscreen", run = bench_dirty_rebase_fullscreen, iterations = 50}
	return benches
}

package render_tests

// Phase 8 dirty-upload tests (CPU-only, nil backend):
// stable slot mapping, offset byte ranges, stale kills, merges,
// orphan widening, scroll fallback, empty skip, and capacity fallback.

import "core:testing"
import render "../"
import instance "../instance"
import termgrid "../../terminal"

DIRTY_TEST_ROWS :: 4
DIRTY_TEST_COLS :: 8
DIRTY_TEST_N :: DIRTY_TEST_ROWS * DIRTY_TEST_COLS

// _dirty_test_renderer builds a CPU-only renderer state: nil backend,
// valid atlas slots, and an initialized V2 frame. No GPU resources.
_dirty_test_renderer :: proc(rows, cols: int) -> render.Renderer {
	r: render.Renderer
	r.rows = i32(rows)
	r.cols = i32(cols)
	r.cell_width = 8
	r.cell_height = 16
	r.instances.max_instances = render.RENDER_MAX_INSTANCES
	r.atlas = _dirty_test_atlas()
	render.render_compiler_init_v2(&r.compiled_v2, i32(rows), i32(cols))
	return r
}

_dirty_test_destroy :: proc(r: ^render.Renderer, d: ^render.Dirty_Upload) {
	render.dirty_upload_destroy(d)
	render.render_compiler_destroy_v2(&r.compiled_v2)
}

// _dirty_test_frame runs one dirty frame and destroys the journal.
_dirty_test_frame :: proc(
	d: ^render.Dirty_Upload,
	r: ^render.Renderer,
	term: ^termgrid.Terminal,
	lut: ^render.Style_LUT,
	ranges: ^[render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range,
) -> (flushed_ranges: int, flushed_bytes: u64, fell_back: bool) {
	journal := termgrid.terminal_take_damage(term)
	defer termgrid.damage_journal_destroy(&journal)
	return render.dirty_upload_frame(d, r, term, &journal, lut, ranges)
}

@(test)
test_dirty_upload_1cell :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm on small grid")
	defer render.dirty_upload_destroy(&d)
	testing.expect(t, d.armed, "dirty must be armed after init")
	testing.expect(t, render.dirty_upload_validate_mirror(&d, &r), "dirty mirror must preserve bg/glyph layout")

	lut := _dirty_test_lut()
	termgrid.terminal_move_cursor(&term, 0, 3)
	termgrid.terminal_put_char(&term, 'X')

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "1-cell frame must not fall back")
	testing.expect_value(t, flushed, 2)
	testing.expect(t, bytes == u64(3 * 2) * instance.INSTANCE_STRIDE, "1-cell bytes must equal one widened run")
	testing.expect(t, bytes < u64(2 * DIRTY_TEST_N * 48), "1-cell bytes must be << fullscreen bytes")

	// Stable slots: bg slot i=3, glyph slot N+3.
	testing.expect(t, d.mirror[3] != instance.Instance_Data{}, "dirty bg slot must hold the cell instance")
	testing.expect(t, d.mirror[DIRTY_TEST_N+3] != instance.Instance_Data{}, "dirty glyph slot must hold the cell instance")
	testing.expect(t, render.dirty_upload_validate_mirror(&d, &r), "single-cell update must keep mirror valid")
}

@(test)
test_dirty_upload_empty_to_occupied :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range

	// Baseline: all slots degenerate.
	for i in 0..<2 * DIRTY_TEST_N {
		testing.expect(t, d.mirror[i] == instance.Instance_Data{}, "init mirror must be all degenerate")
	}

	termgrid.terminal_put_string(&term, "AB")
	flushed, _, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "occupied frame must not fall back")
	testing.expect_value(t, flushed, 2)
	testing.expect(t, d.mirror[0] != instance.Instance_Data{}, "newly occupied bg slot must be written")
	testing.expect(t, d.mirror[DIRTY_TEST_N] != instance.Instance_Data{}, "newly occupied glyph slot must be written")
}

@(test)
test_dirty_upload_occupied_to_empty :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range

	termgrid.terminal_put_string(&term, "AB")
	_, _, _ = _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, d.mirror[0] != instance.Instance_Data{}, "occupied bg slot must be live before erase")

	// Erase cell (0,0) back to default and mark it dirty.
	termgrid.grid_set_cell(&term.grid, 0, 0, termgrid.CELL_DEFAULT)
	termgrid.damage_mark_cell(&term.damage, 0, 0, 0)
	flushed, _, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "erase frame must not fall back")
	testing.expect_value(t, flushed, 2)
	testing.expect(t, d.mirror[0] == instance.Instance_Data{}, "emptied bg slot must be zeroed (no ghost)")
	testing.expect(t, d.mirror[DIRTY_TEST_N] == instance.Instance_Data{}, "emptied glyph slot must be zeroed (no ghost)")
	testing.expect(t, render.dirty_upload_validate_mirror(&d, &r), "glyph-to-empty update must keep mirror valid")
}

@(test)
test_dirty_upload_overlapping_spans_merge :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	termgrid.damage_mark_span(&term.damage, 0, 1, 3, 0)
	termgrid.damage_mark_span(&term.damage, 0, 2, 5, 0)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, _, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "overlap frame must not fall back")
	testing.expect_value(t, flushed, 2)
}

@(test)
test_dirty_upload_full_row_extents :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	termgrid.damage_mark_row(&term.damage, 1, 0)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, _, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "full-row frame must not fall back")
	testing.expect_value(t, flushed, 2)
	testing.expect_value(t, ranges[0].offset, u64(1 * DIRTY_TEST_COLS) * instance.INSTANCE_STRIDE)
	testing.expect_value(t, ranges[0].size, u64(DIRTY_TEST_COLS) * instance.INSTANCE_STRIDE)
	testing.expect_value(t, ranges[1].offset, u64(DIRTY_TEST_N + 1 * DIRTY_TEST_COLS) * instance.INSTANCE_STRIDE)
	testing.expect_value(t, ranges[1].size, u64(DIRTY_TEST_COLS) * instance.INSTANCE_STRIDE)
}

@(test)
test_dirty_upload_orphan_continuation_widen :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()

	// Wide lead at (0,4) + continuation at (0,5). Baseline frame compiles
	// both; then only the continuation is re-marked, so widen must pull
	// the lead back in from the persistent frame.
	termgrid.grid_set_cell(&term.grid, 0, 4, termgrid.Semantic_Cell{content = 0x57, style = 0, width = 2, flags = .None})
	termgrid.grid_set_cell(&term.grid, 0, 5, termgrid.Semantic_Cell{content = 0, style = 0, width = 0, flags = .Wide_Continuation})
	termgrid.damage_mark_row(&term.damage, 0, 0)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	_, _, _ = _dirty_test_frame(&d, &r, &term, &lut, &ranges)

	termgrid.damage_mark_cell(&term.damage, 0, 5, 0)
	flushed, _, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "orphan frame must not fall back")
	testing.expect_value(t, flushed, 2)
	// Widen pulled the lead in: lead expanded, stray continuation zeroed.
	testing.expect(t, d.mirror[4] != instance.Instance_Data{}, "widened lead bg slot must be expanded")
	testing.expect(t, d.mirror[5] == instance.Instance_Data{}, "orphan continuation bg slot must stay degenerate")
	testing.expect(t, d.mirror[DIRTY_TEST_N+5] == instance.Instance_Data{}, "orphan continuation glyph slot must stay degenerate")
}

@(test)
test_dirty_upload_scroll_falls_back :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	termgrid.terminal_put_string(&term, "hi")
	termgrid.terminal_scroll_up(&term, 1)

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, fell_back, "scroll journal must fall back")
	testing.expect_value(t, flushed, 0)
	testing.expect_value(t, bytes, u64(0))
}

@(test)
test_dirty_upload_empty_journal :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(DIRTY_TEST_ROWS, DIRTY_TEST_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "empty journal must not fall back")
	testing.expect_value(t, flushed, 0)
	testing.expect_value(t, bytes, u64(0))
}

@(test)
test_dirty_upload_init_capacity_fallback :: proc(t: ^testing.T) {
	r: render.Renderer
	r.rows = 24
	r.cols = 80
	r.instances.max_instances = 100

	d: render.Dirty_Upload
	testing.expect(t, !render.dirty_upload_init(&d, &r), "2N > max_instances must refuse init")
	testing.expect(t, d.mirror == nil, "refused init must leave no mirror")
	testing.expect(t, !d.armed, "refused init must leave dirty disarmed")
}

@(test)
test_dirty_upload_scale_ratio :: proc(t: ^testing.T) {
	// Full-size grid: 1-cell upload must stay within one widened run and under 1% of fullscreen.
	SCALE_ROWS :: 24
	SCALE_COLS :: 80
	term: termgrid.Terminal
	termgrid.terminal_init(&term, SCALE_ROWS, SCALE_COLS)
	defer termgrid.terminal_destroy(&term)

	r := _dirty_test_renderer(SCALE_ROWS, SCALE_COLS)
	defer render.render_compiler_destroy_v2(&r.compiled_v2)

	d: render.Dirty_Upload
	testing.expect(t, render.dirty_upload_init(&d, &r), "dirty init must arm on 24x80")
	defer render.dirty_upload_destroy(&d)

	lut := _dirty_test_lut()
	termgrid.terminal_move_cursor(&term, 12, 40)
	termgrid.terminal_put_char(&term, 'Q')

	ranges: [render.DIRTY_UPLOAD_MAX_RANGES]render.Dirty_Upload_Range
	flushed, bytes, fell_back := _dirty_test_frame(&d, &r, &term, &lut, &ranges)
	testing.expect(t, !fell_back, "1-cell frame must not fall back")
	testing.expect_value(t, flushed, 2)
	testing.expect(t, bytes == u64(3 * 2) * instance.INSTANCE_STRIDE, "mid-grid 1-cell bytes must equal one widened run")
	fullscreen := u64(2 * SCALE_ROWS * SCALE_COLS) * instance.INSTANCE_STRIDE
	testing.expect(t, bytes * 100 < fullscreen, "1-cell bytes must be <1% of fullscreen bytes")
}

_dirty_test_atlas :: proc() -> render.Atlas {
	a: render.Atlas
	for i in 0..<render.ATLAS_SLOT_COUNT {
		a.slots[i].valid = true
	}
	return a
}

_dirty_test_lut :: proc() -> render.Style_LUT {
	table: termgrid.Style_Table
	termgrid.style_table_init(&table)
	lut: render.Style_LUT
	render.style_lut_rebuild(&lut, &table)
	return lut
}

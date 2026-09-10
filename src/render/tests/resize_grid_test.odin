package render_tests

// Langkah 13 renderer_resize_grid tests (nil backend, CPU-only):
// same-dims no-op (identity), grow/shrink realloc, degenerate safety,
// mark_all + disarm tail, GPU handles stay nil, terminal untouched,
// and a tracking-allocator no-leak sweep.

import "core:mem"
import "core:testing"
import render "../"
import gpu "../gpu"
import instance "../instance"
import tile "../tile"
import termgrid "../../terminal"

RESIZE_GRID_TEST_ROWS :: 4
RESIZE_GRID_TEST_COLS :: 8

// _resize_grid_test_renderer builds a CPU-only renderer with every
// dimension-dependent subsystem live: nil backend, valid frames,
// tile map, dirty mirror (armed), upload ring staging, instance staging.
_resize_grid_test_renderer :: proc(rows, cols: int) -> render.Renderer {
	r: render.Renderer
	r.rows = i32(rows)
	r.cols = i32(cols)
	r.cell_width = 8
	r.cell_height = 16
	r.format = gpu.Gpu_Format.BGRA8_Unorm
	r.instances.max_instances = render.RENDER_MAX_INSTANCES
	r.instances.instance_data = make([]instance.Instance_Data, r.instances.max_instances)
	render.render_compiler_init(&r.compiled, i32(rows), i32(cols))
	render.render_compiler_init_v2(&r.compiled_v2, i32(rows), i32(cols))
	tile.tile_map_init(&r.tile_map, i32(rows), i32(cols), tile.TILE_W_DEFAULT, tile.TILE_H_DEFAULT)
	render.dirty_upload_init(&r.dirty, &r)
	render.upload_ring_init(&r.upload_ring, nil, nil, nil, render.RENDER_UPLOAD_CAPACITY)
	return r
}

_resize_grid_test_destroy :: proc(r: ^render.Renderer) {
	render.upload_ring_destroy(&r.upload_ring)
	render.dirty_upload_destroy(&r.dirty)
	tile.tile_map_destroy(&r.tile_map)
	render.render_compiler_destroy_v2(&r.compiled_v2)
	render.render_compiler_destroy(&r.compiled)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
}

@(test)
test_resize_grid_same_dims_noop :: proc(t: ^testing.T) {
	r := _resize_grid_test_renderer(RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer _resize_grid_test_destroy(&r)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	compiled_ptr := raw_data(r.compiled.cells)
	v2_ptr := raw_data(r.compiled_v2.cells)
	mirror_ptr := raw_data(r.dirty.mirror)
	staging_ptr := raw_data(r.upload_ring.staging[0])
	inst_ptr := raw_data(r.instances.instance_data)
	armed_before := r.dirty.armed

	render.renderer_resize_grid(&r, &term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)

	testing.expect(t, r.rows == RESIZE_GRID_TEST_ROWS && r.cols == RESIZE_GRID_TEST_COLS, "same dims must keep dims")
	testing.expect(t, raw_data(r.compiled.cells) == compiled_ptr, "same dims must not realloc compiled")
	testing.expect(t, raw_data(r.compiled_v2.cells) == v2_ptr, "same dims must not realloc compiled_v2")
	testing.expect(t, raw_data(r.dirty.mirror) == mirror_ptr, "same dims must not realloc dirty mirror")
	testing.expect(t, raw_data(r.upload_ring.staging[0]) == staging_ptr, "same dims must not realloc ring staging")
	testing.expect(t, raw_data(r.instances.instance_data) == inst_ptr, "same dims must not realloc instance staging")
	testing.expect(t, r.dirty.armed == armed_before, "same dims must not touch dirty arming")
}

@(test)
test_resize_grid_grow :: proc(t: ^testing.T) {
	r := _resize_grid_test_renderer(RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer _resize_grid_test_destroy(&r)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	render.renderer_resize_grid(&r, &term, 8, 16)

	testing.expect(t, r.rows == 8 && r.cols == 16, "grow must commit new dims")
	testing.expect(t, len(r.compiled.cells) == 128, "grow must realloc compiled to new N")
	testing.expect(t, len(r.compiled_v2.cells) == 128, "grow must realloc compiled_v2 to new N")
	testing.expect(t, len(r.dirty.mirror) == 256, "grow must realloc dirty mirror to 2N")
	testing.expect(t, r.tile_map.rows == 8 && r.tile_map.cols == 16, "grow must resize tile map")
	testing.expect(t, len(r.upload_ring.staging[0]) == int(render.RENDER_UPLOAD_CAPACITY), "grow must renew ring staging")
	testing.expect(t, len(r.instances.instance_data) == int(r.instances.max_instances), "grow must renew instance staging")
	testing.expect(t, !r.dirty.armed, "grow must disarm dirty for a full rebase next frame")
	testing.expect_value(t, r.tile_map.count, int(r.tile_map.tiles_x) * int(r.tile_map.tiles_y))
	testing.expect(t, rawptr(r.dirty.buffer) == nil, "nil backend must leave dirty GPU buffer nil")
	testing.expect(t, rawptr(r.upload_ring.buffers[0]) == nil, "nil backend must leave ring GPU buffers nil")
	testing.expect(t, !r.compute_tiles.available, "nil backend must leave compute unavailable")
	testing.expect(t, !r.fullscreen.available, "nil backend must leave fullscreen unavailable")
	testing.expect(t, term.grid.row_count == RESIZE_GRID_TEST_ROWS && term.grid.col_count == RESIZE_GRID_TEST_COLS, "terminal grid must be untouched")
}

@(test)
test_resize_grid_shrink :: proc(t: ^testing.T) {
	r := _resize_grid_test_renderer(8, 16)
	defer _resize_grid_test_destroy(&r)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	render.renderer_resize_grid(&r, &term, 2, 4)

	testing.expect(t, r.rows == 2 && r.cols == 4, "shrink must commit new dims")
	testing.expect(t, len(r.compiled.cells) == 8, "shrink must realloc compiled to new N")
	testing.expect(t, len(r.compiled_v2.cells) == 8, "shrink must realloc compiled_v2 to new N")
	testing.expect(t, len(r.dirty.mirror) == 16, "shrink must realloc dirty mirror to 2N")
	testing.expect(t, r.tile_map.rows == 2 && r.tile_map.cols == 4, "shrink must resize tile map")
	testing.expect(t, !r.dirty.armed, "shrink must disarm dirty for a full rebase next frame")
	testing.expect_value(t, r.tile_map.count, int(r.tile_map.tiles_x) * int(r.tile_map.tiles_y))
}

@(test)
test_resize_grid_degenerate :: proc(t: ^testing.T) {
	r := _resize_grid_test_renderer(RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer _resize_grid_test_destroy(&r)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	compiled_ptr := raw_data(r.compiled.cells)
	mirror_ptr := raw_data(r.dirty.mirror)

	render.renderer_resize_grid(&r, &term, 0, 8)
	render.renderer_resize_grid(&r, &term, 4, 0)
	render.renderer_resize_grid(&r, &term, 0, 0)
	render.renderer_resize_grid(&r, &term, -1, 8)
	render.renderer_resize_grid(&r, &term, 4, -2)
	render.renderer_resize_grid(nil, nil, 8, 16)

	testing.expect(t, r.rows == RESIZE_GRID_TEST_ROWS && r.cols == RESIZE_GRID_TEST_COLS, "degenerate must keep dims")
	testing.expect(t, len(r.compiled.cells) == RESIZE_GRID_TEST_ROWS * RESIZE_GRID_TEST_COLS, "degenerate must keep compiled N")
	testing.expect(t, raw_data(r.compiled.cells) == compiled_ptr, "degenerate must not realloc compiled")
	testing.expect(t, raw_data(r.dirty.mirror) == mirror_ptr, "degenerate must not realloc dirty mirror")
}

@(test)
test_resize_grid_disarm_and_mark :: proc(t: ^testing.T) {
	r := _resize_grid_test_renderer(RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer _resize_grid_test_destroy(&r)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	testing.expect(t, r.dirty.armed, "dirty must be armed after init")

	render.renderer_resize_grid(&r, &term, 6, 10)

	testing.expect(t, !r.dirty.armed, "resize must disarm dirty to force a full rebase next frame")
	testing.expect_value(t, r.tile_map.count, int(r.tile_map.tiles_x) * int(r.tile_map.tiles_y))
}

@(test)
test_resize_grid_no_leak :: proc(t: ^testing.T) {
	default_alloc := context.allocator
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, default_alloc)
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = default_alloc
	defer mem.tracking_allocator_destroy(&track)

	r := _resize_grid_test_renderer(RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, RESIZE_GRID_TEST_ROWS, RESIZE_GRID_TEST_COLS)

	render.renderer_resize_grid(&r, &term, 8, 16)
	render.renderer_resize_grid(&r, &term, 2, 4)
	render.renderer_resize_grid(&r, &term, 2, 4)

	termgrid.terminal_destroy(&term)
	_resize_grid_test_destroy(&r)

	leaked := len(track.allocation_map)
	testing.expect_value(t, leaked, 0)
}

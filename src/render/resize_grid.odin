package render

// renderer_resize_grid reallocates all dimension-dependent renderer state
// for a new grid size. Surface reconfigure is NOT here: renderer_resize
// keeps the pixel duties. App-side caller order:
//
//   terminal_resize(t, rows, cols)          // step 6: reflow grid, preservasi isi
//   renderer_resize_grid(r, t, rows, cols)  // this proc: renderer state
//   renderer_resize(r, width_px, height_px) // pixel duties + surface reconfigure
//   pty_set_winsize(master, rows, cols)     // step 4: winsize to the child
//
// terminal_resize is the caller's job; this proc never touches Terminal
// (the t param is accepted for call-site symmetry and ignored).
//
// Structural allocation order (Odin make panics on OOM, so there is no
// mid-way failure return; the order still minimizes exposure):
//   1. compiled frames are built into temporaries first; the old backing
//      is freed only after the new backing exists.
//   2. tile_map / compute / fullscreen resize in place and preserve the
//      old state internally when the new geometry is invalid or a GPU
//      recreation fails (nil backend stays nil, never crashes).
//   3. r.rows/r.cols commit, then the dirty mirror, upload ring, and
//      instance staging rebuild against the committed dims.
// Tail: tile_map_mark_all + dirty.armed = false force a full rebase on
// the next frame (the dirty path rebases when disarmed; scroll takes the
// legacy full path which also disarms).
import "base:runtime"
import fullscreen "fullscreen"
import gpu "gpu"
import instance "instance"
import tile "tile"
import termgrid "../terminal"

// renderer_resize_grid reallocates renderer grid state to rows x cols.
// Same dims is a cheap early-out (nothing reallocated). Degenerate
// (<= 0) dims return safely with no change.
renderer_resize_grid :: proc(r: ^Renderer, t: ^termgrid.Terminal, rows: i32, cols: i32, allocator: runtime.Allocator = context.allocator) {
	_ = t
	if r == nil {
		return
	}
	if rows <= 0 || cols <= 0 {
		return
	}
	if rows == r.rows && cols == r.cols {
		return
	}
	if !_renderer_wait_for_gpu(r) {
		return
	}

	// 1. Compiled frames: allocate new backing before freeing old.
	new_compiled: Compiled_Frame
	render_compiler_init(&new_compiled, rows, cols, allocator)
	new_compiled_v2: Compiled_Frame_V2
	render_compiler_init_v2(&new_compiled_v2, rows, cols, allocator)

	// 2. Tile map: resize preserves the old map on invalid/over-cap
	// geometry. A never-initialized map (tile_w/h == 0) falls back to
	// the default tile extents.
	tw := r.tile_map.tile_w
	th := r.tile_map.tile_h
	if tw == 0 || th == 0 {
		tw = tile.TILE_W_DEFAULT
		th = tile.TILE_H_DEFAULT
	}
	tile.tile_map_resize(&r.tile_map, rows, cols, tw, th, allocator)

	// 3. Commit dims + compiled frames; dependents below read the new dims.
	r.rows = rows
	r.cols = cols
	render_compiler_destroy(&r.compiled, allocator)
	r.compiled = new_compiled
	render_compiler_destroy_v2(&r.compiled_v2, allocator)
	r.compiled_v2 = new_compiled_v2

	// 4. Compute + fullscreen cell buffers. Nil backend (CPU-only) returns
	// false with old state intact; mirror renderer_resize and drop
	// availability so frames keep the instance fallback.
	if r.compute_tiles.available {
		if !tile.compute_tile_resize(&r.compute_tiles, rows, cols, r.cell_width, r.cell_height, r.pad_x, r.pad_y, r.screen_w, r.screen_h, r.format) {
			r.compute_tiles.available = false
		}
	}
	if r.fullscreen.available {
		if !fullscreen.fullscreen_resize(&r.fullscreen, rows, cols, r.cell_width, r.cell_height, r.pad_x, r.pad_y, r.format) {
			r.fullscreen.available = false
		}
	}

	// 5. Dirty mirror: rebuild against the committed dims (rebase + arm
	// inside init; nil backend skips GPU creation for CPU-only use).
	// Oversize grids (2N > max_instances) refuse init and stay disarmed.
	if rawptr(r.dirty.buffer) != nil && r.backend != nil {
		r.backend.destroy_buffer(r.dirty.buffer)
		r.dirty.buffer = gpu.Gpu_Buffer(nil)
	}
	dirty_upload_destroy(&r.dirty, allocator)
	dirty_upload_init(&r.dirty, r, allocator)

	// 6. Upload ring: same per-slot capacity, fresh staging + buffers.
	upload_ring_destroy(&r.upload_ring, allocator)
	upload_ring_init(&r.upload_ring, r.backend, r.device, r.queue, RENDER_UPLOAD_CAPACITY, allocator)

	// 7. Instance staging: draw capacity, not grid capacity, so the length
	// (max_instances) is kept; the backing is renewed to drop stale pixels.
	if r.instances.max_instances > 0 {
		if r.instances.instance_data != nil {
			delete(r.instances.instance_data, allocator)
			r.instances.instance_data = nil
		}
		r.instances.instance_data = make([]instance.Instance_Data, r.instances.max_instances, allocator)
	}

	// Tail: full rewrite next frame.
	tile.tile_map_mark_all(&r.tile_map)
	r.dirty.armed = false
	r.first_frame_pending = false
	r.full_redraw_pending = true
}

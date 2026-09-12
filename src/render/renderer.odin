package render

// Top-level renderer: orchestrates the full render pipeline.
//
// Pipeline per frame:
//   1. Take damage journal from terminal
//   2. Compile full grid → packed render cells
//   3. Prepare instance data (bg + glyph instances)
//   4. Upload instance data via triple-buffered ring
//   5. Encode render commands (2-pass: bg + glyph)
//   6. Compose the staged cursor into the acquired surface, if present
//   7. Submit to GPU and present exactly once
//
// Static scene optimization: if no damage, skip the frame entirely (~0μs).
// The cursor never acquires or presents a surface independently.

import "base:runtime"
import "core:mem"
import "../platform"
import fullscreen "fullscreen"
import "gpu"
import instance "instance"
import tile "tile"
import termgrid "../terminal"

BG_WGSL :: #load("shaders/bg.wgsl")
GLYPH_WGSL :: #load("shaders/glyph.wgsl")

// Render_Strategy selects the frame path. Instance is the zero value and the
// default; Compute_Tiles routes renderer_frame_compute through the tiled
// compute sibling path with per-frame instance fallback; Fullscreen routes
// renderer_frame_fullscreen through the fullscreen fragment sibling path
// with per-frame instance fallback.
Render_Strategy :: enum int {
	Instance,
	Compute_Tiles,
	Fullscreen,
}

// Render_Frame_State tracks the publication transaction. A frame can only
// reach Presented after encode and submit succeed, and every acquired surface
// reaches Released exactly once.
Render_Frame_State :: enum int {
	Idle,
	Acquired,
	Encoded,
	Submitted,
	Presented,
	Released,
	Aborted,
}

// Render_Frame_Transaction owns one acquired surface and one shared encoder.
// cursor_buffer/cursor_offset identify the optional cursor instance appended
// to the same upload-ring submission as legacy instance data.
Render_Frame_Transaction :: struct {
	state:         Render_Frame_State,
	texture:       gpu.Gpu_Texture,
	view:          gpu.Gpu_TextureView,
	format:        gpu.Gpu_Format,
	encoder:       gpu.Gpu_CommandEncoder,
	pass:          gpu.Gpu_RenderPassEncoder,
	cursor_buffer: gpu.Gpu_Buffer,
	cursor_offset: u64,
	upload:        Upload_Ring_Frame,
	upload_committed: bool,
	command_buffer: rawptr,
	encoder_released: bool,
	command_released: bool,
}

// Renderer is the top-level render state.
Renderer :: struct {
	// Sub-systems
	atlas:      Atlas,
	compiled:   Compiled_Frame,
	compiled_v2: Compiled_Frame_V2,
	dirty:      Dirty_Upload,
	style_lut:  Style_LUT,
	upload_ring: Upload_Ring,
	instances:  instance.Instance_Renderer,
	rasterizer: Font_Rasterizer,

	// Phase 11: fallback chain (slot 0 aliases rasterizer), shape cache,
	// and slow-path counters.
	fallback:          Fallback_Chain,
	shape_cache:       Shape_Cache,
	fallback_counters: Fallback_Counters,

	// Phase 12: async raster queue (single worker) and its counters.
	raster:          Raster_Queue,
	raster_counters: Raster_Counters,

	// Configuration
	rows:       i32,
	cols:       i32,
	cell_width:  f32,
	cell_height: f32,
	pad_x:       f32,
	pad_y:       f32,
	screen_w:   f32,
	screen_h:   f32,
	format:     gpu.Gpu_Format,
	theme:      termgrid.Theme,

	// Surface
	surface:    gpu.Gpu_Surface,
	surface_w:  u32,
	surface_h:  u32,

	// State
	frame_count:     u64,
	last_dirty:      bool,  // whether the last frame had damage
	frame_prepared:  bool,
	cursor_staged: bool, // cursor_overlay_draw staged the reserved instance
	device:        gpu.Gpu_Device,
	queue:       gpu.Gpu_Queue,
	backend:     ^gpu.Gpu_Backend_VTable,

	// Phase 14: tiled compute sibling path (instance stays default).
	strategy:      Render_Strategy,
	compute_tiles: tile.Compute_Tile_Renderer,
	tile_map:      tile.Tile_Map,

	// Phase 15: fullscreen fragment sibling path (instance stays default).
	fullscreen: fullscreen.Fullscreen_Renderer,

	// Phase 16: adaptive strategy state (online submit-ns rings + pin).
	strategy_state: Strategy_State,
	fallback_pending: bool,
	first_frame_pending: bool,
	full_redraw_pending: bool,
	last_view:           ^termgrid.Terminal_View,
	last_view_fingerprint: u64,
	last_view_valid:     bool,
}

// RENDER_MAX_INSTANCES is the maximum number of instances per draw call.
RENDER_MAX_INSTANCES :: 16384

// RENDER_UPLOAD_CAPACITY is the bytes per upload ring slot.
RENDER_UPLOAD_CAPACITY :: 1024 * 1024 // 1 MB

// renderer_init creates and initializes the renderer.
renderer_init :: proc(
	r: ^Renderer,
	font_path: string,
	pixel_size: f32,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
	rows, cols: i32,
	cell_width, cell_height: f32,
	screen_w, screen_h: f32,
	format: gpu.Gpu_Format,
	fallback_paths: []string = nil,
	allocator: runtime.Allocator = context.allocator,
	theme: termgrid.Theme = termgrid.THEME_CATPPUCCIN_MOCHA,
) -> bool {
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return false
	}
	r.rows = rows
	r.cols = cols
	r.cell_width  = cell_width
	r.cell_height = cell_height
	r.pad_x       = 6.0
	r.pad_y       = 4.0
	r.screen_w    = screen_w
	r.screen_h    = screen_h
	r.format      = format
	r.theme       = theme
	r.device      = device
	r.queue       = queue
	r.backend     = backend
	r.frame_count = 0
	r.last_dirty  = true
	r.surface     = gpu.Gpu_Surface(nil)
	r.surface_w   = 0
	r.surface_h   = 0
	r.first_frame_pending = true
	r.full_redraw_pending = false

	// Initialize font rasterizer
	font_error: Font_Error
	if !font_rasterizer_init(&r.rasterizer, font_path, pixel_size, &font_error, allocator) {
		return false
	}

	if r.cell_width <= 0 && r.rasterizer.metrics.cell_width > 0 {
		r.cell_width = r.rasterizer.metrics.cell_width
	}
	if r.cell_height <= 0 && r.rasterizer.metrics.cell_height > 0 {
		r.cell_height = r.rasterizer.metrics.cell_height
	}

	// Initialize font atlas (prewarms pinned glyphs)
	atlas_init(&r.atlas, &r.rasterizer, allocator)

	// Phase 11: fallback chain aliases the primary, then pinned slots the
	// primary left invalid are filled through the chain. pinned_count ends
	// as the total valid pinned count (per-font hits).
	r.shape_cache = Shape_Cache{}
	r.fallback_counters = Fallback_Counters{}
	fallback_chain_init(&r.fallback, &r.rasterizer, fallback_paths, pixel_size, allocator)
	atlas_prewarm_chain(&r.atlas, &r.fallback)
	// Phase 18: one-time pin audit after the prewarm-chain fill (never per-frame).
	atlas_pin_audit(&r.atlas, &r.fallback)

	// Upload atlas to GPU
	atlas_upload_gpu(&r.atlas, backend, device, queue)

	// Initialize compiled frame buffer
	render_compiler_init(&r.compiled, rows, cols, allocator)

	// Initialize V2 compiled frame buffer + style LUT (LUT rebuilds on first v2 frame)
	render_compiler_init_v2(&r.compiled_v2, rows, cols, allocator)
	r.style_lut.count = 0

	// Initialize instance renderer with atlas GPU resources
	ok := instance.instance_renderer_init(
		&r.instances,
		backend,
		device,
		queue,
		RENDER_MAX_INSTANCES,
		r.atlas.gpu_texture,
		r.atlas.gpu_view,
		format,
		string(BG_WGSL),
		string(GLYPH_WGSL),
		screen_w,
		screen_h,
		allocator,
	)
	if !ok {
		renderer_destroy(r, allocator)
		return false
	}

	// Phase 8: persistent dirty-upload buffer; the upload ring is retained
	// as the legacy-fallback carrier and is always initialized so the
	// fallback path has valid buffers.
	dirty_upload_init(&r.dirty, r, allocator)
	upload_ring_init(&r.upload_ring, backend, device, queue, RENDER_UPLOAD_CAPACITY, allocator)

	// Phase 12: async raster queue, worker start LAST (after the chain the
	// worker reads and every other subsystem is ready).
	raster_queue_init(&r.raster, &r.raster_counters)
	raster_worker_start(&r.raster, &r.fallback)
	return true
}

// renderer_destroy frees all renderer resources.
renderer_destroy :: proc(r: ^Renderer, allocator: runtime.Allocator = context.allocator) {
	if r == nil { return }
	// No GPU-owned resource may be destroyed while a submitted frame can still
	// reference it. The concrete backend supplies the verified barrier.
	if !_renderer_wait_for_gpu(r) { return }
	// Phase 12 first: join the worker, apply every pending completion to
	// the atlas (no loss), then free the queue — before the atlas, chain,
	// and cache below are torn down.
	raster_worker_shutdown(&r.raster)
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, nil, &r.fallback, &r.fallback_counters)
	raster_queue_destroy(&r.raster, allocator)

	atlas_destroy(&r.atlas, allocator)
	render_compiler_destroy(&r.compiled, allocator)
	render_compiler_destroy_v2(&r.compiled_v2, allocator)
	if rawptr(r.dirty.buffer) != nil && r.backend != nil {
		r.backend.destroy_buffer(r.dirty.buffer)
		r.dirty.buffer = gpu.Gpu_Buffer(nil)
	}
	dirty_upload_destroy(&r.dirty, allocator)
	upload_ring_destroy(&r.upload_ring, allocator)
	instance.instance_renderer_destroy(&r.instances, allocator)

	// Optional sibling renderers are not initialized by the production path;
	// their destroy routines remain nil-safe for benchmark/test instances.
	if r.compute_tiles.available || r.compute_tiles.backend != nil {
		tile.compute_tile_destroy(&r.compute_tiles)
	}
	if r.tile_map.bits != nil {
		tile.tile_map_destroy(&r.tile_map, allocator)
	}
	if r.fullscreen.available || r.fullscreen.backend != nil {
		fullscreen.fullscreen_destroy(&r.fullscreen)
	}

	// Free fallback fonts (slots 1..; slot 0 aliases the rasterizer below)
	fallback_chain_destroy(&r.fallback)

	// Free rasterizer resources
	font_rasterizer_destroy(&r.rasterizer)
}

// renderer_rebuild_font builds a complete font-dependent renderer candidate
// before changing the live renderer. The candidate worker is stopped and its
// queue is reinitialized before its state moves into the live address, so no
// worker retains a pointer to the temporary candidate.
renderer_rebuild_font :: proc(
	r: ^Renderer,
	font_path: string,
	pixel_size: f32,
	fallback_paths: []string = nil,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	if !_renderer_wait_for_gpu(r) {
		return false
	}

	candidate_storage := make([]Renderer, 1, allocator)
	defer delete(candidate_storage)
	candidate := &candidate_storage[0]
	if !renderer_init(
		candidate,
		font_path,
		pixel_size,
		r.backend,
		r.device,
		r.queue,
		r.rows,
		r.cols,
		r.cell_width,
		r.cell_height,
		r.screen_w,
		r.screen_h,
		r.format,
		fallback_paths,
		allocator,
		r.theme,
	) {
		renderer_destroy(candidate, allocator)
		return false
	}
	if candidate.rasterizer.metrics.cell_width > 0 {
		candidate.cell_width = candidate.rasterizer.metrics.cell_width
	}
	if candidate.rasterizer.metrics.cell_height > 0 {
		candidate.cell_height = candidate.rasterizer.metrics.cell_height
	}

	// The worker context points into candidate. Stop it before moving the queue,
	// then rebuild the empty queue in place so the new worker can use live state.
	raster_worker_shutdown(&candidate.raster)
	raster_queue_init(&candidate.raster, &candidate.raster_counters)

	// Stop the old worker while its queue still lives at the renderer address,
	// and apply any completion it produced before ownership is moved.
	raster_worker_shutdown(&r.raster)
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, nil, &r.fallback, &r.fallback_counters)

	old_storage := make([]Renderer, 1, allocator)
	defer delete(old_storage)
	old := &old_storage[0]
	old.atlas = r.atlas
	old.compiled = r.compiled
	old.compiled_v2 = r.compiled_v2
	old.dirty = r.dirty
	old.upload_ring = r.upload_ring
	old.instances = r.instances
	old.rasterizer = r.rasterizer
	old.fallback = r.fallback
	old.shape_cache = r.shape_cache
	old.fallback_counters = r.fallback_counters
	old.raster = r.raster
	old.raster_counters = r.raster_counters
	old.backend = r.backend
	old.device = r.device
	old.queue = r.queue

	new_cell_width := candidate.cell_width
	new_cell_height := candidate.cell_height
	r.atlas = candidate.atlas
	r.compiled = candidate.compiled
	r.compiled_v2 = candidate.compiled_v2
	r.dirty = candidate.dirty
	r.style_lut = candidate.style_lut
	r.upload_ring = candidate.upload_ring
	r.instances = candidate.instances
	r.rasterizer = candidate.rasterizer
	r.fallback = candidate.fallback
	r.shape_cache = candidate.shape_cache
	r.fallback_counters = candidate.fallback_counters
	r.raster = candidate.raster
	r.raster_counters = candidate.raster_counters
	r.cell_width = new_cell_width
	r.cell_height = new_cell_height
	r.raster.counters = &r.raster_counters
	r.dirty.armed = false

	// Candidate ownership is now live; prevent any accidental cleanup of moved
	// fields if this scope grows a candidate cleanup path later.
	candidate.atlas = Atlas{}
	candidate.compiled = Compiled_Frame{}
	candidate.compiled_v2 = Compiled_Frame_V2{}
	candidate.dirty = Dirty_Upload{}
	candidate.upload_ring = Upload_Ring{}
	candidate.instances = instance.Instance_Renderer{}
	candidate.rasterizer = Font_Rasterizer{}
	candidate.fallback = Fallback_Chain{}
	candidate.raster = Raster_Queue{}

	raster_worker_start(&r.raster, &r.fallback)
	renderer_destroy(old, allocator)
	r.full_redraw_pending = true
	return true
}

// renderer_attach_surface configures the surface for presentation.
renderer_attach_surface :: proc(r: ^Renderer, surface: gpu.Gpu_Surface, width: u32, height: u32) {
	r.surface = surface
	r.surface_w = width
	r.surface_h = height
	if width == 0 || height == 0 {
		return
	}
	if r.backend == nil || rawptr(r.device) == nil {
		return
	}
	r.backend.configure_surface(rawptr(surface), r.device, r.format, width, height)
}

// renderer_frame keeps the original entry point while using the transaction
// path and the renderer-owned style LUT.
renderer_frame :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	view: ^termgrid.Terminal_View = nil,
) -> bool {
	if r == nil { return false }
	return renderer_frame_v2(r, terminal, nil, &r.style_lut, view)
}

_renderer_journal_has_damage :: proc(journal: ^termgrid.Damage_Journal) -> bool {
	if journal == nil { return false }
	for row in journal.dirty_rows {
		if row.full || row.span_count > 0 { return true }
	}
	return len(journal.scroll_ops) > 0
}

_renderer_view_fingerprint :: proc(view: ^termgrid.Terminal_View) -> u64 {
	if view == nil {
		return 0
	}
	h := u64(14695981039346656037)
	mix :: proc(value: u64, part: u64) -> u64 {
		return (value ~ part) * u64(1099511628211)
	}
	h = mix(h, u64(view.scrollback_offset))
	h = mix(h, view.selection.active ? u64(1) : u64(0))
	h = mix(h, u64(view.selection.anchor.row))
	h = mix(h, u64(view.selection.anchor.col))
	h = mix(h, u64(view.selection.focus.row))
	h = mix(h, u64(view.selection.focus.col))
	return h
}

_renderer_view_changed :: proc(r: ^Renderer, view: ^termgrid.Terminal_View) -> bool {
	if r == nil {
		return true
	}
	if view == nil {
		// Legacy nil-view frames are not pending merely because no view has
		// been published yet. A transition out of a previously rendered view
		// still needs one complete live-grid redraw.
		return r.last_view_valid && r.last_view != nil
	}
	fingerprint := _renderer_view_fingerprint(view)
	return !r.last_view_valid || r.last_view != view || r.last_view_fingerprint != fingerprint
}

_style_lut_needs_rebuild :: proc(lut: ^Style_LUT, table: ^termgrid.Style_Table) -> bool {
	if lut == nil || table == nil {
		return false
	}
	if lut.count != table.count {
		return true
	}
	default_style := termgrid.style_table_default(table)
	return lut.fg_r5g6b5[0] != color_to_r5g6b5(default_style.fg) ||
		lut.bg_r5g6b5[0] != color_to_r5g6b5(default_style.bg) ||
		lut.selection_fg_r5g6b5 != color_to_r5g6b5(table.theme.selection_foreground) ||
		lut.selection_bg_r5g6b5 != color_to_r5g6b5(table.theme.selection_background)
}

_renderer_theme_clear_color :: proc(theme: termgrid.Theme) -> [4]f64 {
	argb := theme.background
	return [4]f64{
		f64((argb >> 16) & 0xFF) / 255.0,
		f64((argb >> 8) & 0xFF) / 255.0,
		f64(argb & 0xFF) / 255.0,
		f64((argb >> 24) & 0xFF) / 255.0,
	}
}

// _renderer_wait_for_gpu is the publication barrier for CPU-side resource
// mutation. A live backend must provide a verified queue-idle primitive;
// otherwise the renderer refuses to touch resources whose ownership is
// unknown.
_renderer_wait_for_gpu :: proc(r: ^Renderer) -> bool {
	if r == nil || r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return true
	}
	if r.backend.wait_for_idle == nil {
		return false
	}
	return r.backend.wait_for_idle(r.device)
}

_renderer_force_pending_redraw :: proc(r: ^Renderer, terminal: ^termgrid.Terminal) {
	if r == nil || terminal == nil || (!r.first_frame_pending && !r.full_redraw_pending) {
		return
	}
	gens := make([]u32, terminal.grid.row_count)
	for row in 0..<terminal.grid.row_count {
		gens[row] = termgrid.terminal_damage_target(terminal, row, 0).row_generation
	}
	termgrid.damage_mark_all(&terminal.damage, gens)
	delete(gens)
}

// _renderer_has_pending_work checks only state that can make a frame useful.
// It does not drain queues, acquire a surface, or wait for the GPU.
_renderer_has_pending_work :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	view: ^termgrid.Terminal_View = nil,
) -> bool {
	if r == nil || terminal == nil {
		return false
	}
	if r.first_frame_pending || r.full_redraw_pending || r.atlas.gpu_dirty || r.fallback_pending ||
		_renderer_view_changed(r, view) {
		return true
	}
	for row in terminal.damage.dirty_rows {
		if row.full || row.span_count > 0 {
			return true
		}
	}
	if len(terminal.damage.scroll_ops) > 0 {
		return true
	}
	reqs, comps := raster_pending_count(&r.raster)
	return reqs > 0 || comps > 0
}

_renderer_surface_begin :: proc(r: ^Renderer) -> (frame: Render_Frame_Transaction, ok: bool) {
	frame.state = .Idle
	if r == nil || r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || rawptr(r.surface) == nil {
		frame.state = .Aborted
		return frame, false
	}
	texture, view, format := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(texture) == nil || rawptr(view) == nil ||
		(format != .Undefined && r.format != .Undefined && format != r.format) {
		if rawptr(texture) != nil || rawptr(view) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		frame.state = .Aborted
		return frame, false
	}
	encoder := r.backend.create_command_encoder(r.device)
	if rawptr(encoder) == nil {
		r.backend.release_surface_texture(texture, view)
		frame.state = .Aborted
		return frame, false
	}
	frame.texture = texture
	frame.view = view
	frame.format = format
	frame.encoder = encoder
	frame.state = .Acquired
	return frame, true
}

_renderer_surface_abort :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction) {
	if frame == nil || frame.state == .Released || frame.state == .Aborted {
		return
	}
	if r != nil && r.backend != nil && !frame.command_released && frame.command_buffer != nil {
		r.backend.release_command_buffer(frame.command_buffer)
		frame.command_buffer = nil
		frame.command_released = true
	}
	if r != nil && r.backend != nil && !frame.encoder_released && rawptr(frame.encoder) != nil {
		r.backend.release_command_encoder(frame.encoder)
		frame.encoder = gpu.Gpu_CommandEncoder(nil)
		frame.encoder_released = true
	}
	if r != nil && r.backend != nil && !frame.upload_committed && frame.upload.reserved {
		upload_ring_abort(&r.upload_ring, &frame.upload)
	}
	if r != nil && r.backend != nil && (rawptr(frame.texture) != nil || rawptr(frame.view) != nil) {
		r.backend.release_surface_texture(frame.texture, frame.view)
	}
	frame.texture = gpu.Gpu_Texture(nil)
	frame.view = gpu.Gpu_TextureView(nil)
	frame.state = .Aborted
}

_renderer_surface_commit :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction) -> bool {
	if r == nil || frame == nil || frame.state != .Encoded {
		_renderer_surface_abort(r, frame)
		return false
	}
	cmd := r.backend.finish_command_buffer(frame.encoder)
	r.backend.release_command_encoder(frame.encoder)
	frame.encoder = gpu.Gpu_CommandEncoder(nil)
	frame.encoder_released = true
	if cmd == nil {
		_renderer_surface_abort(r, frame)
		return false
	}
	frame.command_buffer = cmd
	if !r.backend.submit(r.queue, cmd) {
		r.backend.release_command_buffer(cmd)
		frame.command_buffer = nil
		frame.command_released = true
		_renderer_surface_abort(r, frame)
		return false
	}
	if frame.upload.reserved && !frame.upload_committed {
		upload_ring_commit(&r.upload_ring, &frame.upload)
		frame.upload_committed = true
	}
	r.backend.release_command_buffer(cmd)
	frame.command_buffer = nil
	frame.command_released = true
	frame.state = .Submitted
	if !r.backend.present_surface(rawptr(r.surface)) {
		_renderer_surface_abort(r, frame)
		return false
	}
	frame.state = .Presented
	r.backend.release_surface_texture(frame.texture, frame.view)
	frame.texture = gpu.Gpu_Texture(nil)
	frame.view = gpu.Gpu_TextureView(nil)
	frame.state = .Released
	return true
}

_renderer_upload_instances :: proc(r: ^Renderer, base_count: u32, frame: ^Render_Frame_Transaction) -> bool {
	if r == nil || frame == nil { return false }
	count := u64(base_count)
	cursor_count: u64 = 0
	if r.cursor_staged { cursor_count = 1 }
	total := count + cursor_count
	byte_count := total * instance.INSTANCE_STRIDE
	upload := upload_ring_begin(&r.upload_ring)
	if !upload.reserved { return false }
	frame.upload = upload
	staging := upload_ring_get_staging(&r.upload_ring, upload)
	if byte_count > u64(len(staging)) || count > u64(len(r.instances.instance_data)) {
		upload_ring_abort(&r.upload_ring, &frame.upload)
		return false
	}
	if count > 0 {
		mem.copy(raw_data(staging[:int(count * instance.INSTANCE_STRIDE)]), raw_data(r.instances.instance_data), int(count * instance.INSTANCE_STRIDE))
	}
	frame.cursor_buffer = gpu.Gpu_Buffer(nil)
	frame.cursor_offset = 0
	if cursor_count > 0 {
		slot := r.instances.max_instances - 1
		if slot >= u32(len(r.instances.instance_data)) {
			upload_ring_abort(&r.upload_ring, &frame.upload)
			return false
		}
		offset := int(count * instance.INSTANCE_STRIDE)
		mem.copy(raw_data(staging[offset:]), &r.instances.instance_data[slot], int(instance.INSTANCE_STRIDE))
		frame.cursor_offset = u64(offset)
	}
	if !upload_ring_write(&r.upload_ring, &frame.upload, byte_count) {
		upload_ring_abort(&r.upload_ring, &frame.upload)
		return false
	}
	buffer := upload_ring_get_buffer(&r.upload_ring, frame.upload.slot)
	if rawptr(buffer) == nil && total > 0 { return false }
	frame.cursor_buffer = buffer
	return true
}

// _prepare_instances fills instance data from compiled cells.
_prepare_instances :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	style_table: ^termgrid.Style_Table,
) -> (bg_count: u32, glyph_count: u32) {
	cells := r.compiled.cells
	cols := r.cols
	cell_w := r.cell_width
	cell_h := r.cell_height
	atlas := &r.atlas
	inst := &r.instances

	bg_count = 0
	glyph_count = 0

	for idx in 0..<len(cells) {
		row := i32(idx) / cols
		col := i32(idx) % cols

		codepoint, fg_packed, bg_packed, flags := render_cell_unpack(cells[idx])

		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		// Skip fully empty cells (space with black background)
		if codepoint == 0x20 && bg_packed == 0x0000 {
			continue
		}

		// Background instance
		if bg_count < inst.max_instances {
			bg_r, bg_g, bg_b := instance.unpack_r5g6b5(bg_packed)
			instance.instance_renderer_fill_bg(inst, bg_count, x, y, cell_w, cell_h, bg_r, bg_g, bg_b)
			bg_count += 1
		}

		// Glyph instance (skip spaces)
		if codepoint != 0x20 && glyph_count < inst.max_instances {
			slot_idx, slot := atlas_get_slot(atlas, codepoint)
			fg_r, fg_g, fg_b := instance.unpack_r5g6b5(fg_packed)

			if slot.valid {
				glyph_idx := bg_count + glyph_count
				if glyph_idx < inst.max_instances {
					instance.instance_renderer_fill_glyph(
						inst, glyph_idx, x, y, cell_w, cell_h,
						slot.u0, slot.v0, slot.u1, slot.v1,
						fg_r, fg_g, fg_b,
					)
					glyph_count += 1
				}
			}
		}
	}

	return bg_count, glyph_count
}

// _prepare_instances_v2 fills instance data from V2 compiled cells via the
// pre-resolved Style_LUT. No per-cell style_table_get, color conversion, or atlas rasterize.
// Two passes partition the staging buffer as [bg 0..bg_count), [glyph bg_count..bg_count+glyph_count),
// matching the draw offsets below. Writes are capped at max_instances.
_prepare_instances_v2 :: proc(r: ^Renderer, lut: ^Style_LUT) -> (bg_count: u32, glyph_count: u32) {
	cells := r.compiled_v2.cells
	cols := r.cols
	cell_w := r.cell_width
	cell_h := r.cell_height
	atlas := &r.atlas
	inst := &r.instances

	bg_count = 0
	glyph_count = 0

	// Pass 1: backgrounds, densely packed from index 0.
	for idx in 0..<len(cells) {
		if bg_count >= inst.max_instances {
			break
		}
		row := i32(idx) / cols
		col := i32(idx) % cols
		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		emit_bg, _ := render_cell_expand_instance(
			cells[idx], lut, atlas, x, y, cell_w, cell_h,
			&inst.instance_data[bg_count], nil,
		)
		if emit_bg {
			bg_count += 1
		}
	}

	// Pass 2: glyphs, packed from index bg_count.
	for idx in 0..<len(cells) {
		glyph_idx := bg_count + glyph_count
		if glyph_idx >= inst.max_instances {
			break
		}
		row := i32(idx) / cols
		col := i32(idx) % cols
		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		_, emit_glyph := render_cell_expand_instance(
			cells[idx], lut, atlas, x, y, cell_w, cell_h,
			nil, &inst.instance_data[glyph_idx],
		)
		if emit_glyph {
			glyph_count += 1
		}
	}

	return bg_count, glyph_count
}

// _draw_cursor_overlay appends the staged cursor draw to the active instance
// render pass. It performs no upload, acquisition, submission, or present.
_draw_cursor_overlay :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction) -> bool {
	if r == nil || frame == nil || !r.cursor_staged { return true }
	if r.backend == nil || rawptr(frame.pass) == nil ||
		rawptr(r.instances.bg_pipeline) == nil || rawptr(r.instances.bind_group_bg) == nil ||
		rawptr(frame.cursor_buffer) == nil {
		return false
	}
	r.backend.render_set_pipeline(frame.pass, r.instances.bg_pipeline)
	r.backend.render_set_bind_group(frame.pass, 0, r.instances.bind_group_bg)
	r.backend.render_set_vertex_buffer(frame.pass, 0, frame.cursor_buffer, frame.cursor_offset)
	r.backend.render_draw(frame.pass, instance.QUAD_VERTEX_COUNT, 1)
	return true
}

_renderer_frame_published :: proc(r: ^Renderer, view: ^termgrid.Terminal_View = nil) {
	if r == nil { return }
	r.first_frame_pending = false
	r.full_redraw_pending = false
	r.cursor_staged = false
	r.last_view = view
	r.last_view_fingerprint = _renderer_view_fingerprint(view)
	r.last_view_valid = true
}

// _draw_instance_buffer encodes bg, glyph, and optional cursor draws into the
// transaction's single render pass. It does not finish, submit, present, or
// release the acquired surface.
_draw_instance_buffer :: proc(
	r: ^Renderer,
	frame: ^Render_Frame_Transaction,
	buffer: gpu.Gpu_Buffer,
	bg_count: u32,
	glyph_count: u32,
	glyph_offset: u64,
) -> bool {
	if r == nil || frame == nil || frame.state != .Acquired || rawptr(frame.encoder) == nil {
		return false
	}
	pass := r.backend.begin_render_pass(frame.encoder, frame.view, _renderer_theme_clear_color(r.theme), .Clear)
	if rawptr(pass) == nil { return false }
	frame.pass = pass
	ok := true
	if bg_count > 0 || glyph_count > 0 {
		ok = rawptr(buffer) != nil && rawptr(r.instances.bg_pipeline) != nil && rawptr(r.instances.glyph_pipeline) != nil &&
			rawptr(r.instances.bind_group_bg) != nil && rawptr(r.instances.bind_group_glyph) != nil
	}
	if ok {
		r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
		r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
		r.backend.render_set_vertex_buffer(pass, 0, buffer, 0)
		r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, bg_count)

		r.backend.render_set_pipeline(pass, r.instances.glyph_pipeline)
		r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_glyph)
		r.backend.render_set_vertex_buffer(pass, 0, buffer, glyph_offset)
		r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, glyph_count)
	}
	if ok { ok = _draw_cursor_overlay(r, frame) }
	r.backend.end_render_pass(pass)
	frame.pass = gpu.Gpu_RenderPassEncoder(nil)
	if !ok { return false }
	frame.state = .Encoded
	return true
}

// renderer_prepare_frame owns the single async completion drain and atlas
// upload for the current frame. The selected strategy consumes the prepared
// state without draining again.
renderer_prepare_frame :: proc(r: ^Renderer, terminal: ^termgrid.Terminal) -> bool {
	if r == nil || terminal == nil { return false }
	applied := raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, terminal, &r.fallback, &r.fallback_counters)
	atlas_changed := r.atlas.gpu_dirty
	if atlas_changed {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
		r.full_redraw_pending = true
	}
	if applied > 0 {
		r.full_redraw_pending = true
	}
	if applied > 0 && r.dirty.armed {
		r.dirty.armed = false
	}
	r.frame_prepared = true
	return applied > 0 || atlas_changed
}

_renderer_frame_failed :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	journal: ^termgrid.Damage_Journal,
	frame: ^Render_Frame_Transaction,
	strategy: Render_Strategy,
) -> bool {
	_renderer_surface_abort(r, frame)
	if terminal != nil && journal != nil {
		termgrid.damage_requeue_journal(&terminal.damage, journal)
	}
	if strategy != .Instance {
		r.fallback_pending = true
	}
	return false
}

// _renderer_frame_unavailable preserves the nil/CPU fallback and restores the
// consumed journal because no visible publication occurred.
_renderer_frame_unavailable :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, journal: ^termgrid.Damage_Journal, strategy: Render_Strategy) -> bool {
	if terminal != nil && journal != nil {
		termgrid.damage_requeue_journal(&terminal.damage, journal)
	}
	if strategy != .Instance {
		r.fallback_pending = true
	}
	return false
}

_renderer_frame_v2_journal :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	journal: ^termgrid.Damage_Journal,
	lut: ^Style_LUT,
	view: ^termgrid.Terminal_View = nil,
	view_changed: bool = false,
) -> bool {
	has_damage := _renderer_journal_has_damage(journal)
	force_full := view_changed || (view != nil && (view.scrollback_offset != 0 || view.selection.active)) || len(journal.scroll_ops) > 0
	if !has_damage && force_full {
		r.last_dirty = true
	} else if !has_damage && r.last_dirty {
		r.last_dirty = false
	} else if !has_damage {
		return false
	} else {
		r.last_dirty = true
	}
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil ||
		rawptr(r.instances.bg_pipeline) == nil || rawptr(r.instances.glyph_pipeline) == nil || lut == nil {
		return _renderer_frame_unavailable(r, terminal, journal, .Instance)
	}
	if _style_lut_needs_rebuild(lut, &terminal.grid.style_table) {
		style_lut_rebuild(lut, &terminal.grid.style_table)
	}

	if !force_full && len(journal.scroll_ops) == 0 && r.dirty.mirror != nil && !r.cursor_staged {
		if !r.dirty.armed {
			dirty_upload_rebase(&r.dirty, r, lut)
		}
		ranges: [DIRTY_UPLOAD_MAX_RANGES]Dirty_Upload_Range
		_, _, fell_back := dirty_upload_frame(&r.dirty, r, terminal, journal, lut, &ranges)
		if !fell_back {
			n := u32(int(r.rows) * int(r.cols))
			frame, ok := _renderer_surface_begin(r)
			if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Instance) }
			if !_draw_instance_buffer(r, &frame, r.dirty.buffer, n, n, u64(n) * instance.INSTANCE_STRIDE) {
				return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
			}
			if !_renderer_surface_commit(r, &frame) {
				return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
			}
			_renderer_frame_published(r)
			return true
		}
	}

	r.dirty.armed = false
	render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster, view)
	bg_count, glyph_count := _prepare_instances_v2(r, lut)
	frame, ok := _renderer_surface_begin(r)
	if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Instance) }
	if !_renderer_upload_instances(r, bg_count + glyph_count, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	if !_draw_instance_buffer(r, &frame, frame.cursor_buffer, bg_count, glyph_count, u64(bg_count) * instance.INSTANCE_STRIDE) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	if !_renderer_surface_commit(r, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	_renderer_frame_published(r, view)
	return true
}

// renderer_frame_v2 takes exactly one journal and delegates publication to
// the journal-owned transaction helper.
renderer_frame_v2 :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
	_: ^Compiled_Frame_V2,
	lut: ^Style_LUT,
	view: ^termgrid.Terminal_View = nil,
) -> bool {
	view_changed := _renderer_view_changed(r, view)
	if !_renderer_has_pending_work(r, terminal, view) {
		if r != nil { r.last_dirty = false }
		return false
	}
	if !r.frame_prepared { renderer_prepare_frame(r, terminal) }
	_renderer_force_pending_redraw(r, terminal)
	r.frame_prepared = false
	r.frame_count += 1
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)
	return _renderer_frame_v2_journal(r, terminal, &journal, lut, view, view_changed)
}

// renderer_set_strategy selects the frame path. Switching to Compute_Tiles
// marks all tiles so the next compute frame rebuilds the framebuffer.
// Fullscreen needs no mark (full upload every frame).
renderer_set_strategy :: proc(r: ^Renderer, s: Render_Strategy) {
	r.strategy = s
	r.strategy_state.pinned = false
	if s == .Compute_Tiles {
		tile.tile_map_mark_all(&r.tile_map)
	}
}

// _renderer_frame_compute_journal owns one journal and one shared encoder for
// dispatch, blit, optional cursor composition, and publication.
_renderer_frame_compute_journal :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, journal: ^termgrid.Damage_Journal, lut: ^Style_LUT) -> bool {
	if r.strategy != .Compute_Tiles || !r.compute_tiles.available || r.tile_map.bits == nil {
		return _renderer_frame_v2_journal(r, terminal, journal, lut)
	}
	if !_renderer_journal_has_damage(journal) {
		return false
	}
	r.last_dirty = true
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || lut == nil {
		return _renderer_frame_unavailable(r, terminal, journal, .Compute_Tiles)
	}
	lut_rebuilt := _style_lut_needs_rebuild(lut, &terminal.grid.style_table)
	if lut_rebuilt { style_lut_rebuild(lut, &terminal.grid.style_table) }
	tile.tile_map_clear(&r.tile_map)
	if len(journal.scroll_ops) > 0 {
		render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
		tile.tile_map_mark_all(&r.tile_map)
	} else {
		render_compile_v2(&r.compiled_v2, terminal, journal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
		count, _ := tile.tile_map_mark_damage(&r.tile_map, journal)
		if count == 0 {
			return _renderer_frame_failed(r, terminal, journal, nil, .Compute_Tiles)
		}
	}
	lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:tile.TILE_LUT_WORDS]
	_ = tile.compute_tile_upload_cells(&r.compute_tiles, &r.tile_map, r.compiled_v2.cells, lut_words, lut_rebuilt)
	frame, ok := _renderer_surface_begin(r)
	if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Compute_Tiles) }
	if r.cursor_staged && !_renderer_upload_instances(r, 0, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Compute_Tiles)
	}
	dispatches, _ := tile.compute_tile_dispatch(&r.compute_tiles, &r.tile_map, frame.encoder)
	if dispatches == 0 {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Compute_Tiles)
	}
	cursor_pipeline := gpu.Gpu_RenderPipeline(nil)
	cursor_bind_group := gpu.Gpu_BindGroup(nil)
	cursor_buffer := gpu.Gpu_Buffer(nil)
	cursor_offset: u64 = 0
	if r.cursor_staged {
		cursor_pipeline = r.instances.bg_pipeline
		cursor_bind_group = r.instances.bind_group_bg
		cursor_buffer = frame.cursor_buffer
		cursor_offset = frame.cursor_offset
	}
	if !tile.compute_tile_blit(&r.compute_tiles, frame.view, frame.encoder, cursor_pipeline, cursor_bind_group, cursor_buffer, cursor_offset) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Compute_Tiles)
	}
	frame.state = .Encoded
	if !_renderer_surface_commit(r, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Compute_Tiles)
	}
	_renderer_frame_published(r)
	tile.tile_map_clear(&r.tile_map)
	return true
}

// renderer_frame_compute takes exactly one journal before entering the
// compute journal helper.
renderer_frame_compute :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	if !_renderer_has_pending_work(r, terminal) {
		if r != nil { r.last_dirty = false }
		return false
	}
	if !r.frame_prepared { renderer_prepare_frame(r, terminal) }
	_renderer_force_pending_redraw(r, terminal)
	r.frame_prepared = false
	r.frame_count += 1
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)
	return _renderer_frame_compute_journal(r, terminal, &journal, lut)
}

// _renderer_frame_fullscreen_journal owns one journal and one shared encoder
// for the fullscreen shade, optional cursor composition, and publication.
_renderer_frame_fullscreen_journal :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, journal: ^termgrid.Damage_Journal, lut: ^Style_LUT) -> bool {
	if r.strategy != .Fullscreen || !r.fullscreen.available {
		return _renderer_frame_v2_journal(r, terminal, journal, lut)
	}
	if !_renderer_journal_has_damage(journal) {
		r.last_dirty = false
		return false
	}
	r.last_dirty = true
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || lut == nil {
		return _renderer_frame_unavailable(r, terminal, journal, .Fullscreen)
	}
	lut_rebuilt := _style_lut_needs_rebuild(lut, &terminal.grid.style_table)
	if lut_rebuilt { style_lut_rebuild(lut, &terminal.grid.style_table) }
	if len(journal.scroll_ops) > 0 {
		render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
	} else {
		render_compile_v2(&r.compiled_v2, terminal, journal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
	}
	cells := transmute([]u64)r.compiled_v2.cells
	lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:fullscreen.FULLSCREEN_LUT_WORDS]
	_ = fullscreen.fullscreen_upload_grid(&r.fullscreen, cells, lut_words, lut_rebuilt)
	frame, ok := _renderer_surface_begin(r)
	if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Fullscreen) }
	if r.cursor_staged && !_renderer_upload_instances(r, 0, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Fullscreen)
	}
	cursor_pipeline := gpu.Gpu_RenderPipeline(nil)
	cursor_bind_group := gpu.Gpu_BindGroup(nil)
	cursor_buffer := gpu.Gpu_Buffer(nil)
	cursor_offset: u64 = 0
	if r.cursor_staged {
		cursor_pipeline = r.instances.bg_pipeline
		cursor_bind_group = r.instances.bind_group_bg
		cursor_buffer = frame.cursor_buffer
		cursor_offset = frame.cursor_offset
	}
	if !fullscreen.fullscreen_draw(&r.fullscreen, frame.view, frame.encoder, cursor_pipeline, cursor_bind_group, cursor_buffer, cursor_offset) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Fullscreen)
	}
	frame.state = .Encoded
	if !_renderer_surface_commit(r, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Fullscreen)
	}
	_renderer_frame_published(r)
	return true
}

// renderer_frame_fullscreen takes exactly one journal before entering the
// fullscreen journal helper.
renderer_frame_fullscreen :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	if !_renderer_has_pending_work(r, terminal) {
		if r != nil { r.last_dirty = false }
		return false
	}
	if !r.frame_prepared { renderer_prepare_frame(r, terminal) }
	_renderer_force_pending_redraw(r, terminal)
	r.frame_prepared = false
	r.frame_count += 1
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)
	return _renderer_frame_fullscreen_journal(r, terminal, &journal, lut)
}

// renderer_frame_auto executes one adaptive frame. Strategy selection reads
// live damage, then exactly one journal is taken and routed to the selected
// journal-owned helper. Runtime sibling failure is deferred to the next frame
// through fallback_pending.
renderer_frame_auto :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	if !_renderer_has_pending_work(r, terminal) {
		r.last_dirty = false
		return false
	}
	renderer_prepare_frame(r, terminal)
	_renderer_force_pending_redraw(r, terminal)
	inp := strategy_estimate_inputs(&terminal.damage, r.rows, r.cols)
	if inp.dirty_cells <= 0 && !inp.scroll {
		r.frame_prepared = false
		return false
	}

	chosen := strategy_select(inp, &r.strategy_state, r.compute_tiles.available, r.fullscreen.available)
	if r.fallback_pending {
		chosen = .Instance
		r.fallback_pending = false
	}
	r.strategy = chosen
	if !r.strategy_state.pinned {
		if chosen == .Compute_Tiles && r.strategy_state.last != .Compute_Tiles {
			tile.tile_map_mark_all(&r.tile_map)
		} else if chosen == .Instance && r.strategy_state.last != .Instance {
			r.dirty.armed = false
		}
	}
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)
	r.frame_prepared = false
	r.frame_count += 1
	start := platform.platform_now()
	ok := false
	switch chosen {
	case .Instance:
		ok = _renderer_frame_v2_journal(r, terminal, &journal, lut)
	case .Compute_Tiles:
		if r.compute_tiles.available && r.tile_map.bits != nil {
			ok = _renderer_frame_compute_journal(r, terminal, &journal, lut)
		} else {
			ok = _renderer_frame_v2_journal(r, terminal, &journal, lut)
		}
	case .Fullscreen:
		if r.fullscreen.available {
			ok = _renderer_frame_fullscreen_journal(r, terminal, &journal, lut)
		} else {
			ok = _renderer_frame_v2_journal(r, terminal, &journal, lut)
		}
	}
	end := platform.platform_now()
	if ok {
		strategy_record(&r.strategy_state, chosen, u64(platform.platform_ticks_to_ns(end - start)))
	}
	return ok
}

// renderer_strategy_pin locks the selector to s: the pin wins over scroll,
// ratio, and history. Pinning Compute_Tiles marks all tiles so the next
// compute frame rebuilds the framebuffer (mirrors renderer_set_strategy);
// Fullscreen needs no mark. An unavailable pinned sibling falls back to
// Instance per frame without latching availability.
renderer_strategy_pin :: proc(r: ^Renderer, s: Render_Strategy) {
	r.strategy_state.pinned = true
	r.strategy_state.pin = s
	r.strategy = s
	if s == .Compute_Tiles {
		tile.tile_map_mark_all(&r.tile_map)
	}
}

// renderer_strategy_unpin clears the manual pin; the next frame_auto call
// resumes adaptive selection with history intact.
renderer_strategy_unpin :: proc(r: ^Renderer) {
	r.strategy_state.pinned = false
}

// renderer_resize handles window resize events.
renderer_resize :: proc(r: ^Renderer, new_width_px: u32, new_height_px: u32) {
	if !_renderer_wait_for_gpu(r) {
		return
	}
	r.screen_w = f32(new_width_px)
	r.screen_h = f32(new_height_px)
	r.surface_w = new_width_px
	r.surface_h = new_height_px
	if new_width_px == 0 || new_height_px == 0 {
		return
	}
	if r.backend != nil && rawptr(r.device) != nil && rawptr(r.surface) != nil {
		r.backend.configure_surface(rawptr(r.surface), r.device, r.format, new_width_px, new_height_px)
	}
	instance.instance_renderer_set_screen_size(&r.instances, r.backend, f32(new_width_px), f32(new_height_px))
	if r.dirty.armed {
		dirty_upload_rebase(&r.dirty, r, &r.style_lut)
	}
	// Phase 14: recreate compute resources on pixel change, then force a
	// full rewrite next frame. Resize failure disables compute (fallback).
	tw := r.compute_tiles.tile_w
	th := r.compute_tiles.tile_h
	if tw == 0 || th == 0 {
		tw = tile.TILE_W_DEFAULT
		th = tile.TILE_H_DEFAULT
	}
	if r.compute_tiles.available {
		if tile.compute_tile_resize(&r.compute_tiles, r.rows, r.cols, r.cell_width, r.cell_height, r.pad_x, r.pad_y, r.screen_w, r.screen_h, r.format) {
			if tile.tile_map_resize(&r.tile_map, r.rows, r.cols, tw, th) {
				tile.tile_map_mark_all(&r.tile_map)
			}
		} else {
			r.compute_tiles.available = false
		}
	}
	// Phase 15: rewrite fullscreen params / recreate the grid buffer on
	// geometry change. Resize failure disables fullscreen (fallback); the
	// flag never latches.
	if r.fullscreen.available {
		if !fullscreen.fullscreen_resize(&r.fullscreen, r.rows, r.cols, r.cell_width, r.cell_height, r.pad_x, r.pad_y, r.format) {
			r.fullscreen.available = false
		}
	}
	r.full_redraw_pending = true
}

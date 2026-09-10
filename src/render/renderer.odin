package render

// Top-level renderer: orchestrates the full render pipeline.
//
// Pipeline per frame:
//   1. Take damage journal from terminal
//   2. Compile full grid → packed render cells
//   3. Prepare instance data (bg + glyph instances)
//   4. Upload instance data via triple-buffered ring
//   5. Encode render commands (2-pass: bg + glyph)
//   6. Submit to GPU and present
//
// Static scene optimization: if no damage, skip the frame entirely (~0μs).

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
TILE_COMPUTE_WGSL :: #load("shaders/tile_compute.wgsl")
TILE_BLIT_WGSL :: #load("shaders/tile_blit.wgsl")
FULLSCREEN_WGSL :: #load("shaders/fullscreen.wgsl")

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
	screen_w:   f32,
	screen_h:   f32,
	format:     gpu.Gpu_Format,

	// Surface
	surface:    gpu.Gpu_Surface,
	surface_w:  u32,
	surface_h:  u32,

	// State
	frame_count: u64,
	last_dirty:  bool,  // whether the last frame had damage
	device:      gpu.Gpu_Device,
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
) -> bool {
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return false
	}
	r.rows = rows
	r.cols = cols
	r.cell_width  = cell_width
	r.cell_height = cell_height
	r.screen_w    = screen_w
	r.screen_h    = screen_h
	r.format      = format
	r.device      = device
	r.queue       = queue
	r.backend     = backend
	r.frame_count = 0
	r.last_dirty  = true
	r.surface     = gpu.Gpu_Surface(nil)
	r.surface_w   = 0
	r.surface_h   = 0

	// Initialize font rasterizer
	font_error: Font_Error
	if !font_rasterizer_init(&r.rasterizer, font_path, pixel_size, &font_error, allocator) {
		// Font loading failed, but we continue with an uninitialized rasterizer
		// The atlas will have no prewarmed glyphs
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
		return false
	}

	// Phase 8: persistent dirty-upload buffer; the upload ring is retained
	// as the legacy-fallback carrier and is always initialized so the
	// fallback path has valid buffers.
	dirty_upload_init(&r.dirty, r, allocator)
	upload_ring_init(&r.upload_ring, backend, device, queue, RENDER_UPLOAD_CAPACITY, allocator)

	// Phase 14: tiled compute sibling path (best-effort; failure leaves
	// compute unavailable and the instance default untouched).
	tile.tile_map_init(&r.tile_map, rows, cols, tile.TILE_W_DEFAULT, tile.TILE_H_DEFAULT, allocator)
	tile.compute_tile_init(
		&r.compute_tiles, backend, device, queue, rows, cols,
		cell_width, cell_height, format, r.atlas.gpu_view,
		string(TILE_COMPUTE_WGSL), string(TILE_BLIT_WGSL),
		tile.TILE_W_DEFAULT, tile.TILE_H_DEFAULT, allocator,
	)

	// Phase 15: fullscreen fragment sibling path (best-effort; failure
	// leaves fullscreen unavailable and the instance default untouched).
	fullscreen.fullscreen_init(
		&r.fullscreen, backend, device, queue, rows, cols,
		cell_width, cell_height, format, r.atlas.gpu_view,
		string(FULLSCREEN_WGSL), allocator,
	)

	// Phase 12: async raster queue, worker start LAST (after the chain the
	// worker reads and every other subsystem is ready).
	raster_queue_init(&r.raster, &r.raster_counters)
	raster_worker_start(&r.raster, &r.fallback)
	return true
}

// renderer_destroy frees all renderer resources.
renderer_destroy :: proc(r: ^Renderer, allocator: runtime.Allocator = context.allocator) {
	// Phase 12 first: join the worker, apply every pending completion to
	// the atlas (no loss), then free the queue — before the atlas, chain,
	// and cache below are torn down.
	raster_worker_shutdown(&r.raster)
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, &r.fallback, &r.fallback_counters)
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

	// Phase 14 compute path teardown.
	tile.compute_tile_destroy(&r.compute_tiles)
	tile.tile_map_destroy(&r.tile_map, allocator)

	// Phase 15 fullscreen path teardown.
	fullscreen.fullscreen_destroy(&r.fullscreen)

	// Free fallback fonts (slots 1..; slot 0 aliases the rasterizer below)
	fallback_chain_destroy(&r.fallback)

	// Free rasterizer resources
	font_rasterizer_destroy(&r.rasterizer)
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

// renderer_frame executes one render frame.
// Returns true if a frame was actually rendered (had damage), false if skipped.
renderer_frame :: proc(
	r: ^Renderer,
	terminal: ^termgrid.Terminal,
) -> bool {
	r.frame_count += 1

	// Take damage journal
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)

	// Check if there is any damage
	has_damage := false
	for i in 0..<len(journal.dirty_rows) {
		if journal.dirty_rows[i].full || journal.dirty_rows[i].span_count > 0 {
			has_damage = true
			break
		}
	}
	if len(journal.scroll_ops) > 0 {
		has_damage = true
	}

	// Static scene optimization: skip frame if no damage
	if !has_damage && r.last_dirty {
		// First clean frame after dirty: render once more to ensure consistency
		r.last_dirty = false
	} else if !has_damage {
		// Skip frame entirely
		return false
	} else {
		r.last_dirty = true
	}

	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	if rawptr(r.instances.bg_pipeline) == nil || rawptr(r.instances.glyph_pipeline) == nil {
		return false
	}

	// Step 1: Compile full grid → packed render cells
	style_table := &terminal.grid.style_table
	render_compile_full(&r.compiled, terminal, style_table)

	// Step 2: Prepare instance data
	bg_count, glyph_count := _prepare_instances(r, terminal, style_table)

	// Step 3: Upload instance data via ring buffer
	total := u64(bg_count + glyph_count)
	byte_count := total * instance.INSTANCE_STRIDE
	staging := upload_ring_get_staging(&r.upload_ring)
	copy_size := byte_count
	if copy_size > u64(len(staging)) {
		copy_size = u64(len(staging))
	}
	if copy_size > 0 && len(r.instances.instance_data) > 0 {
		mem.copy(raw_data(staging), raw_data(r.instances.instance_data), int(copy_size))
	}
	submitted_slot := upload_ring_current_slot(&r.upload_ring)
	upload_ring_submit(&r.upload_ring, byte_count)
	buffer := upload_ring_get_buffer(&r.upload_ring, submitted_slot)

	// Step 4: Get surface texture
	if rawptr(r.surface) == nil {
		return false
	}
	texture, view, _ := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(view) == nil {
		// Lost/Outdated/Timeout/Error → reconfigure and skip
		if rawptr(texture) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		return false
	}

	// Step 5: Encode bg + glyph passes in a single render pass (clear black)
	encoder := r.backend.create_command_encoder(r.device)
	pass := r.backend.begin_render_pass(encoder, view, {0, 0, 0, 1}, .Clear)

	r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
	r.backend.render_set_vertex_buffer(pass, 0, buffer, 0)
	r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, bg_count)

	glyph_offset := u64(bg_count) * instance.INSTANCE_STRIDE
	r.backend.render_set_pipeline(pass, r.instances.glyph_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_glyph)
	r.backend.render_set_vertex_buffer(pass, 0, buffer, glyph_offset)
	r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, glyph_count)

	r.backend.end_render_pass(pass)
	cmd := r.backend.finish_command_buffer(encoder)
	r.backend.submit(r.queue, cmd)

	// Step 6: Present + release
	r.backend.present_surface(rawptr(r.surface))
	r.backend.release_surface_texture(texture, view)

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

		x := f32(col) * cell_w
		y := f32(row) * cell_h

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
		x := f32(col) * cell_w
		y := f32(row) * cell_h

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
		x := f32(col) * cell_w
		y := f32(row) * cell_h

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

// _draw_instance_buffer presents one frame from an explicit instance buffer:
// surface texture acquisition, bg + glyph passes in a single render pass
// (clear black), submit, present, release.
_draw_instance_buffer :: proc(r: ^Renderer, buffer: gpu.Gpu_Buffer, bg_count: u32, glyph_count: u32, glyph_offset: u64) -> bool {
	// Step 4: Get surface texture
	if rawptr(r.surface) == nil {
		return false
	}
	texture, view, _ := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(view) == nil {
		if rawptr(texture) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		return false
	}

	// Step 5: Encode bg + glyph passes in a single render pass (clear black)
	encoder := r.backend.create_command_encoder(r.device)
	pass := r.backend.begin_render_pass(encoder, view, {0, 0, 0, 1}, .Clear)

	r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
	r.backend.render_set_vertex_buffer(pass, 0, buffer, 0)
	r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, bg_count)

	r.backend.render_set_pipeline(pass, r.instances.glyph_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_glyph)
	r.backend.render_set_vertex_buffer(pass, 0, buffer, glyph_offset)
	r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, glyph_count)

	r.backend.end_render_pass(pass)
	cmd := r.backend.finish_command_buffer(encoder)
	r.backend.submit(r.queue, cmd)

	// Step 6: Present + release
	r.backend.present_surface(rawptr(r.surface))
	r.backend.release_surface_texture(texture, view)

	return true
}

// renderer_frame_v2 executes one render frame through the V2 pipeline:
// damage take + static-scene skip, LUT rebuild (when stale), then either the
// dirty path (stable slots, offset writes, constant counts) or the legacy
// full path (dense recompile + ring upload, disarms dirty).
renderer_frame_v2 :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, _: ^Compiled_Frame_V2, lut: ^Style_LUT) -> bool {
	r.frame_count += 1

	// Phase 12 frame top: drain worker completions into the atlas, then
	// upload the atlas when the drain dirtied it — before the
	// dirty/legacy branch so pop-in glyphs compile fresh this frame.
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, &r.fallback, &r.fallback_counters)
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}

	// Take damage journal
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)

	// Check if there is any damage
	has_damage := false
	for i in 0..<len(journal.dirty_rows) {
		if journal.dirty_rows[i].full || journal.dirty_rows[i].span_count > 0 {
			has_damage = true
			break
		}
	}
	if len(journal.scroll_ops) > 0 {
		has_damage = true
	}

	// Static scene optimization: skip frame if no damage
	if !has_damage && r.last_dirty {
		// First clean frame after dirty: render once more to ensure consistency
		r.last_dirty = false
	} else if !has_damage {
		// Skip frame entirely
		return false
	} else {
		r.last_dirty = true
	}

	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	if rawptr(r.instances.bg_pipeline) == nil || rawptr(r.instances.glyph_pipeline) == nil {
		return false
	}

	// Rebuild the LUT when the style table grew since the last rebuild.
	if terminal.grid.style_table.count != lut.count {
		style_lut_rebuild(lut, &terminal.grid.style_table)
	}

	// Dirty path: persistent buffer + offset writes, constant counts (N, N).
	if len(journal.scroll_ops) == 0 && r.dirty.mirror != nil {
		if !r.dirty.armed {
			dirty_upload_rebase(&r.dirty, r, lut)
		}
		ranges: [DIRTY_UPLOAD_MAX_RANGES]Dirty_Upload_Range
		_, _, fell_back := dirty_upload_frame(&r.dirty, r, terminal, &journal, lut, &ranges)
		if !fell_back {
			n := u32(int(r.rows) * int(r.cols))
			return _draw_instance_buffer(r, r.dirty.buffer, n, n, u64(n) * instance.INSTANCE_STRIDE)
		}
	}

	// Legacy full path (dense recompile + ring upload). Disarms dirty; the
	// next clean frame rebases before returning to the dirty path.
	r.dirty.armed = false

	// Step 1: Compile full grid → persistent V2 frame.
	render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)

	// Step 2: Prepare instance data (dense).
	bg_count, glyph_count := _prepare_instances_v2(r, lut)

	// Step 3: Upload instance data via ring buffer (CapacityClamp on overflow).
	total := u64(bg_count + glyph_count)
	byte_count := total * instance.INSTANCE_STRIDE
	staging := upload_ring_get_staging(&r.upload_ring)
	copy_size := byte_count
	if copy_size > u64(len(staging)) {
		copy_size = u64(len(staging))
	}
	if copy_size > 0 && len(r.instances.instance_data) > 0 {
		mem.copy(raw_data(staging), raw_data(r.instances.instance_data), int(copy_size))
	}
	submitted_slot := upload_ring_current_slot(&r.upload_ring)
	upload_ring_submit(&r.upload_ring, byte_count)
	buffer := upload_ring_get_buffer(&r.upload_ring, submitted_slot)

	return _draw_instance_buffer(r, buffer, bg_count, glyph_count, u64(bg_count) * instance.INSTANCE_STRIDE)
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

// renderer_frame_compute executes one frame through the Phase 14 tiled
// compute path: damage take + static-scene skip, LUT rebuild (when stale),
// scroll → full compile + mark_all else dirty compile + mark_damage,
// dirty cell + tile-list (+ LUT when rebuilt) upload, one dispatch, blit.
// Empty damage skips with no blit. Any unavailable/nil compute state
// delegates to renderer_frame_v2 verbatim (instance fallback, never latches).
renderer_frame_compute :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	if r.strategy != .Compute_Tiles || !r.compute_tiles.available || r.tile_map.bits == nil {
		return renderer_frame_v2(r, terminal, nil, lut)
	}
	r.frame_count += 1

	// Atlas drain + upload BEFORE dispatch (same order as frame_v2).
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, &r.fallback, &r.fallback_counters)
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}

	// Take damage journal
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)

	// Check if there is any damage
	has_damage := false
	for i in 0..<len(journal.dirty_rows) {
		if journal.dirty_rows[i].full || journal.dirty_rows[i].span_count > 0 {
			has_damage = true
			break
		}
	}
	if len(journal.scroll_ops) > 0 {
		has_damage = true
	}

	// Static scene optimization: skip frame if no damage
	if !has_damage && r.last_dirty {
		r.last_dirty = false
	} else if !has_damage {
		return false
	} else {
		r.last_dirty = true
	}

	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}

	// Rebuild the LUT when the style table grew since the last rebuild.
	lut_rebuilt := terminal.grid.style_table.count != lut.count
	if lut_rebuilt {
		style_lut_rebuild(lut, &terminal.grid.style_table)
	}

	// Scroll ops: full rebase, no span mapping.
	if len(journal.scroll_ops) > 0 {
		render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
		tile.tile_map_mark_all(&r.tile_map)
	} else {
		render_compile_v2(&r.compiled_v2, terminal, &journal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
		count, _ := tile.tile_map_mark_damage(&r.tile_map, &journal)
		if count == 0 {
			return false
		}
	}

	// Dirty cell ranges + tile list (+ LUT when rebuilt), then one dispatch.
	lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:tile.TILE_LUT_WORDS]
	bytes := tile.compute_tile_upload_cells(&r.compute_tiles, &r.tile_map, r.compiled_v2.cells, lut_words, lut_rebuilt)
	_ = bytes
	dispatches, _ := tile.compute_tile_dispatch(&r.compute_tiles, &r.tile_map)
	if dispatches == 0 {
		tile.tile_map_clear(&r.tile_map)
		return false
	}

	// Acquire surface (same discipline as _draw_instance_buffer).
	if rawptr(r.surface) == nil {
		tile.tile_map_clear(&r.tile_map)
		return false
	}
	texture, view, _ := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(view) == nil {
		if rawptr(texture) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		tile.tile_map_clear(&r.tile_map)
		return false
	}

	tile.compute_tile_blit(&r.compute_tiles, view)
	tile.tile_map_clear(&r.tile_map)

	r.backend.present_surface(rawptr(r.surface))
	r.backend.release_surface_texture(texture, view)

	return true
}

// renderer_frame_fullscreen executes one frame through the Phase 15
// fullscreen fragment path: damage take + static-scene skip, LUT rebuild
// (when stale), scroll → full compile else dirty compile, full grid + LUT
// upload, one fullscreen draw. Empty damage skips with no upload and no
// draw. Any unavailable/nil fullscreen state delegates to
// renderer_frame_v2 verbatim (instance fallback, never latches).
renderer_frame_fullscreen :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	if r.strategy != .Fullscreen || !r.fullscreen.available {
		return renderer_frame_v2(r, terminal, nil, lut)
	}
	r.frame_count += 1

	// Atlas drain + upload BEFORE the fullscreen draw (same order as frame_v2).
	raster_drain_completions(&r.raster, &r.atlas, &r.shape_cache, &r.fallback, &r.fallback_counters)
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}

	// Take damage journal
	journal := termgrid.terminal_take_damage(terminal)
	defer termgrid.damage_journal_destroy(&journal)

	// Check if there is any damage
	has_damage := false
	for i in 0..<len(journal.dirty_rows) {
		if journal.dirty_rows[i].full || journal.dirty_rows[i].span_count > 0 {
			has_damage = true
			break
		}
	}
	if len(journal.scroll_ops) > 0 {
		has_damage = true
	}

	// Static scene optimization: skipped frames write nothing.
	if !has_damage {
		r.last_dirty = false
		return false
	}
	r.last_dirty = true

	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}

	// Rebuild the LUT when the style table grew since the last rebuild.
	lut_rebuilt := terminal.grid.style_table.count != lut.count
	if lut_rebuilt {
		style_lut_rebuild(lut, &terminal.grid.style_table)
	}

	// Scroll ops: full rebase, no span mapping.
	if len(journal.scroll_ops) > 0 {
		render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
	} else {
		render_compile_v2(&r.compiled_v2, terminal, &journal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster)
	}

	// Full grid re-upload (+ LUT when rebuilt), no ranges/offsets.
	cells := transmute([]u64)r.compiled_v2.cells
	lut_words := ([^]u32)(rawptr(&lut.fg_r5g6b5[0]))[:fullscreen.FULLSCREEN_LUT_WORDS]
	bytes := fullscreen.fullscreen_upload_grid(&r.fullscreen, cells, lut_words, lut_rebuilt)
	_ = bytes

	// Acquire surface (same discipline as _draw_instance_buffer).
	if rawptr(r.surface) == nil {
		return false
	}
	texture, view, _ := r.backend.get_surface_texture(rawptr(r.surface))
	if rawptr(view) == nil {
		if rawptr(texture) != nil {
			r.backend.release_surface_texture(texture, view)
		}
		if r.surface_w != 0 && r.surface_h != 0 {
			r.backend.configure_surface(rawptr(r.surface), r.device, r.format, r.surface_w, r.surface_h)
		}
		return false
	}

	if !fullscreen.fullscreen_draw(&r.fullscreen, view) {
		r.backend.release_surface_texture(texture, view)
		return false
	}

	r.backend.present_surface(rawptr(r.surface))
	r.backend.release_surface_texture(texture, view)

	return true
}

// renderer_frame_auto executes one frame through the Phase 16 adaptive
// path: a read-only pre-scan of the live damage journal skips empty frames
// with no record and no mutation (frame_count/last_dirty stay owned by the
// delegated procs, so there is no double-toggle); otherwise the strategy is
// selected, dispatched through the existing frame procs unchanged, timed
// with platform_now, and recorded to the executed strategy only when the
// frame completes (true) with ns > 0. Skips and failed frames record
// nothing and never poison the averages.
renderer_frame_auto :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, lut: ^Style_LUT) -> bool {
	inp := strategy_estimate_inputs(&terminal.damage, r.rows, r.cols)
	if inp.dirty_cells <= 0 && !inp.scroll {
		return false
	}

	chosen := strategy_select(inp, &r.strategy_state, r.compute_tiles.available, r.fullscreen.available)
	r.strategy = chosen
	start := platform.platform_now()
	ok := false
	switch chosen {
	case .Instance:
		ok = renderer_frame_v2(r, terminal, nil, lut)
	case .Compute_Tiles:
		ok = renderer_frame_compute(r, terminal, lut)
	case .Fullscreen:
		ok = renderer_frame_fullscreen(r, terminal, lut)
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
	if tile.compute_tile_resize(&r.compute_tiles, r.rows, r.cols, r.cell_width, r.cell_height, r.format) {
		if tile.tile_map_resize(&r.tile_map, r.rows, r.cols, tw, th) {
			tile.tile_map_mark_all(&r.tile_map)
		}
	} else {
		r.compute_tiles.available = false
	}
	// Phase 15: rewrite fullscreen params / recreate the grid buffer on
	// geometry change. Resize failure disables fullscreen (fallback); the
	// flag never latches.
	if !fullscreen.fullscreen_resize(&r.fullscreen, r.rows, r.cols, r.cell_width, r.cell_height, r.format) {
		r.fullscreen.available = false
	}
}

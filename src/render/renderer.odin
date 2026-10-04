package render

// Top-level renderer: orchestrates the full render pipeline.
import "core:fmt"
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
import diag "../diag"
import fullscreen "fullscreen"
import graphics_pkg "../graphics"
import interaction "../interaction"
import "gpu"
import instance "instance"
import tile "tile"
import termgrid "../terminal"

BG_WGSL :: #load("shaders/bg.wgsl")
GLYPH_WGSL :: #load("shaders/glyph.wgsl")
EMOJI_WGSL :: #load("shaders/emoji.wgsl")
IMAGE_WGSL :: #load("shaders/image.wgsl")

BG_MSL :: #load("shaders/msl_spike/bg.msl")
GLYPH_MSL :: #load("shaders/msl_spike/glyph.msl")
EMOJI_MSL :: #load("shaders/msl_spike/emoji.msl")
IMAGE_MSL :: #load("shaders/msl_spike/image.msl")

// Pane_Viewport defines a rendering rectangle for a single pane within the app window.
Pane_Viewport :: struct {
	terminal:   ^termgrid.Terminal,
	view:       ^termgrid.Terminal_View,
	x, y:       f32,
	w, h:       f32,
	clip_rect:  [4]f32, // [min_x, min_y, max_x, max_y] physical pixels; if clip_rect[2] <= clip_rect[0], no clipping
	rows, cols: int,
	dim_factor: f32, // 1.0 for active focused pane, 0.75-0.80 for inactive
	is_active:  bool,
}

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
	// drawable_outstanding is true from the moment a surface drawable has been
	// acquired until a present has been attempted for it. CAMetalLayer only
	// returns a drawable to its pool once it has been presented, so a frame that
	// is abandoned while this is true is holding a pool slot that nothing else
	// can reclaim. It is cleared before the present call, not after, so a present
	// that fails is not retried on the way out.
	drawable_outstanding: bool,
	texture:       gpu.Gpu_Texture,
	view:          gpu.Gpu_TextureView,
	format:        gpu.Gpu_Format,
	encoder:       gpu.Gpu_CommandEncoder,
	pass:          gpu.Gpu_RenderPassEncoder,
	cursor_buffer: gpu.Gpu_Buffer,
	cursor_offset: u64,
	interaction_offset: u64,
	interaction_count:  u32,
	scrollbar_offset:   u64,
	scrollbar_count:    u32,
	// UI chrome is composited per layer, ascending: a higher layer always
	// lands at a higher byte offset and therefore paints last.
	ui_bg_offset:    [UI_LAYER_COUNT]u64,
	ui_bg_count:     [UI_LAYER_COUNT]u32,
	ui_glyph_offset: [UI_LAYER_COUNT]u64,
	ui_glyph_count:  [UI_LAYER_COUNT]u32,
	upload:        Upload_Ring_Frame,
	upload_committed: bool,
	command_buffer: rawptr,
	encoder_released: bool,
	command_released: bool,
	image_offset:   u64,
	image_count:    u32,
	focus_image_offset: u64,
	focus_image_count: u32,
}

Image_Texture_Key :: struct {
	graphics_namespace: u64,
	image_id:           u32,
	generation:         u64,
}

Image_Texture_Cache_Slot :: struct {
	used:       bool,
	key:        Image_Texture_Key,
	texture:    gpu.Gpu_Texture,
	view:       gpu.Gpu_TextureView,
	bind_group: gpu.Gpu_BindGroup,
	width, height: u32,
	last_seen_frame: u64,
}

Image_Draw :: struct {
	used:         bool,
	placement_id: u32,
	image_id:     u32,
	z:            i32,
	cache_slot:   int,
	instance_index: u32,
}

// Renderer is the top-level render state.
Renderer :: struct {
	// surface_reclaims counts frames abandoned after acquiring a drawable, whose
	// drawable was handed back to the layer from the abort path instead of being
	// presented with real content. It is per renderer so a test can assert the
	// distinction between "the frame presented nothing" and "the frame presented
	// only to reclaim its drawable", and it is the direct measure of how close the
	// surface is to losing every drawable in its pool.
	surface_reclaims: u32,
	// Sub-systems
	atlas:       Atlas,
	emoji_atlas: Emoji_Atlas,
	compiled:    Compiled_Frame,
	compiled_v2: Compiled_Frame_V2,
	dirty:      Dirty_Upload,
	style_lut:  Style_LUT,
	upload_ring: Upload_Ring,
	unlock_cb:   proc(data: rawptr),
	unlock_data: rawptr,
	instances:  instance.Instance_Renderer,
	image_pipeline: gpu.Gpu_RenderPipeline,
	image_bind_group_layout: gpu.Gpu_BindGroupLayout,
	image_cache: [graphics_pkg.KGP_MAX_IMAGES]Image_Texture_Cache_Slot,
	image_instances: [graphics_pkg.KGP_MAX_PLACEMENTS]instance.Instance_Data,
	image_draws: [graphics_pkg.KGP_MAX_PLACEMENTS]Image_Draw,
	image_count: u32,
	image_under_count: u32,
	image_focus_staged: bool,
	image_focus_instance: instance.Instance_Data,
	image_focus_cache_slot: int,
	staged_graphics_store: ^graphics_pkg.Store,
	staged_graphics_namespace: u64,
	staged_graphics_epoch: u64,
	staged_graphics_placement_epoch: u64,
	staged_graphics_valid: bool,
	last_graphics_store: ^graphics_pkg.Store,
	last_graphics_namespace: u64,
	last_graphics_epoch: u64,
	last_graphics_placement_epoch: u64,
	last_graphics_valid: bool,
	rasterizer: Font_Rasterizer,
	ligature_cache: Ligature_Cache,

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
	// background_opacity scales every terminal background paint. Foreground
	// coverage and app chrome are independent; overlapping background paints
	// retain normal source-over composition.
	background_opacity: f32,

	// Surface
	surface:    gpu.Gpu_Surface,
	surface_w:  u32,
	surface_h:  u32,

	// State
	frame_count:     u64,
	last_dirty:      bool,  // whether the last frame had damage
	frame_prepared:         bool,
	cursor_staged:          bool, // cursor_overlay_draw staged the reserved instance
	ui_staged:              bool,
	ui_layer:               UI_Layer,        // currently open layer for staging
	ui_layer_bg_count:      [UI_LAYER_COUNT]u32,
	ui_layer_glyph_count:   [UI_LAYER_COUNT]u32,
	ui_bg_data:             [UI_LAYER_COUNT][UI_LAYER_MAX_BG]instance.Instance_Data,
	ui_glyph_data:          [UI_LAYER_COUNT][UI_LAYER_MAX_GLYPH]instance.Instance_Data,
	interaction_staged:     bool, // interaction_overlay_draw staged quads
	interaction_slot_start: u32,  // starting instance slot for interaction quads
	interaction_quad_count: int,  // count of staged interaction quads
	scrollbar_staged:       bool, // scrollbar_overlay_draw staged quads
	scrollbar_count:        u32,  // count of staged scrollbar quads
	scrollbar_data:         [2]instance.Instance_Data,
	device:                 gpu.Gpu_Device,
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
	last_is_alt_screen:  bool,
}

// RENDER_MAX_INSTANCES is the maximum number of instances per draw call.
RENDER_MAX_INSTANCES :: 16384

// Reserve one background, glyph, decoration and interaction quad per
// surface cell. Slack covers bounded pane fills, cursor and chrome overlays.
RENDER_INSTANCES_PER_CELL :: 4
RENDER_INSTANCE_OVERLAY_SLACK :: 128

_renderer_instance_capacity :: proc(rows, cols: i32) -> u32 {
	return max(u32(RENDER_MAX_INSTANCES), u32(RENDER_INSTANCES_PER_CELL * rows * cols + RENDER_INSTANCE_OVERLAY_SLACK))
}

// UI_LAYER_COUNT is the number of chrome compositing layers. Blended UI has no
// depth test, so layer order alone decides paint order.
UI_LAYER_COUNT :: 6

UI_Layer :: enum u8 {
	Pane_Chrome = 0,  // dividers, active-pane outline, hollow cursors
	Tab_Chrome  = 1,  // tab bar bg + strip, search bar
	Popover     = 2,  // tab context menu, tab overflow menu, tab rename
	Modal       = 3,  // session switcher
	Overlay     = 4,  // confirm dialog, drop FX surface
	Devtools    = 5,  // read-only DevTools perf panel (draw-only, never interactive)
}

// Per-layer instance budgets, sized to real usage. Each layer owns a private
// fixed sub-array, so a full layer drops its own quads instead of spilling into
// a neighbour and callers may emit into any layer in any temporal order.
// Pane_Chrome: <=32 dividers + 4 quads per inactive-pane hollow cursor + 4
// border edges. Tab_Chrome/Modal: the strip and the switcher list dominate.
// Overlay also carries the multi-quad drop-FX ripples plus the session
// switcher's row context menu, whose three label+shortcut rows need ~51 cells.
// These are package-level values rather than constants so the staging helpers can
// index them by layer; they live in static storage and never allocate. A capacity
// only bounds how much a layer may stage: every layer row is allocated at
// UI_LAYER_MAX_GLYPH, so raising one does not grow the storage.
// Positional entries follow the UI_Layer declaration order:
// {Pane_Chrome, Tab_Chrome, Popover, Modal, Overlay, Devtools}.
// Devtools needs a single background card and a glyph budget of exactly
// DEVTOOLS_PANEL_LINES * DEVTOOLS_PANEL_COLUMNS, which is also
// UI_LAYER_MAX_GLYPH, so the layer adds no static instance memory at all.
// A capacity must never exceed UI_LAYER_MAX_BG / UI_LAYER_MAX_GLYPH: the
// staging rows are allocated at the maximum, not at the per-layer capacity.
UI_LAYER_BG_CAPACITY: [UI_LAYER_COUNT]int = [UI_LAYER_COUNT]int{160, 64, 48, 48, 160, 1}
UI_LAYER_GLYPH_CAPACITY: [UI_LAYER_COUNT]int = [UI_LAYER_COUNT]int{0, 256, 160, 256, 64, 256}

// Storage dimensions: Odin arrays cannot be ragged, so every layer row is
// allocated at the widest budget it needs. Total instance memory is
// (UI_LAYER_MAX_BG + UI_LAYER_MAX_GLYPH) * UI_LAYER_COUNT * INSTANCE_STRIDE
// ~= 98 KB, about 2x the previous flat 2 x 512 staging pair.
UI_LAYER_MAX_BG :: 160
UI_LAYER_MAX_GLYPH :: 256

// UI_Layer_Run records where one layer's background and glyph runs land inside
// the contiguous staging region.
UI_Layer_Run :: struct {
	bg_offset:    u64,
	bg_count:     u32,
	glyph_offset: u64,
	glyph_count:  u32,
}

// renderer_ui_reset clears every UI layer and reopens the base pane-chrome layer.
renderer_ui_reset :: proc(r: ^Renderer) {
	if r == nil do return
	for layer in UI_Layer {
		r.ui_layer_bg_count[layer] = 0
		r.ui_layer_glyph_count[layer] = 0
	}
	r.ui_layer = .Pane_Chrome
}

// renderer_ui_begin_layer selects the layer that subsequent staging targets.
renderer_ui_begin_layer :: proc(r: ^Renderer, layer: UI_Layer) {
	if r == nil do return
	r.ui_layer = layer
}

// renderer_ui_stage_bg appends one background quad to the open layer. Quads that
// do not fit the open layer's budget are dropped, never written past its row.
renderer_ui_stage_bg :: proc(
	r: ^Renderer,
	x, y, w, h: f32,
	col: [4]f32,
	params: [4]f32 = {0, 0, 0, 0},
) {
	if r == nil || w <= 0 || h <= 0 do return
	layer := r.ui_layer
	n := int(r.ui_layer_bg_count[layer])
	if n >= UI_LAYER_BG_CAPACITY[layer] do return
	r.ui_bg_data[layer][n] = instance.Instance_Data{
		x = x, y = y, cw = w, ch = h,
		u0 = params[0], v0 = params[1], u1 = params[2], v1 = params[3],
		r = col.r, g = col.g, b = col.b, a = col.a,
	}
	r.ui_layer_bg_count[layer] += 1
}

// renderer_ui_can_stage_bg reports whether the open layer still has room for one
// more background quad. Callers that mutate other uniform state use it to bail
// out before doing work they would otherwise have to undo.
renderer_ui_can_stage_bg :: proc(r: ^Renderer) -> bool {
	if r == nil do return false
	layer := r.ui_layer
	return int(r.ui_layer_bg_count[layer]) < UI_LAYER_BG_CAPACITY[layer]
}

// renderer_ui_stage_glyph appends one atlas glyph quad to the open layer.
renderer_ui_stage_glyph :: proc(
	r: ^Renderer,
	x, y, cw, ch: f32,
	cp: rune,
	col: [4]f32,
) {
	if r == nil do return
	layer := r.ui_layer
	n := int(r.ui_layer_glyph_count[layer])
	if n >= UI_LAYER_GLYPH_CAPACITY[layer] do return
	_, s := atlas_get_slot(&r.atlas, u32(cp))
	if !s.valid do return
	r.ui_glyph_data[layer][n] = instance.Instance_Data{
		x = x, y = y, cw = cw, ch = ch,
		u0 = s.u0, v0 = s.v0, u1 = s.u1, v1 = s.v1,
		r = col.r, g = col.g, b = col.b, a = 1.0,
	}
	r.ui_layer_glyph_count[layer] += 1
}

// renderer_ui_layer_plan assigns ascending byte ranges to every layer's
// background and glyph runs starting at base_offset, and returns the end offset.
// Because ranges are handed out in layer order, a higher layer's first instance
// is always drawn after a lower layer's last instance.
renderer_ui_layer_plan :: proc(r: ^Renderer, base_offset: u64, runs: ^[UI_LAYER_COUNT]UI_Layer_Run) -> u64 {
	if r == nil || runs == nil do return base_offset
	offset := base_offset
	for layer in UI_Layer {
		bg := min(int(r.ui_layer_bg_count[layer]), UI_LAYER_BG_CAPACITY[layer])
		glyph := min(int(r.ui_layer_glyph_count[layer]), UI_LAYER_GLYPH_CAPACITY[layer])
		run := &runs[layer]
		run.bg_offset = offset
		run.bg_count = u32(bg)
		offset += u64(bg) * instance.INSTANCE_STRIDE
		run.glyph_offset = offset
		run.glyph_count = u32(glyph)
		offset += u64(glyph) * instance.INSTANCE_STRIDE
	}
	return offset
}

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
	r.background_opacity = 1.0
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

	when ODIN_OS == .Darwin {
		emoji_size := r.cell_height * 0.85
		_ = emoji_atlas_init(&r.emoji_atlas, emoji_size, 1.0)
	}

	// Initialize compiled frame buffer
	render_compiler_init(&r.compiled, rows, cols, allocator)
	ligature_cache_init(&r.ligature_cache)

	// Initialize V2 compiled frame buffer + style LUT (LUT rebuilds on first v2 frame)
	render_compiler_init_v2(&r.compiled_v2, rows, cols, allocator)
	r.style_lut.count = 0

	// Initialize instance renderer with atlas GPU resources
	ok := instance.instance_renderer_init(
		&r.instances,
		backend,
		device,
		queue,
		_renderer_instance_capacity(rows, cols),
		r.atlas.gpu_texture,
		r.atlas.gpu_view,
		format,
		string(BG_MSL),
		string(GLYPH_MSL),
		screen_w,
		screen_h,
		allocator,
	)
	if !ok {
		renderer_destroy(r, allocator)
		return false
	}

	image_attrs := []gpu.Gpu_Vertex_Attribute{
		{format = .Float32x2, offset = 0, shader_location = 0},
		{format = .Float32x2, offset = 8, shader_location = 1},
		{format = .Float32x4, offset = 16, shader_location = 2},
		{format = .Float32x4, offset = 32, shader_location = 3},
	}
	image_layouts := []gpu.Gpu_Vertex_Layout{
		{array_stride = instance.INSTANCE_STRIDE, step_mode = .Instance, attributes = image_attrs},
	}
	image_module := backend.create_shader_module(device, string(IMAGE_MSL))
	r.image_pipeline = backend.create_render_pipeline(
		device, image_module, "vs_main", image_module, "fs_main",
		image_layouts, format, .Alpha_Blend, .Triangle_List,
	)
	backend.destroy_shader_module(image_module)
	if rawptr(r.image_pipeline) == nil {
		renderer_destroy(r, allocator)
		return false
	}
	r.image_bind_group_layout = backend.pipeline_get_bind_group_layout(r.image_pipeline, 0)
	if rawptr(r.image_bind_group_layout) == nil {
		renderer_destroy(r, allocator)
		return false
	}

	if r.emoji_atlas.has_font {
		emoji_atlas_upload_gpu(&r.emoji_atlas, backend, device, queue)
		instance.instance_renderer_init_emoji(
			&r.instances,
			r.emoji_atlas.gpu_texture,
			r.emoji_atlas.gpu_view,
			string(EMOJI_MSL),
			format,
			allocator,
		)
	}

	// Phase 8: persistent dirty-upload buffer; the upload ring is retained
	// as the legacy-fallback carrier and is always initialized so the
	// fallback path has valid buffers.
	dirty_upload_init(&r.dirty, r, allocator)
	upload_ring_init(&r.upload_ring, backend, device, queue, max(u64(RENDER_UPLOAD_CAPACITY), u64(r.instances.max_instances) * instance.INSTANCE_STRIDE), allocator)

	// Phase 12: async raster queue, worker start LAST (after the chain the
	// worker reads and every other subsystem is ready).
	raster_queue_init(&r.raster, &r.raster_counters)
	raster_worker_start(&r.raster, &r.fallback)
	return true
}

_image_texture_cache_release_slot :: proc(r: ^Renderer, slot: ^Image_Texture_Cache_Slot) {
	if r == nil || slot == nil || r.backend == nil do return
	if rawptr(slot.bind_group) != nil {
		r.backend.destroy_bind_group(slot.bind_group)
	}
	if rawptr(slot.view) != nil {
		r.backend.destroy_texture_view(slot.view)
	}
	if rawptr(slot.texture) != nil {
		r.backend.destroy_texture(slot.texture)
	}
	slot^ = Image_Texture_Cache_Slot{}
}

_image_texture_cache_destroy :: proc(r: ^Renderer) {
	if r == nil do return
	for i := 0; i < len(r.image_cache); i += 1 {
		_image_texture_cache_release_slot(r, &r.image_cache[i])
	}
}

_image_texture_cache_evict_unseen :: proc(r: ^Renderer) {
	if r == nil do return
	for i := 0; i < len(r.image_cache); i += 1 {
		slot := &r.image_cache[i]
		if slot.used && slot.last_seen_frame != r.frame_count {
			_image_texture_cache_release_slot(r, slot)
		}
	}
}

_image_texture_cache_evict_namespace :: proc(r: ^Renderer, namespace: u64) {
	if r == nil || namespace == 0 do return
	for i := 0; i < len(r.image_cache); i += 1 {
		slot := &r.image_cache[i]
		if slot.used && slot.key.graphics_namespace == namespace {
			_image_texture_cache_release_slot(r, slot)
		}
	}
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

	atlas_destroy(&r.atlas, r.backend, allocator)
	render_compiler_destroy(&r.compiled, allocator)
	render_compiler_destroy_v2(&r.compiled_v2, allocator)
	if rawptr(r.dirty.buffer) != nil && r.backend != nil {
		r.backend.destroy_buffer(r.dirty.buffer)
		r.dirty.buffer = gpu.Gpu_Buffer(nil)
	}
	dirty_upload_destroy(&r.dirty, allocator)
	upload_ring_destroy(&r.upload_ring, allocator)
	_image_texture_cache_destroy(r)
	if r.backend != nil {
		if rawptr(r.image_pipeline) != nil {
			r.backend.destroy_render_pipeline(r.image_pipeline)
			r.image_pipeline = gpu.Gpu_RenderPipeline(nil)
		}
		if rawptr(r.image_bind_group_layout) != nil {
			r.backend.destroy_bind_group_layout(r.image_bind_group_layout)
			r.image_bind_group_layout = gpu.Gpu_BindGroupLayout(nil)
		}
	}
	instance.instance_renderer_destroy(&r.instances, allocator)
	when ODIN_OS == .Darwin {
		emoji_atlas_destroy(&r.emoji_atlas, r.backend)
	}

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
	when ODIN_OS == .Darwin {
		old.emoji_atlas = r.emoji_atlas
	}
	old.compiled = r.compiled
	old.compiled_v2 = r.compiled_v2
	old.dirty = r.dirty
	old.upload_ring = r.upload_ring
	old.instances = r.instances
	old.image_pipeline = r.image_pipeline
	old.image_bind_group_layout = r.image_bind_group_layout
	old.image_cache = r.image_cache
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
	when ODIN_OS == .Darwin {
		r.emoji_atlas = candidate.emoji_atlas
		candidate.emoji_atlas = Emoji_Atlas{}
	}
	r.compiled = candidate.compiled
	r.compiled_v2 = candidate.compiled_v2
	r.dirty = candidate.dirty
	r.style_lut = candidate.style_lut
	r.upload_ring = candidate.upload_ring
	r.instances = candidate.instances
	r.image_pipeline = candidate.image_pipeline
	r.image_bind_group_layout = candidate.image_bind_group_layout
	r.image_cache = candidate.image_cache
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
	candidate.image_pipeline = gpu.Gpu_RenderPipeline(nil)
	candidate.image_bind_group_layout = gpu.Gpu_BindGroupLayout(nil)
	candidate.image_cache = {}
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

_image_placement_rect :: proc(
	placement: ^graphics_pkg.Placement,
	cell_w, cell_h: f32,
	frame_w, frame_h: u32,
) -> (rect: [4]f32, ok: bool) {
	if placement == nil || !placement.used || cell_w <= 0 || cell_h <= 0 || frame_w == 0 || frame_h == 0 {
		return {}, false
	}
	if placement.src_x >= frame_w || placement.src_y >= frame_h || placement.src_w == 0 || placement.src_h == 0 {
		return {}, false
	}
	src_w := min(placement.src_w, frame_w - placement.src_x)
	src_h := min(placement.src_h, frame_h - placement.src_y)
	if src_w == 0 || src_h == 0 do return {}, false

	width := f32(0)
	height := f32(0)
	if placement.cols > 0 { width = f32(placement.cols) * cell_w }
	if placement.rows > 0 { height = f32(placement.rows) * cell_h }
	if width <= 0 && height <= 0 {
		width, height = f32(src_w), f32(src_h)
	} else if width <= 0 {
		width = height * f32(src_w) / f32(src_h)
	} else if height <= 0 {
		height = width * f32(src_h) / f32(src_w)
	}
	if !(width > 0) || !(height > 0) do return {}, false
	return [4]f32{
		f32(placement.col) * cell_w + f32(placement.cell_x),
		f32(placement.row) * cell_h + f32(placement.cell_y),
		width,
		height,
	}, true
}

_image_placement_uv :: proc(placement: ^graphics_pkg.Placement, frame_w, frame_h: u32) -> (uv: [4]f32, ok: bool) {
	if placement == nil || frame_w == 0 || frame_h == 0 || placement.src_w == 0 || placement.src_h == 0 ||
		placement.src_x >= frame_w || placement.src_y >= frame_h {
		return {}, false
	}
	src_w := min(placement.src_w, frame_w - placement.src_x)
	src_h := min(placement.src_h, frame_h - placement.src_y)
	if src_w == 0 || src_h == 0 do return {}, false
	return [4]f32{
		f32(placement.src_x) / f32(frame_w),
		f32(placement.src_y) / f32(frame_h),
		f32(placement.src_x + src_w) / f32(frame_w),
		f32(placement.src_y + src_h) / f32(frame_h),
	}, true
}

_image_clip_for_pane :: proc(r: ^Renderer, pane: ^Pane_Viewport) -> [4]f32 {
	if r == nil || pane == nil do return {}
	clip := [4]f32{pane.x, pane.y, pane.x + pane.w, pane.y + pane.h}
	if pane.clip_rect[2] > pane.clip_rect[0] && pane.clip_rect[3] > pane.clip_rect[1] {
		clip = {max(clip[0], pane.clip_rect[0]), max(clip[1], pane.clip_rect[1]), min(clip[2], pane.clip_rect[2]), min(clip[3], pane.clip_rect[3])}
	}
	if r.screen_w > 0 && r.screen_h > 0 {
		clip = {max(clip[0], f32(0)), max(clip[1], f32(0)), min(clip[2], r.screen_w), min(clip[3], r.screen_h)}
	}
	if r.surface_w > 0 && r.surface_h > 0 {
		clip = {max(clip[0], f32(0)), max(clip[1], f32(0)), min(clip[2], f32(r.surface_w)), min(clip[3], f32(r.surface_h))}
	}
	return clip
}

_image_draw_precedes :: proc(a, b: Image_Draw) -> bool {
	if a.z != b.z { return a.z < b.z }
	if a.image_id != b.image_id { return a.image_id < b.image_id }
	return a.placement_id < b.placement_id
}

_image_texture_cache_acquire :: proc(
	r: ^Renderer,
	namespace: u64,
	image: ^graphics_pkg.Image_Slot,
) -> (slot_index: int, ok: bool) {
	if r == nil || image == nil || !image.used || namespace == 0 || r.backend == nil ||
		r.backend.create_texture == nil || r.backend.create_texture_view == nil ||
		r.backend.write_texture == nil || rawptr(r.image_bind_group_layout) == nil ||
		r.backend.create_bind_group == nil || rawptr(r.instances.uniform_buffer) == nil ||
		r.backend.create_sampler == nil || rawptr(r.instances.sampler) == nil {
		return -1, false
	}
	if image.frame_count <= 0 || image.current_frame < 0 || image.current_frame >= image.frame_count {
		return -1, false
	}
	frame := &image.frames[image.current_frame]
	if frame.width <= 0 || frame.height <= 0 || frame.data == nil {
		return -1, false
	}
	byte_count := u64(frame.width) * u64(frame.height) * u64(4)
	if u64(len(frame.data)) < byte_count do return -1, false
	key := Image_Texture_Key{graphics_namespace = namespace, image_id = image.id, generation = image.generation}
	free_index := -1
	oldest_index := -1
	oldest_frame: u64 = 0
	oldest_set := false
	for i := 0; i < len(r.image_cache); i += 1 {
		slot := &r.image_cache[i]
		if !slot.used {
			if free_index < 0 { free_index = i }
			continue
		}
		if slot.key == key {
			slot.last_seen_frame = r.frame_count
			return i, true
		}
		if slot.key.graphics_namespace == namespace && slot.key.image_id == image.id {
			_image_texture_cache_release_slot(r, slot)
			if free_index < 0 { free_index = i }
			continue
		}
		if !oldest_set || slot.last_seen_frame < oldest_frame {
			oldest_frame = slot.last_seen_frame
			oldest_index = i
			oldest_set = true
		}
	}
	if free_index < 0 { free_index = oldest_index }
	if free_index < 0 do return -1, false
	_image_texture_cache_release_slot(r, &r.image_cache[free_index])

	texture := r.backend.create_texture(
		r.device, u32(frame.width), u32(frame.height), .RGBA8_Unorm,
		gpu.Gpu_Texture_Usage.Texture_Binding | gpu.Gpu_Texture_Usage.Copy_Dst,
	)
	if rawptr(texture) == nil do return -1, false
	view := r.backend.create_texture_view(texture)
	if rawptr(view) == nil {
		r.backend.destroy_texture(texture)
		return -1, false
	}
	entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, buffer = r.instances.uniform_buffer, offset = 0, size = size_of(instance.Uniform_Data), entry_type = .Buffer},
		{binding = 1, view = view, entry_type = .Texture_View},
		{binding = 2, sampler = r.instances.sampler, entry_type = .Sampler},
	}
	bind_group := r.backend.create_bind_group(r.device, r.image_bind_group_layout, entries)
	if rawptr(bind_group) == nil {
		r.backend.destroy_texture_view(view)
		r.backend.destroy_texture(texture)
		return -1, false
	}
	r.backend.write_texture(r.queue, texture, frame.data[:int(byte_count)], u32(frame.width), u32(frame.height))
	r.image_cache[free_index] = Image_Texture_Cache_Slot{
		used = true, key = key, texture = texture, view = view, bind_group = bind_group,
		width = u32(frame.width), height = u32(frame.height), last_seen_frame = r.frame_count,
	}
	return free_index, true
}

_renderer_stage_images_for_pane :: proc(r: ^Renderer, pane: ^Pane_Viewport) -> bool {
	if r == nil || pane == nil || pane.terminal == nil do return false
	store := termgrid.terminal_graphics_active(pane.terminal)
	if store == nil do return true
	namespace := pane.terminal.graphics_namespace
	if r.staged_graphics_store != nil && r.staged_graphics_store != store &&
		r.staged_graphics_namespace == namespace {
		_image_texture_cache_evict_namespace(r, namespace)
	}
	clip := _image_clip_for_pane(r, pane)
	for i := 0; i < graphics_pkg.KGP_MAX_PLACEMENTS; i += 1 {
		placement := &store.placements[i]
		if !placement.used do continue
		image := graphics_pkg.store_find_image(store, placement.image_id, placement.image_number)
		if image == nil || !image.used || image.frame_count <= 0 || image.current_frame < 0 || image.current_frame >= image.frame_count do continue
		frame := &image.frames[image.current_frame]
		rect, rect_ok := _image_placement_rect(placement, r.cell_width, r.cell_height, u32(frame.width), u32(frame.height))
		uv, uv_ok := _image_placement_uv(placement, u32(frame.width), u32(frame.height))
		if !rect_ok || !uv_ok do continue
		slot, slot_ok := _image_texture_cache_acquire(r, namespace, image)
		if !slot_ok do return false
		if r.image_count >= u32(len(r.image_instances)) do return false
		index := r.image_count
		r.image_instances[index] = instance.Instance_Data{
			x = pane.x + rect[0], y = pane.y + rect[1], cw = rect[2], ch = rect[3],
			u0 = uv[0], v0 = uv[1], u1 = uv[2], v1 = uv[3],
			r = 1, g = 1, b = 1, a = clamp(pane.dim_factor, f32(0), f32(1)),
		}
		if !_clip_instance_rect(&r.image_instances[index], clip, true) do continue
		draw := Image_Draw{used = true, placement_id = placement.placement_id, image_id = image.id, z = placement.z, cache_slot = slot, instance_index = index}
		insert := int(r.image_count)
		for insert > 0 && _image_draw_precedes(draw, r.image_draws[insert-1]) {
			r.image_draws[insert] = r.image_draws[insert-1]
			insert -= 1
		}
		r.image_draws[insert] = draw
		r.image_count += 1
	}
	for i := 0; i < int(r.image_count); i += 1 {
		if r.image_draws[i].z >= 0 {
			r.image_under_count = u32(i)
			break
		}
		if i == int(r.image_count)-1 { r.image_under_count = r.image_count }
	}
	r.staged_graphics_store = store
	r.staged_graphics_namespace = namespace
	r.staged_graphics_epoch = store.epoch
	r.staged_graphics_placement_epoch = store.placement_epoch
	r.staged_graphics_valid = true
	return true
}

_renderer_stage_images_for_panes :: proc(r: ^Renderer, panes: []Pane_Viewport) -> bool {
	if r == nil do return false
	r.image_count = 0
	r.image_under_count = 0
	_image_texture_cache_evict_unseen(r)
	for &pane in panes {
		if !_renderer_stage_images_for_pane(r, &pane) do return false
	}
	return true
}

// renderer_image_focus_draw stages a focused image and its scrim. It runs on
// the render thread after the event loop, so cache misses may upload through
// the existing TG3 cache while event dispatch remains GPU-free.
renderer_image_focus_draw :: proc(
	r: ^Renderer,
	focus: ^interaction.Image_Focus_State,
	panes: []Pane_Viewport,
	fallback_terminal: ^termgrid.Terminal = nil,
) -> bool {
	if r == nil do return false
	r.image_focus_staged = false
	r.image_focus_cache_slot = -1
	if focus == nil || !focus.active do return true

	found_store: ^graphics_pkg.Store = nil
	found_image: ^graphics_pkg.Image_Slot = nil
	for &pane in panes {
		if pane.terminal == nil || pane.terminal.graphics_namespace != focus.namespace do continue
		store := termgrid.terminal_graphics_active(pane.terminal)
		image := graphics_pkg.store_find_image(store, focus.image_id, 0)
		if store != nil && image != nil && image.used && image.generation == focus.generation {
			found_store = store
			found_image = image
			break
		}
	}
	if found_image == nil && fallback_terminal != nil && fallback_terminal.graphics_namespace == focus.namespace {
		found_store = termgrid.terminal_graphics_active(fallback_terminal)
		found_image = graphics_pkg.store_find_image(found_store, focus.image_id, 0)
		if found_image == nil || !found_image.used || found_image.generation != focus.generation {
			found_store = nil
			found_image = nil
		}
	}
	if found_store == nil || found_image == nil || found_image.frame_count <= 0 ||
		found_image.current_frame < 0 || found_image.current_frame >= found_image.frame_count {
		return true
	}
	frame := &found_image.frames[found_image.current_frame]
	if frame.width <= 0 || frame.height <= 0 || len(frame.data) == 0 do return true
	slot, slot_ok := _image_texture_cache_acquire(r, focus.namespace, found_image)
	if !slot_ok do return false

	focused := focus^
	interaction.image_focus_clamp_for_view(&focused, r.screen_w, r.screen_h, f32(frame.width), f32(frame.height))
	rect, rect_ok := interaction.image_focus_rect(focused, r.screen_w, r.screen_h, f32(frame.width), f32(frame.height))
	if !rect_ok do return true
	r.image_focus_instance = instance.Instance_Data{
		x = rect[0], y = rect[1], cw = rect[2], ch = rect[3],
		u0 = 0, v0 = 0, u1 = 1, v1 = 1,
		r = 1, g = 1, b = 1, a = 1,
	}
	if !_clip_instance_rect(&r.image_focus_instance, {0, 0, r.screen_w, r.screen_h}, true) do return true
	r.image_focus_cache_slot = slot
	r.image_focus_staged = true

	// The scrim is an Overlay-layer quad; the focused texture is emitted after
	// all UI layers in _draw_instance_buffer, keeping the image above chrome.
	renderer_ui_begin_layer(r, .Overlay)
	renderer_ui_stage_bg(r, 0, 0, r.screen_w, r.screen_h, {0, 0, 0, 0.52})
	r.ui_staged = true
	return true
}

_renderer_stage_images_for_terminal :: proc(r: ^Renderer, terminal: ^termgrid.Terminal) -> bool {
	if r == nil || terminal == nil do return false
	r.image_count = 0
	r.image_under_count = 0
	_image_texture_cache_evict_unseen(r)
	store := termgrid.terminal_graphics_active(terminal)
	if store == nil do return true
	if r.last_graphics_store != nil && r.last_graphics_store != store {
		_image_texture_cache_evict_namespace(r, terminal.graphics_namespace)
	}
	pane := Pane_Viewport{
		terminal = terminal, x = r.pad_x, y = r.pad_y,
		w = max(r.screen_w - r.pad_x, f32(0)), h = max(r.screen_h - r.pad_y, f32(0)),
		rows = terminal.grid.row_count, cols = terminal.grid.col_count, dim_factor = 1,
	}
	ok := _renderer_stage_images_for_pane(r, &pane)
	r.staged_graphics_store = store
	r.staged_graphics_namespace = terminal.graphics_namespace
	r.staged_graphics_epoch = store.epoch
	r.staged_graphics_placement_epoch = store.placement_epoch
	r.staged_graphics_valid = true
	return ok
}

_renderer_graphics_changed :: proc(r: ^Renderer, terminal: ^termgrid.Terminal) -> bool {
	if r == nil || terminal == nil do return false
	store := termgrid.terminal_graphics_active(terminal)
	if store == nil { return r.last_graphics_valid }
	if !r.last_graphics_valid {
		return store.image_count > 0 || store.placement_count > 0 || store.epoch != 0 || store.placement_epoch != 0
	}
	return r.last_graphics_store != store ||
		r.last_graphics_namespace != terminal.graphics_namespace ||
		r.last_graphics_epoch != store.epoch || r.last_graphics_placement_epoch != store.placement_epoch
}

_renderer_terminal_has_graphics :: proc(r: ^Renderer, terminal: ^termgrid.Terminal) -> bool {
	if terminal == nil do return false
	store := termgrid.terminal_graphics_active(terminal)
	return _renderer_graphics_changed(r, terminal) || (store != nil && (store.image_count > 0 || store.placement_count > 0))
}

// renderer_frame_panes processes a multi-pane layout into a single frame.
renderer_frame_panes :: proc(
	r:     ^Renderer,
	panes: []Pane_Viewport,
	lut:   ^Style_LUT = nil,
) -> bool {
	if r == nil || len(panes) == 0 {
		return false
	}
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil ||
		rawptr(r.instances.bg_pipeline) == nil || rawptr(r.instances.glyph_pipeline) == nil {
		return false
	}
	active_term: ^termgrid.Terminal = nil
	active_view: ^termgrid.Terminal_View = nil
	grid_limit := min(int(r.instances.max_instances) - 1, len(r.instances.instance_data))
	if r.interaction_staged { grid_limit = min(grid_limit, int(r.interaction_slot_start)) }
	needed := 0
	for p in panes {
		if p.terminal == nil || p.rows <= 0 || p.cols <= 0 || !(p.w > 0) || !(p.h > 0) {
			return false
		}
		// Each cell can emit a background, glyph and decoration. Reject
		// insufficient storage before touching staged overlays or damage.
		if grid_limit < 0 || p.rows > max(0, grid_limit - 1) / 3 / p.cols { return false }
		needed += p.rows * p.cols * 3 + 1
		if needed > grid_limit { return false }
		if active_term == nil || p.is_active {
			active_term = p.terminal
			active_view = p.view
		}
	}
	if !r.frame_prepared { renderer_prepare_frame(r, active_term) }
	r.frame_prepared = false
	// Pane journals and borrowed terminal state remain protected through
	// publication or failure restoration.
	unlock_cb, unlock_data := r.unlock_cb, r.unlock_data
	r.unlock_cb = nil
	defer {
		r.unlock_cb, r.unlock_data = unlock_cb, unlock_data
		if unlock_cb != nil { unlock_cb(unlock_data) }
	}
	r.frame_count += 1
	lut_ptr := lut != nil ? lut : &r.style_lut
	journals := make([]termgrid.Damage_Journal, len(panes), context.temp_allocator)
	published := false
	defer {
		for i in 0 ..< len(panes) {
			if !published { termgrid.damage_requeue_journal(&panes[i].terminal.damage, &journals[i]) }
			termgrid.damage_journal_destroy(&journals[i])
		}
	}
	for i in 0 ..< len(panes) { journals[i] = termgrid.terminal_take_damage(panes[i].terminal) }

	compiled_panes := make([]Compiled_Frame_V2, len(panes), context.temp_allocator)
	for i in 0 ..< len(panes) {
		p := &panes[i]
		render_compiler_init_v2(&compiled_panes[i], i32(p.rows), i32(p.cols), context.temp_allocator)
		render_compile_full_v2(&compiled_panes[i], p.terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster, p.view)
	}

	r.dirty.armed = false
	if !_renderer_stage_images_for_panes(r, panes) {
		return false
	}
	bg_count, glyph_count, emoji_count, decor_count := _prepare_pane_instances_v2(r, lut_ptr, panes, compiled_panes)

	when ODIN_OS == .Darwin {
		if r.emoji_atlas.gpu_dirty {
			emoji_atlas_upload_gpu(&r.emoji_atlas, r.backend, r.device, r.queue)
		}
		if emoji_count > 0 && rawptr(r.instances.emoji_buffer) != nil && r.instances.emoji_data != nil {
			r.backend.write_buffer(r.queue, r.instances.emoji_buffer, 0, raw_data(r.instances.emoji_data), u64(emoji_count) * instance.INSTANCE_STRIDE)
		}
	}
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}

	frame, ok := _renderer_surface_begin(r)
	if !ok {
		return false
	}
	if !_renderer_upload_instances(r, bg_count + glyph_count + decor_count, &frame, r.image_count) {
		_renderer_surface_abort(r, &frame)
		return false
	}
	decor_offset := u64(bg_count + glyph_count) * instance.INSTANCE_STRIDE
	if !_draw_instance_buffer(r, &frame, frame.cursor_buffer, bg_count, glyph_count, u64(bg_count) * instance.INSTANCE_STRIDE, emoji_count, false, decor_count, decor_offset, true, r.image_under_count, r.image_count - r.image_under_count) {
		_renderer_surface_abort(r, &frame)
		return false
	}
	if !_renderer_surface_commit(r, &frame) {
		return false
	}
	r.full_redraw_pending = false
	published = true
	_renderer_frame_published(r, active_view)
	return true
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
	h = mix(h, view.selection.block ? u64(1) : u64(0))
	h = mix(h, u64(view.selection.anchor.row))
	h = mix(h, u64(view.selection.anchor.col))
	h = mix(h, u64(view.selection.focus.row))
	h = mix(h, u64(view.selection.focus.col))
	h = mix(h, view.visual_mode ? u64(1) : u64(0))
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

_renderer_visual_background_color :: proc(base_bg: u32) -> u32 {
	a := (base_bg >> 24) & 0xFF
	r := (base_bg >> 16) & 0xFF
	g := (base_bg >> 8) & 0xFF
	b := base_bg & 0xFF

	new_r := u32((int(r) * 65 + 0x18 * 35) / 100)
	new_g := u32((int(g) * 65 + 0x28 * 35) / 100)
	new_b := u32((int(b) * 65 + 0x55 * 35) / 100)

	return (a << 24) | (new_r << 16) | (new_g << 8) | new_b
}

_renderer_default_background_alpha :: proc(argb: u32, opacity: f32) -> f32 {
	normalized_opacity := clamp(opacity, f32(0), f32(1))
	return f32((argb >> 24) & 0xFF) / 255.0 * normalized_opacity
}

_renderer_theme_clear_color :: proc(theme: termgrid.Theme, visual_mode: bool = false, opacity: f32 = 1.0) -> [4]f64 {
	argb := theme.background
	if visual_mode {
		argb = _renderer_visual_background_color(theme.background)
	}
	// The drawable is composited as premultiplied alpha. Instance blending
	// adds straight-source glyphs over this premultiplied destination.
	alpha := f64(_renderer_default_background_alpha(argb, opacity))
	return [4]f64{
		f64((argb >> 16) & 0xFF) / 255.0 * alpha,
		f64((argb >> 8) & 0xFF) / 255.0 * alpha,
		f64(argb & 0xFF) / 255.0 * alpha,
		alpha,
	}
}

// _renderer_sync_bg_opacity pushes the effective default-background alpha into
// the fullscreen and tiled-compute params uniforms, rewriting only on change.
_renderer_sync_bg_opacity :: proc(r: ^Renderer, theme_background: u32) {
	if r == nil {
		return
	}
	effective_opacity := _renderer_default_background_alpha(theme_background, r.background_opacity)
	if r.fullscreen.bg_opacity != effective_opacity || r.fullscreen.cell_opacity != r.background_opacity {
		r.fullscreen.cell_opacity = r.background_opacity
		r.fullscreen.bg_opacity = effective_opacity
		fullscreen.fullscreen_write_params(&r.fullscreen)
	}
	if r.compute_tiles.bg_opacity != effective_opacity || r.compute_tiles.cell_opacity != r.background_opacity {
		r.compute_tiles.cell_opacity = r.background_opacity
		r.compute_tiles.bg_opacity = effective_opacity
		tile.compute_tile_write_params(&r.compute_tiles)
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
		_renderer_view_changed(r, view) || _renderer_graphics_changed(r, terminal) || r.ui_staged || r.interaction_staged {
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
	frame.drawable_outstanding = true
	frame.state = .Acquired
	return frame, true
}

// _surface_abort_note surfaces the first few abandoned frames. A run of aborts
// is the precondition for drawable pool exhaustion, which shows up as a window
// that never recovers, so it must not pass silently.
@(private)
_renderer_note_surface_abort :: proc(count: u32) {
	if count <= 5 {
		diag.diag_warn("renderer: surface frame abandoned (#%d); its drawable was handed back to the layer without being drawn into", count)
	}
}

_renderer_surface_abort :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction) {
	if frame == nil || frame.state == .Released || frame.state == .Aborted {
		return
	}
	// A frame that never reaches present still holds the drawable it acquired in
	// _renderer_surface_begin, and CAMetalLayer only returns a drawable to its
	// pool once that drawable has been presented. release_surface_texture frees
	// only the wrapper structs, not the drawable, so an abandoned frame used to
	// consume one of the layer's few pool slots permanently. Once those are gone
	// nextDrawable() blocks with no way out, which is what turned a transient
	// render failure into a permanently frozen window. Present it here so the slot
	// returns to the pool; the frame was never drawn into, so the presented content
	// is simply the previous one.
	if frame.drawable_outstanding && r != nil && r.backend != nil && r.backend.present_surface != nil && rawptr(r.surface) != nil {
		frame.drawable_outstanding = false
		r.surface_reclaims += 1
		_renderer_note_surface_abort(r.surface_reclaims)
		_ = r.backend.present_surface(rawptr(r.surface))
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
	
	if r.unlock_cb != nil {
		r.unlock_cb(r.unlock_data)
	}
	
	// The drawable is handed back to the layer here. The flag is cleared BEFORE
	// the call so that a present which fails does not get retried from the abort
	// path; the attempt itself is what returns the drawable to the pool.
	frame.drawable_outstanding = false
	if !r.backend.present_surface(rawptr(r.surface)) {
		_renderer_surface_abort(r, frame)
		return false
	}
	frame.state = .Presented
	r.backend.release_surface_texture(frame.texture, frame.view)
	frame.texture = gpu.Gpu_Texture(nil)
	frame.view = gpu.Gpu_TextureView(nil)
	frame.state = .Released

	if r.backend != nil && r.backend.poll_device != nil && rawptr(r.device) != nil {
		_ = r.backend.poll_device(r.device, false)
	}

	return true
}

_renderer_upload_instances :: proc(r: ^Renderer, base_count: u32, frame: ^Render_Frame_Transaction, image_count: u32 = 0) -> bool {
	if r == nil || frame == nil { return false }
	count := u64(base_count)
	focus_count: u64 = 1 if r.image_focus_staged else 0
	cursor_count: u64 = 0
	if r.cursor_staged { cursor_count = 1 }
	interaction_count: u64 = 0
	if r.interaction_staged && r.interaction_quad_count > 0 { interaction_count = u64(r.interaction_quad_count) }
	scrollbar_count: u64 = 0
	if r.scrollbar_staged && r.scrollbar_count > 0 { scrollbar_count = u64(r.scrollbar_count) }
	// Each layer owns a private sub-array; the plan hands out ascending byte
	// ranges so the copy order below is the paint order. An unstaged frame still
	// copies nothing, so the runs stay zeroed.
	ui_runs: [UI_LAYER_COUNT]UI_Layer_Run = {}
	ui_instances: u64 = 0
	if r.ui_staged {
		ui_instances = (renderer_ui_layer_plan(r, 0, &ui_runs)) / instance.INSTANCE_STRIDE
	}
	total := count + u64(image_count) + focus_count + cursor_count + interaction_count + scrollbar_count + ui_instances
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
	frame.image_offset = 0
	frame.image_count = image_count
	frame.focus_image_offset = 0
	frame.focus_image_count = u32(focus_count)
	frame.interaction_offset = 0
	frame.interaction_count = 0
	frame.scrollbar_offset = 0
	frame.scrollbar_count = 0
	for layer in UI_Layer {
		frame.ui_bg_offset[layer] = 0
		frame.ui_bg_count[layer] = 0
		frame.ui_glyph_offset[layer] = 0
		frame.ui_glyph_count[layer] = 0
	}

	offset := int(count * instance.INSTANCE_STRIDE)
	if image_count > 0 {
		if image_count > u32(len(r.image_instances)) {
			upload_ring_abort(&r.upload_ring, &frame.upload)
			return false
		}
		frame.image_offset = u64(offset)
		bytes := int(u64(image_count) * instance.INSTANCE_STRIDE)
		mem.copy(raw_data(staging[offset:]), raw_data(r.image_instances[:]), bytes)
		offset += bytes
	}
	if focus_count > 0 {
		frame.focus_image_offset = u64(offset)
		mem.copy(raw_data(staging[offset:]), &r.image_focus_instance, int(instance.INSTANCE_STRIDE))
		offset += int(instance.INSTANCE_STRIDE)
	}
	if cursor_count > 0 {
		slot := r.instances.max_instances - 1
		if slot >= u32(len(r.instances.instance_data)) {
			upload_ring_abort(&r.upload_ring, &frame.upload)
			return false
		}
		mem.copy(raw_data(staging[offset:]), &r.instances.instance_data[slot], int(instance.INSTANCE_STRIDE))
		frame.cursor_offset = u64(offset)
		offset += int(instance.INSTANCE_STRIDE)
	}
	if interaction_count > 0 {
		slot := r.interaction_slot_start
		if int(slot) + int(interaction_count) <= len(r.instances.instance_data) {
			frame.interaction_offset = u64(offset)
			frame.interaction_count = u32(interaction_count)
			bytes := int(interaction_count * instance.INSTANCE_STRIDE)
			mem.copy(raw_data(staging[offset:]), &r.instances.instance_data[slot], bytes)
			offset += bytes
		}
	}
	if scrollbar_count > 0 {
		frame.scrollbar_offset = u64(offset)
		frame.scrollbar_count = u32(scrollbar_count)
		bytes := int(scrollbar_count * instance.INSTANCE_STRIDE)
		mem.copy(raw_data(staging[offset:]), raw_data(r.scrollbar_data[:]), bytes)
		offset += bytes
	}
	for layer in UI_Layer {
		run := ui_runs[layer]
		if run.bg_count > 0 {
			frame.ui_bg_offset[layer] = u64(offset)
			frame.ui_bg_count[layer] = run.bg_count
			ui_bg_bytes := int(run.bg_count) * instance.INSTANCE_STRIDE
			mem.copy(raw_data(staging[offset:]), raw_data(r.ui_bg_data[layer][:]), ui_bg_bytes)
			offset += ui_bg_bytes
		}
		if run.glyph_count > 0 {
			frame.ui_glyph_offset[layer] = u64(offset)
			frame.ui_glyph_count[layer] = run.glyph_count
			ui_glyph_bytes := int(run.glyph_count) * instance.INSTANCE_STRIDE
			mem.copy(raw_data(staging[offset:]), raw_data(r.ui_glyph_data[layer][:]), ui_glyph_bytes)
			offset += ui_glyph_bytes
		}
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
	grid_limit := inst.max_instances > 1 ? inst.max_instances - 1 : 0

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
		if bg_count < grid_limit {
			bg_r, bg_g, bg_b := instance.unpack_r5g6b5(bg_packed)
			instance.instance_renderer_fill_bg(inst, bg_count, x, y, cell_w, cell_h, bg_r, bg_g, bg_b)
			bg_count += 1
		}

		// Glyph instance (skip spaces)
		if codepoint != 0x20 && glyph_count < grid_limit {
			slot_idx, slot := atlas_get_slot(atlas, codepoint)
			fg_r, fg_g, fg_b := instance.unpack_r5g6b5(fg_packed)

			if !slot.valid && codepoint >= CONTENT_LIGATURE_BASE && codepoint < 0x1FFFFF {
				_atlas_rasterize_into_slot(atlas, &r.rasterizer, codepoint, slot_idx, true)
			}

			if slot.valid {
				glyph_idx := bg_count + glyph_count
				if glyph_idx < grid_limit {
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
// Three passes partition the staging buffer as [bg 0..bg_count), [glyph bg_count..bg_count+glyph_count),
// and [decor bg_count+glyph_count..bg_count+glyph_count+decor_count), matching the draw offsets below.
// Writes are capped at max_instances.
_prepare_instances_v2 :: proc(
	r: ^Renderer,
	lut: ^Style_LUT,
	store: ^termgrid.Grapheme_Store = nil,
	terminal: ^termgrid.Terminal = nil,
	view: ^termgrid.Terminal_View = nil,
) -> (bg_count: u32, glyph_count: u32, emoji_count: u32, decor_count: u32) {
	cells := r.compiled_v2.cells
	cols := r.cols
	cell_w := r.cell_width
	cell_h := r.cell_height
	atlas := &r.atlas
	inst := &r.instances

	bg_count = 0
	glyph_count = 0
	emoji_count = 0
	decor_count = 0
	grid_limit := inst.max_instances > 1 ? inst.max_instances - 1 : 0

	// Pass 1: backgrounds, densely packed from index 0.
	for idx in 0..<len(cells) {
		if bg_count >= grid_limit {
			break
		}
		row := i32(idx) / cols
		col := i32(idx) % cols
		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		dc := termgrid.terminal_view_get_direct_color(terminal, view, int(row), int(col))
		emit_bg, _, _, _ := render_cell_expand_instance(
			cells[idx], lut, atlas, x, y, cell_w, cell_h,
			&inst.instance_data[bg_count], nil,
			direct_color = dc,
			background_opacity = r.background_opacity,
		)
		if emit_bg {
			bg_count += 1
		}
	}

	// Pass 2: glyphs and emojis
	for idx in 0..<len(cells) {
		glyph_idx := bg_count + glyph_count
		if glyph_idx >= grid_limit {
			break
		}
		row := i32(idx) / cols
		col := i32(idx) % cols
		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		emoji_inst_ptr: ^instance.Instance_Data = nil
		emoji_atlas_ptr: ^Emoji_Atlas = nil
		if r.emoji_atlas.has_font {
			if emoji_count < grid_limit && inst.emoji_data != nil {
				emoji_inst_ptr = &inst.emoji_data[emoji_count]
			}
			emoji_atlas_ptr = &r.emoji_atlas
		}

		dc := termgrid.terminal_view_get_direct_color(terminal, view, int(row), int(col))
		_, emit_glyph, emit_emoji, _ := render_cell_expand_instance(
			cells[idx], lut, atlas, x, y, cell_w, cell_h,
			nil, &inst.instance_data[glyph_idx],
			emoji_inst_ptr,
			emoji_atlas_ptr,
			store,
			direct_color = dc,
			background_opacity = r.background_opacity,
		)
		if emit_emoji {
			emoji_count += 1
		} else if emit_glyph {
			glyph_count += 1
		}
	}

	// Pass 3: decorations (underline, strikethrough)
	for idx in 0..<len(cells) {
		decor_idx := bg_count + glyph_count + decor_count
		if decor_idx >= grid_limit {
			break
		}
		row := i32(idx) / cols
		col := i32(idx) % cols
		x := r.pad_x + f32(col) * cell_w
		y := r.pad_y + f32(row) * cell_h

		dc := termgrid.terminal_view_get_direct_color(terminal, view, int(row), int(col))
		_, _, _, emit_decor := render_cell_expand_instance(
			cells[idx], lut, atlas, x, y, cell_w, cell_h,
			nil, nil, nil, nil, nil,
			&inst.instance_data[decor_idx],
			direct_color = dc,
			background_opacity = r.background_opacity,
		)
		if emit_decor {
			decor_count += 1
		}
	}

	return bg_count, glyph_count, emoji_count, decor_count
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
	r.ui_staged = false
	renderer_ui_reset(r)
	r.interaction_staged = false
	r.interaction_slot_start = 0
	r.interaction_quad_count = 0
	r.scrollbar_staged = false
	r.scrollbar_count = 0
	r.last_view = view
	r.last_view_fingerprint = _renderer_view_fingerprint(view)
	r.last_view_valid = true
	if r.staged_graphics_valid {
		r.last_graphics_store = r.staged_graphics_store
		r.last_graphics_namespace = r.staged_graphics_namespace
		r.last_graphics_epoch = r.staged_graphics_epoch
		r.last_graphics_placement_epoch = r.staged_graphics_placement_epoch
		r.last_graphics_valid = true
		r.staged_graphics_valid = false
	}
	r.image_count = 0
	r.image_under_count = 0
	r.image_focus_staged = false
	r.image_focus_cache_slot = -1
}

_draw_image_range :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction, start, count: u32) -> bool {
	if count == 0 do return true
	if r == nil || frame == nil || r.backend == nil || rawptr(frame.pass) == nil ||
		rawptr(r.image_pipeline) == nil || rawptr(frame.cursor_buffer) == nil {
		return false
	}
	if start + count > r.image_count do return false
	for i in start ..< start + count {
		draw := r.image_draws[i]
		if !draw.used || draw.cache_slot < 0 || draw.cache_slot >= len(r.image_cache) do return false
		slot := &r.image_cache[draw.cache_slot]
		if !slot.used || rawptr(slot.bind_group) == nil do return false
		r.backend.render_set_pipeline(frame.pass, r.image_pipeline)
		r.backend.render_set_bind_group(frame.pass, 0, slot.bind_group)
		r.backend.render_set_vertex_buffer(frame.pass, 0, frame.cursor_buffer, frame.image_offset + u64(draw.instance_index) * instance.INSTANCE_STRIDE)
		r.backend.render_draw(frame.pass, instance.QUAD_VERTEX_COUNT, 1)
	}
	return true
}

// _draw_instance_buffer encodes bg, glyph, and optional cursor draws into the
// transaction's single render pass. It does not finish, submit, present, or
// release the acquired surface.
_draw_image_focus :: proc(r: ^Renderer, frame: ^Render_Frame_Transaction) -> bool {
	if r == nil || frame == nil || !r.image_focus_staged || frame.focus_image_count == 0 do return true
	if r.backend == nil || rawptr(frame.pass) == nil || rawptr(r.image_pipeline) == nil ||
		r.image_focus_cache_slot < 0 || r.image_focus_cache_slot >= len(r.image_cache) {
		return false
	}
	slot := &r.image_cache[r.image_focus_cache_slot]
	if !slot.used || rawptr(slot.bind_group) == nil do return false
	r.backend.render_set_pipeline(frame.pass, r.image_pipeline)
	r.backend.render_set_bind_group(frame.pass, 0, slot.bind_group)
	r.backend.render_set_vertex_buffer(frame.pass, 0, frame.cursor_buffer, frame.focus_image_offset)
	r.backend.render_draw(frame.pass, instance.QUAD_VERTEX_COUNT, 1)
	return true
}

_draw_instance_buffer :: proc(
	r: ^Renderer,
	frame: ^Render_Frame_Transaction,
	buffer: gpu.Gpu_Buffer,
	bg_count: u32,
	glyph_count: u32,
	glyph_offset: u64,
	emoji_count: u32 = 0,
	visual_mode: bool = false,
	decor_count: u32 = 0,
	decor_offset: u64 = 0,
	transparent_clear: bool = false,
	image_under_count: u32 = 0,
	image_over_count: u32 = 0,
) -> bool {
	if r == nil || frame == nil || frame.state != .Acquired || rawptr(frame.encoder) == nil {
		return false
	}
	instance.instance_renderer_upload_uniforms(&r.instances)
	clear_color := _renderer_theme_clear_color(r.theme, visual_mode, r.background_opacity)
	if transparent_clear {
		clear_color = {}
	}
	pass := r.backend.begin_render_pass(frame.encoder, frame.view, clear_color, .Clear)
	if rawptr(pass) == nil { return false }
	frame.pass = pass
	ok := _draw_image_range(r, frame, 0, image_under_count)
	if bg_count > 0 || glyph_count > 0 || decor_count > 0 {
		ok = rawptr(buffer) != nil && rawptr(r.instances.bg_pipeline) != nil && rawptr(r.instances.glyph_pipeline) != nil &&
			rawptr(r.instances.bind_group_bg) != nil && rawptr(r.instances.bind_group_glyph) != nil
	}
	if ok {
		r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
		r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
		r.backend.render_set_vertex_buffer(pass, 0, buffer, 0)
		r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, bg_count)

		if decor_count > 0 {
			r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
			r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
			r.backend.render_set_vertex_buffer(pass, 0, buffer, decor_offset)
			r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, decor_count)
		}

		if ok && frame.interaction_count > 0 {
			r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
			r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
			r.backend.render_set_vertex_buffer(pass, 0, buffer, frame.interaction_offset)
			r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, frame.interaction_count)
		}

		r.backend.render_set_pipeline(pass, r.instances.glyph_pipeline)
		r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_glyph)
		r.backend.render_set_vertex_buffer(pass, 0, buffer, glyph_offset)
		r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, glyph_count)

		when ODIN_OS == .Darwin {
			if emoji_count > 0 && rawptr(r.instances.emoji_pipeline) != nil && rawptr(r.instances.emoji_buffer) != nil {
				r.backend.render_set_pipeline(pass, r.instances.emoji_pipeline)
				r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_emoji)
				r.backend.render_set_vertex_buffer(pass, 0, r.instances.emoji_buffer, 0)
				r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, emoji_count)
			}
		}
	}
	if ok { ok = _draw_image_range(r, frame, image_under_count, image_over_count) }
	if ok { ok = _draw_cursor_overlay(r, frame) }
	if ok && frame.scrollbar_count > 0 {
		r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
		r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
		r.backend.render_set_vertex_buffer(pass, 0, buffer, frame.scrollbar_offset)
		r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, frame.scrollbar_count)
	}
	// Ascending layer order is the compositing contract: each layer paints its
	// backgrounds, then its glyphs, before the next layer starts.
	for layer in UI_Layer {
		if ok && frame.ui_bg_count[layer] > 0 {
			r.backend.render_set_pipeline(pass, r.instances.bg_pipeline)
			r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_bg)
			r.backend.render_set_vertex_buffer(pass, 0, buffer, frame.ui_bg_offset[layer])
			r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, frame.ui_bg_count[layer])
		}
		if ok && frame.ui_glyph_count[layer] > 0 {
			r.backend.render_set_pipeline(pass, r.instances.glyph_pipeline)
			r.backend.render_set_bind_group(pass, 0, r.instances.bind_group_glyph)
			r.backend.render_set_vertex_buffer(pass, 0, buffer, frame.ui_glyph_offset[layer])
			r.backend.render_draw(pass, instance.QUAD_VERTEX_COUNT, frame.ui_glyph_count[layer])
		}
	}
	if ok { ok = _draw_image_focus(r, frame) }
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
	when ODIN_OS == .Darwin {
		if r.emoji_atlas.gpu_dirty {
			emoji_atlas_upload_gpu(&r.emoji_atlas, r.backend, r.device, r.queue)
		}
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
	force_full := r.full_redraw_pending || view_changed || _renderer_graphics_changed(r, terminal) ||
		(view != nil && (view.scrollback_offset != 0 || view.selection.active)) || len(journal.scroll_ops) > 0
	alt_screen_changed := r.last_is_alt_screen != terminal.is_alt_screen
	if alt_screen_changed {
		r.last_is_alt_screen = terminal.is_alt_screen
		r.dirty.armed = false
		force_full = true
	}
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

	is_visual := view != nil && view.visual_mode
	if is_visual {
		lut.bg_r5g6b5[0] = color_to_r5g6b5(_renderer_visual_background_color(terminal.grid.style_table.theme.background))
	} else {
		lut.bg_r5g6b5[0] = color_to_r5g6b5(terminal.grid.style_table.theme.background)
	}

	if !_renderer_stage_images_for_terminal(r, terminal) {
		return _renderer_frame_unavailable(r, terminal, journal, .Instance)
	}

	if !force_full && len(journal.scroll_ops) == 0 && r.dirty.mirror != nil && !r.ui_staged && !r.interaction_staged {
		if !r.dirty.armed {
			render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster, view)
			dirty_upload_rebase(&r.dirty, r, lut, &terminal.grapheme_store, terminal, view)
		}
		ranges: [DIRTY_UPLOAD_MAX_RANGES]Dirty_Upload_Range
		_, _, fell_back := dirty_upload_frame(&r.dirty, r, terminal, journal, lut, &ranges, view)
		if !fell_back {
			if r.unlock_cb != nil {
				r.unlock_cb(r.unlock_data)
			}
			when ODIN_OS == .Darwin {
				if r.emoji_atlas.gpu_dirty {
					emoji_atlas_upload_gpu(&r.emoji_atlas, r.backend, r.device, r.queue)
				}
			}
			if r.atlas.gpu_dirty {
				atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
			}
			n := u32(int(r.rows) * int(r.cols))
			frame, ok := _renderer_surface_begin(r)
			if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Instance) }
			if (r.cursor_staged || r.image_count > 0) && !_renderer_upload_instances(r, 0, &frame, r.image_count) {
				return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
			}
			if !_draw_instance_buffer(r, &frame, r.dirty.buffer, n, n, u64(n) * instance.INSTANCE_STRIDE, emoji_count = n, image_under_count = r.image_under_count, image_over_count = r.image_count - r.image_under_count) {
				return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
			}
			if !_renderer_surface_commit(r, &frame) {
				return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
			}
			_renderer_frame_published(r, view)
			return true
		}
	}

	r.dirty.armed = false
	render_compile_full_v2(&r.compiled_v2, terminal, &r.fallback, &r.shape_cache, &r.atlas, &r.fallback_counters, &r.raster, view)
	bg_count, glyph_count, emoji_count, decor_count := _prepare_instances_v2(r, lut, &terminal.grapheme_store, terminal, view)
	if r.unlock_cb != nil {
		r.unlock_cb(r.unlock_data)
	}
	when ODIN_OS == .Darwin {
		if r.emoji_atlas.gpu_dirty {
			emoji_atlas_upload_gpu(&r.emoji_atlas, r.backend, r.device, r.queue)
		}
		if emoji_count > 0 && rawptr(r.instances.emoji_buffer) != nil && r.instances.emoji_data != nil {
			r.backend.write_buffer(r.queue, r.instances.emoji_buffer, 0, raw_data(r.instances.emoji_data), u64(emoji_count) * instance.INSTANCE_STRIDE)
		}
	}
	if r.atlas.gpu_dirty {
		atlas_upload_gpu(&r.atlas, r.backend, r.device, r.queue)
	}
	frame, ok := _renderer_surface_begin(r)
	if !ok { return _renderer_frame_failed(r, terminal, journal, &frame, .Instance) }
	if !_renderer_upload_instances(r, bg_count + glyph_count + decor_count, &frame, r.image_count) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	decor_offset := u64(bg_count + glyph_count) * instance.INSTANCE_STRIDE
	if !_draw_instance_buffer(r, &frame, frame.cursor_buffer, bg_count, glyph_count, u64(bg_count) * instance.INSTANCE_STRIDE, emoji_count, is_visual, decor_count, decor_offset, false, r.image_under_count, r.image_count - r.image_under_count) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	if !_renderer_surface_commit(r, &frame) {
		return _renderer_frame_failed(r, terminal, journal, &frame, .Instance)
	}
	r.full_redraw_pending = false
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

_renderer_terminal_has_direct_color :: proc(terminal: ^termgrid.Terminal) -> bool {
	if terminal == nil do return false
	for &row in terminal.grid.rows {
		if .Direct_Color in row.ext.channels do return true
	}
	return false
}

// _renderer_frame_compute_journal owns one journal and one shared encoder for
// dispatch, blit, optional cursor composition, and publication.
_renderer_frame_compute_journal :: proc(r: ^Renderer, terminal: ^termgrid.Terminal, journal: ^termgrid.Damage_Journal, lut: ^Style_LUT) -> bool {
	if r.strategy != .Compute_Tiles || !r.compute_tiles.available || r.tile_map.bits == nil ||
		_renderer_terminal_has_direct_color(terminal) || _renderer_terminal_has_graphics(r, terminal) {
		return _renderer_frame_v2_journal(r, terminal, journal, lut)
	}
	if !_renderer_journal_has_damage(journal) {
		return false
	}
	r.last_dirty = true
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || lut == nil {
		return _renderer_frame_unavailable(r, terminal, journal, .Compute_Tiles)
	}
	_renderer_sync_bg_opacity(r, terminal.grid.style_table.theme.background)
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
	if r.strategy != .Fullscreen || !r.fullscreen.available || _renderer_terminal_has_direct_color(terminal) ||
		_renderer_terminal_has_graphics(r, terminal) {
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
	_renderer_sync_bg_opacity(r, terminal.grid.style_table.theme.background)
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
// _clip_instance_rect intersects a quad with physical pixel bounds and
// preserves the corresponding atlas region when clipping textured quads.
_clip_instance_rect :: proc(quad: ^instance.Instance_Data, clip: [4]f32, textured: bool) -> bool {
	if quad == nil || !(quad.cw > 0) || !(quad.ch > 0) { return false }
	x0 := max(quad.x, clip[0])
	y0 := max(quad.y, clip[1])
	x1 := min(quad.x + quad.cw, clip[2])
	y1 := min(quad.y + quad.ch, clip[3])
	if !(x1 > x0) || !(y1 > y0) { return false }
	if textured {
		du := quad.u1 - quad.u0
		dv := quad.v1 - quad.v0
		u0, v0 := quad.u0, quad.v0
		quad.u0 = u0 + du * (x0 - quad.x) / quad.cw
		quad.u1 = u0 + du * (x1 - quad.x) / quad.cw
		quad.v0 = v0 + dv * (y0 - quad.y) / quad.ch
		quad.v1 = v0 + dv * (y1 - quad.y) / quad.ch
	}
	quad.x, quad.y = x0, y0
	quad.cw, quad.ch = x1 - x0, y1 - y0
	return true
}

// _prepare_pane_style_clip resolves terminal-local styles and the intersection
// of viewport geometry with any additional caller clip.
_prepare_pane_style_clip :: proc(lut: ^Style_LUT, p: ^Pane_Viewport) -> [4]f32 {
	style_lut_rebuild(lut, &p.terminal.grid.style_table)
	bg := p.terminal.grid.style_table.theme.background
	if p.view != nil && p.view.visual_mode { bg = _renderer_visual_background_color(bg) }
	lut.bg_r5g6b5[0] = color_to_r5g6b5(bg)
	clip := [4]f32{p.x, p.y, p.x + p.w, p.y + p.h}
	if p.clip_rect[2] > p.clip_rect[0] && p.clip_rect[3] > p.clip_rect[1] {
		clip = {max(clip[0], p.clip_rect[0]), max(clip[1], p.clip_rect[1]), min(clip[2], p.clip_rect[2]), min(clip[3], p.clip_rect[3])}
	}
	return clip
}

// _apply_pane_dim fades an inactive pane's text-family quad (glyph, emoji,
// decoration) by scaling its alpha. Background quads are deliberately left
// untouched: the pane background is the terminal surface as authored, and
// multiplying its RGB would darken the surface while leaving its translucency
// intact, which makes faded text harder to read over a light desktop instead of
// letting it recede. Matches kitty's inactive_text_alpha uniform.
_apply_pane_dim :: proc(inst: ^instance.Instance_Data, dim: f32) {
	if inst == nil || dim >= 1.0 do return
	inst.a *= dim
}

_prepare_pane_instances_v2 :: proc(
	r:              ^Renderer,
	lut:            ^Style_LUT,
	panes:          []Pane_Viewport,
	compiled_panes: []Compiled_Frame_V2,
) -> (bg_count: u32, glyph_count: u32, emoji_count: u32, decor_count: u32) {
	cell_w := r.cell_width
	cell_h := r.cell_height
	atlas := &r.atlas
	inst := &r.instances

	bg_count = 0
	glyph_count = 0
	emoji_count = 0
	decor_count = 0
	grid_limit := u32(min(int(inst.max_instances > 1 ? inst.max_instances - 1 : 0), len(inst.instance_data)))
	if r.interaction_staged { grid_limit = min(grid_limit, r.interaction_slot_start) }

	// Pass 1: backgrounds across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) || p.rows <= 0 || p.cols <= 0 || !(p.w > 0) || !(p.h > 0) do continue
		clip := _prepare_pane_style_clip(lut, p)
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		// Empty/default cells intentionally emit no quad. Fill the viewport
		// first so every pane retains its own theme background. The background
		// is never dimmed: see _apply_pane_dim.
		if bg_count < grid_limit {
			red, green, blue := instance.unpack_r5g6b5(lut.bg_r5g6b5[0])
			background_alpha := _renderer_default_background_alpha(p.terminal.grid.style_table.theme.background, r.background_opacity)
			inst.instance_data[bg_count] = instance.Instance_Data{
				x = p.x, y = p.y, cw = p.w, ch = p.h,
				r = red, g = green, b = blue, a = background_alpha,
			}
			if _clip_instance_rect(&inst.instance_data[bg_count], clip, false) { bg_count += 1 }
		}

		for idx in 0 ..< len(cells) {
			if bg_count >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			emit_bg, _, _, _ := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				&inst.instance_data[bg_count], nil,
				direct_color = dc,
			background_opacity = r.background_opacity,
			)
			if emit_bg && _clip_instance_rect(&inst.instance_data[bg_count], clip, false) {
				bg_count += 1
			}
		}
	}

	// Pass 2: glyphs and emojis across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) || p.rows <= 0 || p.cols <= 0 || !(p.w > 0) || !(p.h > 0) do continue
		clip := _prepare_pane_style_clip(lut, p)
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		dim := p.dim_factor

		for idx in 0 ..< len(cells) {
			glyph_idx := bg_count + glyph_count
			if glyph_idx >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			emoji_inst_ptr: ^instance.Instance_Data = nil
			emoji_atlas_ptr: ^Emoji_Atlas = nil
			if r.emoji_atlas.has_font {
				if emoji_count < grid_limit && inst.emoji_data != nil {
					emoji_inst_ptr = &inst.emoji_data[emoji_count]
				}
				emoji_atlas_ptr = &r.emoji_atlas
			}

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			_, emit_glyph, emit_emoji, _ := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				nil, &inst.instance_data[glyph_idx],
				emoji_inst_ptr,
				emoji_atlas_ptr,
				&p.terminal.grapheme_store,
				direct_color = dc,
			background_opacity = r.background_opacity,
			)
			if emit_emoji && emoji_inst_ptr != nil && _clip_instance_rect(emoji_inst_ptr, clip, true) {
				_apply_pane_dim(emoji_inst_ptr, dim)
				emoji_count += 1
			} else if emit_glyph && _clip_instance_rect(&inst.instance_data[glyph_idx], clip, true) {
				_apply_pane_dim(&inst.instance_data[glyph_idx], dim)
				glyph_count += 1
			}
		}
	}

	// Pass 3: decorations across all panes
	for i in 0 ..< len(panes) {
		p := &panes[i]
		if p.terminal == nil || i >= len(compiled_panes) || p.rows <= 0 || p.cols <= 0 || !(p.w > 0) || !(p.h > 0) do continue
		clip := _prepare_pane_style_clip(lut, p)
		cells := compiled_panes[i].cells
		cols := i32(p.cols)
		dim := p.dim_factor

		for idx in 0 ..< len(cells) {
			decor_idx := bg_count + glyph_count + decor_count
			if decor_idx >= grid_limit do break
			row := i32(idx) / cols
			col := i32(idx) % cols
			x := p.x + f32(col) * cell_w
			y := p.y + f32(row) * cell_h

			dc := termgrid.terminal_view_get_direct_color(p.terminal, p.view, int(row), int(col))
			_, _, _, emit_decor := render_cell_expand_instance(
				cells[idx], lut, atlas, x, y, cell_w, cell_h,
				nil, nil, nil, nil, nil,
				&inst.instance_data[decor_idx],
				direct_color = dc,
			background_opacity = r.background_opacity,
			)
			if emit_decor && _clip_instance_rect(&inst.instance_data[decor_idx], clip, false) {
				_apply_pane_dim(&inst.instance_data[decor_idx], dim)
				decor_count += 1
			}
		}
	}

	return bg_count, glyph_count, emoji_count, decor_count
}

package tile

// Phase 14 tiled compute renderer: sibling path to the instance renderer on
// the same compiled input (packed V2 cells, Style_LUT, atlas view).
//
// Per frame only dirty tiles are rewritten: dirty cell ranges + the
// tile list (+ LUT when rebuilt) are uploaded with sync write_buffer, one
// compute dispatch renders the tiles into a persistent framebuffer, and a
// fullscreen-triangle blit presents it. The instance path is untouched.
//
// Data flow:
//   Tile_Map -> Tile_List_Buffer -> Compute_Dispatch -> Framebuffer_Texture
//   Atlas_Texture -> Compute_Dispatch, Tile_Params -> Compute_Dispatch,
//   Framebuffer_Texture -> Blit_Pass.
//
// Compute shader bindings (must match tile_compute.wgsl):
//   0 params uniform, 1 tile_list ro storage, 2 cells ro storage,
//   3 lut ro storage, 4 atlas texture, 5 sampler, 6 framebuffer storage.
// Blit shader bindings (must match tile_blit.wgsl):
//   0 framebuffer texture, 1 sampler.

import "base:runtime"
import gpu "../gpu"

// TILE_PARAMS_SIZE is the params uniform buffer size in bytes.
// size_of(Tile_Params) == 56; the trailing 8 bytes stay zero.
TILE_PARAMS_SIZE :: 64

// TILE_CELL_BYTES is one packed V2 cell (u64).
TILE_CELL_BYTES :: 8

// TILE_LUT_WORDS / TILE_LUT_BYTES cover the raw Style_LUT fg+bg bytes
// (1024 u16 fg + 1024 u16 bg = 1024 u32 words).
TILE_LUT_WORDS :: 1024
TILE_LUT_BYTES :: 4096

// TILE_FRAMEBUFFER_FORMAT is the compute framebuffer format. BGRA8Unorm is
// not storage-capable in WebGPU, so the framebuffer is always RGBA8Unorm
// (storage write + texture sample + copy source); the blit converts to the
// surface format.
TILE_FRAMEBUFFER_FORMAT :: gpu.Gpu_Format.RGBA8_Unorm

// TILE_ATLAS_TEX_W/H mirror the render atlas pixel dimensions
// (render.ATLAS_COLS * render.ATLAS_GLYPH_SIZE = 256,
// render.ATLAS_ROWS * render.ATLAS_GLYPH_SIZE = 512); tile cannot import
// render (import cycle), so they are mirrored here.
TILE_ATLAS_TEX_W :: 256
TILE_ATLAS_TEX_H :: 512

// Compute/blit shader entry points (must match the WGSL sources).
TILE_COMPUTE_ENTRY :: "cs_main"
TILE_BLIT_VERTEX_ENTRY :: "vs_main"
TILE_BLIT_FRAGMENT_ENTRY :: "fs_main"

// Tile_Params mirrors the WGSL Tile_Params struct field for field (56 bytes,
// all 4-byte scalars, no padding). screen_w/h carry the framebuffer size.
Tile_Params :: struct {
	screen_w: f32,
	screen_h: f32,
	cols:     u32,
	rows:     u32,
	cell_w:   f32,
	cell_h:   f32,
	pad_x:    f32,
	pad_y:    f32,
	tile_w:   u32,
	tile_h:   u32,
	tiles_x:  u32,
	tiles_y:  u32,
	atlas_w:  u32,
	atlas_h:  u32,
}

#assert(size_of(Tile_Params) == 56)

// Compute_Tile_Renderer holds the tiled compute path GPU state.
// available == false means every frame must take the instance fallback;
// the flag never latches (a later resize or strategy switch can recover).
Compute_Tile_Renderer :: struct {
	backend:            ^gpu.Gpu_Backend_VTable,
	device:             gpu.Gpu_Device,
	queue:              gpu.Gpu_Queue,
	tile_w:             u32,
	tile_h:             u32,
	rows:               i32,
	cols:               i32,
	cell_w:             f32,
	cell_h:             f32,
	pad_x:              f32,
	pad_y:              f32,
	available:          bool,
	compute_pipeline:   gpu.Gpu_ComputePipeline,
	blit_pipeline:      gpu.Gpu_RenderPipeline,
	framebuffer:        gpu.Gpu_Texture,
	fb_view:            gpu.Gpu_TextureView,
	params_buffer:      gpu.Gpu_Buffer,
	tile_list_buffer:   gpu.Gpu_Buffer,
	cell_buffer:        gpu.Gpu_Buffer,
	lut_buffer:         gpu.Gpu_Buffer,
	atlas_view:         gpu.Gpu_TextureView,
	sampler:            gpu.Gpu_Sampler,
	compute_bind_group: gpu.Gpu_BindGroup,
	blit_bind_group:    gpu.Gpu_BindGroup,
	compute_layout:     gpu.Gpu_BindGroupLayout,
	blit_layout:        gpu.Gpu_BindGroupLayout,
	fb_w_px:            u32,
	fb_h_px:            u32,
	format:             gpu.Gpu_Format,
}

// _compute_tile_params builds the uniform value for the current geometry.
_compute_tile_params :: proc(r: ^Compute_Tile_Renderer) -> Tile_Params {
	tiles_x, tiles_y := _tile_grid_extent(r.cols, r.rows, r.tile_w, r.tile_h)
	return Tile_Params{
		screen_w = f32(r.fb_w_px),
		screen_h = f32(r.fb_h_px),
		cols     = u32(r.cols),
		rows     = u32(r.rows),
		cell_w   = r.cell_w,
		cell_h   = r.cell_h,
		pad_x    = r.pad_x,
		pad_y    = r.pad_y,
		tile_w   = r.tile_w,
		tile_h   = r.tile_h,
		tiles_x  = tiles_x,
		tiles_y  = tiles_y,
		atlas_w  = TILE_ATLAS_TEX_W,
		atlas_h  = TILE_ATLAS_TEX_H,
	}
}

// compute_tile_init creates the framebuffer, storage buffers, pipelines, and
// bind groups. format is the surface (blit target) format; the framebuffer
// itself is always TILE_FRAMEBUFFER_FORMAT. A nil compute/blit pipeline
// marks the renderer unavailable (NOT fatal: the caller falls back per
// frame); nil handles, degenerate geometry, over-cap tiles, or
// buffer/framebuffer failure return false.
compute_tile_init :: proc(
	r: ^Compute_Tile_Renderer,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
	rows: i32,
	cols: i32,
	cell_w: f32,
	cell_h: f32,
	pad_x: f32,
	pad_y: f32,
	screen_w: f32,
	screen_h: f32,
	format: gpu.Gpu_Format,
	atlas_view: gpu.Gpu_TextureView,
	compute_wgsl: string,
	blit_wgsl: string,
	tile_w: u32 = TILE_W_DEFAULT,
	tile_h: u32 = TILE_H_DEFAULT,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	_ = allocator
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return false
	}
	if rawptr(atlas_view) == nil {
		return false
	}
	if rows <= 0 || cols <= 0 || cell_w <= 0 || cell_h <= 0 || pad_x < 0 || pad_y < 0 || screen_w <= 0 || screen_h <= 0 || tile_w == 0 || tile_h == 0 {
		return false
	}
	tiles_x, tiles_y := _tile_grid_extent(cols, rows, tile_w, tile_h)
	if tiles_x == 0 || tiles_y == 0 {
		return false
	}
	if u64(tiles_x) * u64(tiles_y) > TILE_MAX_TILES {
		return false
	}
	fb_w := u32(screen_w)
	fb_h := u32(screen_h)
	if fb_w == 0 || fb_h == 0 {
		return false
	}
	n := int(rows) * int(cols)

	r.backend = backend
	r.device = device
	r.queue = queue
	r.tile_w = tile_w
	r.tile_h = tile_h
	r.rows = rows
	r.cols = cols
	r.cell_w = cell_w
	r.cell_h = cell_h
	r.pad_x = pad_x
	r.pad_y = pad_y
	r.format = format
	r.fb_w_px = fb_w
	r.fb_h_px = fb_h
	r.atlas_view = atlas_view
	r.available = false

	r.framebuffer = backend.create_texture(
		device, fb_w, fb_h, TILE_FRAMEBUFFER_FORMAT,
		gpu.Gpu_Texture_Usage.Storage_Binding | gpu.Gpu_Texture_Usage.Texture_Binding | gpu.Gpu_Texture_Usage.Copy_Src,
	)
	if rawptr(r.framebuffer) == nil {
		return false
	}
	r.fb_view = backend.create_texture_view(r.framebuffer)
	r.params_buffer = backend.create_buffer(device, TILE_PARAMS_SIZE, gpu.Gpu_Buffer_Usage.Uniform | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	r.tile_list_buffer = backend.create_buffer(device, TILE_MAX_TILES * 4, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	r.cell_buffer = backend.create_buffer(device, u64(n) * TILE_CELL_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	r.lut_buffer = backend.create_buffer(device, TILE_LUT_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	if rawptr(r.fb_view) == nil || rawptr(r.params_buffer) == nil || rawptr(r.tile_list_buffer) == nil || rawptr(r.cell_buffer) == nil || rawptr(r.lut_buffer) == nil {
		compute_tile_destroy(r)
		return false
	}
	r.sampler = backend.create_sampler(device)
	if rawptr(r.sampler) == nil {
		compute_tile_destroy(r)
		return false
	}

	compute_module := backend.create_shader_module(device, compute_wgsl)
	r.compute_pipeline = backend.create_compute_pipeline(device, compute_module, TILE_COMPUTE_ENTRY)
	backend.destroy_shader_module(compute_module)

	blit_vs := backend.create_shader_module(device, blit_wgsl)
	blit_fs := blit_vs
	r.blit_pipeline = backend.create_render_pipeline(
		device, blit_vs, TILE_BLIT_VERTEX_ENTRY, blit_fs, TILE_BLIT_FRAGMENT_ENTRY,
		nil, format, .Opaque, .Triangle_List,
	)
	backend.destroy_shader_module(blit_vs)

	if rawptr(r.compute_pipeline) == nil || rawptr(r.blit_pipeline) == nil {
		return true
	}
	r.compute_layout = backend.compute_get_bind_group_layout(r.compute_pipeline, 0)
	r.blit_layout = backend.pipeline_get_bind_group_layout(r.blit_pipeline, 0)
	if rawptr(r.compute_layout) == nil || rawptr(r.blit_layout) == nil {
		return true
	}

	compute_entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, buffer = r.params_buffer, offset = 0, size = TILE_PARAMS_SIZE, entry_type = .Buffer},
		{binding = 1, buffer = r.tile_list_buffer, offset = 0, size = TILE_MAX_TILES * 4, entry_type = .Buffer},
		{binding = 2, buffer = r.cell_buffer, offset = 0, size = u64(n) * TILE_CELL_BYTES, entry_type = .Buffer},
		{binding = 3, buffer = r.lut_buffer, offset = 0, size = TILE_LUT_BYTES, entry_type = .Buffer},
		{binding = 4, view = atlas_view, entry_type = .Texture_View},
		{binding = 5, sampler = r.sampler, entry_type = .Sampler},
		{binding = 6, view = r.fb_view, entry_type = .Texture_View},
	}
	r.compute_bind_group = backend.create_bind_group(device, r.compute_layout, compute_entries)

	blit_entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, view = r.fb_view, entry_type = .Texture_View},
		{binding = 1, sampler = r.sampler, entry_type = .Sampler},
	}
	r.blit_bind_group = backend.create_bind_group(device, r.blit_layout, blit_entries)

	if rawptr(r.compute_bind_group) == nil || rawptr(r.blit_bind_group) == nil {
		return true
	}

	compute_tile_write_params(r)
	r.available = true
	return true
}

// compute_tile_write_params uploads the current geometry to the params buffer.
compute_tile_write_params :: proc(r: ^Compute_Tile_Renderer) {
	if r.backend == nil || rawptr(r.queue) == nil || rawptr(r.params_buffer) == nil {
		return
	}
	p := _compute_tile_params(r)
	r.backend.write_buffer(r.queue, r.params_buffer, 0, &p, size_of(Tile_Params))
}

// compute_tile_destroy frees GPU resources in pipeline → group → layout →
// buffer → view → texture → sampler order. Nil-safe; resets all handles.
compute_tile_destroy :: proc(r: ^Compute_Tile_Renderer) {
	if r.backend != nil {
		if rawptr(r.compute_pipeline) != nil {
			r.backend.destroy_compute_pipeline(r.compute_pipeline)
			r.compute_pipeline = gpu.Gpu_ComputePipeline(nil)
		}
		if rawptr(r.blit_pipeline) != nil {
			r.backend.destroy_render_pipeline(r.blit_pipeline)
			r.blit_pipeline = gpu.Gpu_RenderPipeline(nil)
		}
		if rawptr(r.compute_bind_group) != nil {
			r.backend.destroy_bind_group(r.compute_bind_group)
			r.compute_bind_group = gpu.Gpu_BindGroup(nil)
		}
		if rawptr(r.blit_bind_group) != nil {
			r.backend.destroy_bind_group(r.blit_bind_group)
			r.blit_bind_group = gpu.Gpu_BindGroup(nil)
		}
		if rawptr(r.compute_layout) != nil {
			r.backend.destroy_bind_group_layout(r.compute_layout)
			r.compute_layout = gpu.Gpu_BindGroupLayout(nil)
		}
		if rawptr(r.blit_layout) != nil {
			r.backend.destroy_bind_group_layout(r.blit_layout)
			r.blit_layout = gpu.Gpu_BindGroupLayout(nil)
		}
		if rawptr(r.params_buffer) != nil {
			r.backend.destroy_buffer(r.params_buffer)
			r.params_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.tile_list_buffer) != nil {
			r.backend.destroy_buffer(r.tile_list_buffer)
			r.tile_list_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.cell_buffer) != nil {
			r.backend.destroy_buffer(r.cell_buffer)
			r.cell_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.lut_buffer) != nil {
			r.backend.destroy_buffer(r.lut_buffer)
			r.lut_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.fb_view) != nil {
			r.backend.destroy_texture_view(r.fb_view)
			r.fb_view = gpu.Gpu_TextureView(nil)
		}
		if rawptr(r.framebuffer) != nil {
			r.backend.destroy_texture(r.framebuffer)
			r.framebuffer = gpu.Gpu_Texture(nil)
		}
		if rawptr(r.sampler) != nil {
			r.backend.destroy_sampler(r.sampler)
			r.sampler = gpu.Gpu_Sampler(nil)
		}
	}
	r.available = false
}

// compute_tile_resize recreates size-dependent resources (cell buffer on N
// change, framebuffer on pixel change), rebuilds both bind groups, and
// rewrites params. Unchanged resources are kept. The surface format is baked
// into the blit pipeline, so a format change returns false (old resources
// intact; the caller disables compute). Returns false as well when the
// geometry is degenerate or a recreation fails.
compute_tile_resize :: proc(r: ^Compute_Tile_Renderer, rows: i32, cols: i32, cell_w: f32, cell_h: f32, pad_x: f32, pad_y: f32, screen_w: f32, screen_h: f32, format: gpu.Gpu_Format) -> bool {
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	if rows <= 0 || cols <= 0 || cell_w <= 0 || cell_h <= 0 || pad_x < 0 || pad_y < 0 || screen_w <= 0 || screen_h <= 0 {
		return false
	}
	if format != r.format {
		return false
	}
	fb_w := u32(screen_w)
	fb_h := u32(screen_h)
	if fb_w == 0 || fb_h == 0 {
		return false
	}
	n := int(rows) * int(cols)
	old_n := int(r.rows) * int(r.cols)
	if n == old_n && fb_w == r.fb_w_px && fb_h == r.fb_h_px && rows == r.rows && cols == r.cols {
		r.pad_x = pad_x
		r.pad_y = pad_y
		compute_tile_write_params(r)
		return true
	}

	new_cell_buffer := r.cell_buffer
	new_fb := r.framebuffer
	new_view := r.fb_view
	if n != old_n {
		new_cell_buffer = r.backend.create_buffer(r.device, u64(n) * TILE_CELL_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
		if rawptr(new_cell_buffer) == nil {
			return false
		}
	}
	if fb_w != r.fb_w_px || fb_h != r.fb_h_px {
		new_fb = r.backend.create_texture(
			r.device, fb_w, fb_h, TILE_FRAMEBUFFER_FORMAT,
			gpu.Gpu_Texture_Usage.Storage_Binding | gpu.Gpu_Texture_Usage.Texture_Binding | gpu.Gpu_Texture_Usage.Copy_Src,
		)
		if rawptr(new_fb) == nil {
			if new_cell_buffer != r.cell_buffer {
				r.backend.destroy_buffer(new_cell_buffer)
			}
			return false
		}
		new_view = r.backend.create_texture_view(new_fb)
		if rawptr(new_view) == nil {
			r.backend.destroy_texture(new_fb)
			if new_cell_buffer != r.cell_buffer {
				r.backend.destroy_buffer(new_cell_buffer)
			}
			return false
		}
	}

	new_compute_group := r.compute_bind_group
	new_blit_group := r.blit_bind_group
	groups_stale := new_cell_buffer != r.cell_buffer || new_view != r.fb_view
	if groups_stale && rawptr(r.compute_layout) != nil && rawptr(r.blit_layout) != nil {
		compute_entries := []gpu.Gpu_Bind_Entry{
			{binding = 0, buffer = r.params_buffer, offset = 0, size = TILE_PARAMS_SIZE, entry_type = .Buffer},
			{binding = 1, buffer = r.tile_list_buffer, offset = 0, size = TILE_MAX_TILES * 4, entry_type = .Buffer},
			{binding = 2, buffer = new_cell_buffer, offset = 0, size = u64(n) * TILE_CELL_BYTES, entry_type = .Buffer},
			{binding = 3, buffer = r.lut_buffer, offset = 0, size = TILE_LUT_BYTES, entry_type = .Buffer},
			{binding = 4, view = r.atlas_view, entry_type = .Texture_View},
			{binding = 5, sampler = r.sampler, entry_type = .Sampler},
			{binding = 6, view = new_view, entry_type = .Texture_View},
		}
		new_compute_group = r.backend.create_bind_group(r.device, r.compute_layout, compute_entries)
		blit_entries := []gpu.Gpu_Bind_Entry{
			{binding = 0, view = new_view, entry_type = .Texture_View},
			{binding = 1, sampler = r.sampler, entry_type = .Sampler},
		}
		new_blit_group = r.backend.create_bind_group(r.device, r.blit_layout, blit_entries)
		if rawptr(new_compute_group) == nil || rawptr(new_blit_group) == nil {
			if rawptr(new_compute_group) != nil && new_compute_group != r.compute_bind_group {
				r.backend.destroy_bind_group(new_compute_group)
			}
			if rawptr(new_blit_group) != nil && new_blit_group != r.blit_bind_group {
				r.backend.destroy_bind_group(new_blit_group)
			}
			if new_cell_buffer != r.cell_buffer {
				r.backend.destroy_buffer(new_cell_buffer)
			}
			if new_fb != r.framebuffer {
				r.backend.destroy_texture_view(new_view)
				r.backend.destroy_texture(new_fb)
			}
			return false
		}
	}

	if groups_stale {
		if rawptr(r.compute_bind_group) != nil && new_compute_group != r.compute_bind_group {
			r.backend.destroy_bind_group(r.compute_bind_group)
		}
		if rawptr(r.blit_bind_group) != nil && new_blit_group != r.blit_bind_group {
			r.backend.destroy_bind_group(r.blit_bind_group)
		}
		r.compute_bind_group = new_compute_group
		r.blit_bind_group = new_blit_group
	}
	if new_cell_buffer != r.cell_buffer {
		if rawptr(r.cell_buffer) != nil {
			r.backend.destroy_buffer(r.cell_buffer)
		}
		r.cell_buffer = new_cell_buffer
	}
	if new_fb != r.framebuffer {
		if rawptr(r.fb_view) != nil {
			r.backend.destroy_texture_view(r.fb_view)
		}
		if rawptr(r.framebuffer) != nil {
			r.backend.destroy_texture(r.framebuffer)
		}
		r.framebuffer = new_fb
		r.fb_view = new_view
	}
	r.rows = rows
	r.cols = cols
	r.cell_w = cell_w
	r.cell_h = cell_h
	r.pad_x = pad_x
	r.pad_y = pad_y
	r.fb_w_px = fb_w
	r.fb_h_px = fb_h
	r.format = format
	compute_tile_write_params(r)
	r.available = rawptr(r.compute_pipeline) != nil && rawptr(r.blit_pipeline) != nil && rawptr(r.compute_bind_group) != nil && rawptr(r.blit_bind_group) != nil
	return true
}

// compute_tile_set_tile_size switches the tile geometry (params uniform
// only; the grid is unchanged). Returns false on degenerate sizes or
// over-cap geometry, leaving the old size intact.
compute_tile_set_tile_size :: proc(r: ^Compute_Tile_Renderer, tile_w: u32, tile_h: u32) -> bool {
	if tile_w == 0 || tile_h == 0 || r.rows <= 0 || r.cols <= 0 {
		return false
	}
	tiles_x, tiles_y := _tile_grid_extent(r.cols, r.rows, tile_w, tile_h)
	if tiles_x == 0 || tiles_y == 0 {
		return false
	}
	if u64(tiles_x) * u64(tiles_y) > TILE_MAX_TILES {
		return false
	}
	r.tile_w = tile_w
	r.tile_h = tile_h
	compute_tile_write_params(r)
	return true
}

// compute_tile_upload_cells writes dirty tile cell rows at byte offsets, the
// tile list, and (when rebuilt) the LUT. cells holds packed V2 u64s in
// row-major order; lut_words views the raw Style_LUT fg+bg bytes as
// TILE_LUT_WORDS u32s. Byte math runs even with a nil backend (CPU-only
// accounting); write_buffer is issued only when backend, queue, and buffers
// are live. Returns total bytes that would be / were uploaded.
compute_tile_upload_cells :: proc(r: ^Compute_Tile_Renderer, m: ^Tile_Map, cells: []u64, lut_words: []u32, lut_changed: bool) -> u64 {
	bytes: u64 = 0
	live := r.backend != nil && rawptr(r.queue) != nil && rawptr(r.cell_buffer) != nil && rawptr(r.tile_list_buffer) != nil && rawptr(r.lut_buffer) != nil
	cols := int(r.cols)
	rows := int(r.rows)
	if m != nil && m.list != nil && cols > 0 && rows > 0 {
		tw := int(m.tile_w)
		th := int(m.tile_h)
		for k in 0..<m.count {
			if k >= len(m.list) {
				break
			}
			orow, ocol := tile_origin_of(m, m.list[k])
			r1 := orow + th
			if r1 > rows {
				r1 = rows
			}
			c1 := ocol + tw
			if c1 > cols {
				c1 = cols
			}
			for row in orow..<r1 {
				base := row * cols + ocol
				nseg := c1 - ocol
				if base < 0 || nseg <= 0 {
					continue
				}
				end := base + nseg
				if base >= len(cells) {
					continue
				}
				if end > len(cells) {
					end = len(cells)
					nseg = end - base
				}
				size := u64(nseg) * TILE_CELL_BYTES
				if size == 0 {
					continue
				}
				if live {
					r.backend.write_buffer(r.queue, r.cell_buffer, u64(base) * TILE_CELL_BYTES, &cells[base], size)
				}
				bytes += size
			}
		}
		if live && m.count > 0 && m.count <= len(m.list) {
			r.backend.write_buffer(r.queue, r.tile_list_buffer, 0, &m.list[0], u64(m.count) * 4)
		}
		bytes += u64(m.count) * 4
	}
	if lut_changed && len(lut_words) * 4 >= TILE_LUT_BYTES {
		if live {
			r.backend.write_buffer(r.queue, r.lut_buffer, 0, &lut_words[0], TILE_LUT_BYTES)
		}
		bytes += TILE_LUT_BYTES
	}
	return bytes
}

// compute_tile_dispatch appends one compute dispatch to encoder. It does not
// finish or submit the encoder. Returns (dispatches, invocations); (0, 0)
// when unavailable, empty, or the shared encoder cannot be used.
compute_tile_dispatch :: proc(r: ^Compute_Tile_Renderer, m: ^Tile_Map, encoder: gpu.Gpu_CommandEncoder) -> (dispatches: u32, invocations: u32) {
	if !r.available {
		return 0, 0
	}
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || rawptr(encoder) == nil {
		return 0, 0
	}
	if rawptr(r.compute_pipeline) == nil || rawptr(r.compute_bind_group) == nil {
		return 0, 0
	}
	if m == nil || m.count <= 0 {
		return 0, 0
	}
	count := u32(m.count)
	pass := r.backend.begin_compute_pass(encoder)
	if rawptr(pass) == nil {
		return 0, 0
	}
	r.backend.compute_set_pipeline(pass, r.compute_pipeline)
	r.backend.compute_set_bind_group(pass, 0, r.compute_bind_group)
	r.backend.compute_dispatch(pass, count, 1, 1)
	r.backend.end_compute_pass(pass)
	return 1, count
}

// compute_tile_blit appends the framebuffer blit and optional cursor draw to
// encoder. It does not finish or submit the encoder. The caller owns the
// shared command buffer and surface lifecycle.
compute_tile_blit :: proc(
	r: ^Compute_Tile_Renderer,
	surface_view: gpu.Gpu_TextureView,
	encoder: gpu.Gpu_CommandEncoder,
	cursor_pipeline: gpu.Gpu_RenderPipeline,
	cursor_bind_group: gpu.Gpu_BindGroup,
	cursor_buffer: gpu.Gpu_Buffer,
	cursor_offset: u64,
) -> bool {
	if !r.available {
		return false
	}
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil || rawptr(encoder) == nil {
		return false
	}
	if rawptr(r.blit_pipeline) == nil || rawptr(r.blit_bind_group) == nil {
		return false
	}
	if rawptr(surface_view) == nil {
		return false
	}
	pass := r.backend.begin_render_pass(encoder, surface_view, {0, 0, 0, 1}, .Clear)
	if rawptr(pass) == nil {
		return false
	}
	r.backend.render_set_pipeline(pass, r.blit_pipeline)
	r.backend.render_set_bind_group(pass, 0, r.blit_bind_group)
	r.backend.render_draw(pass, 3, 1)
	if rawptr(cursor_pipeline) != nil || rawptr(cursor_bind_group) != nil || rawptr(cursor_buffer) != nil {
		if rawptr(cursor_pipeline) == nil || rawptr(cursor_bind_group) == nil || rawptr(cursor_buffer) == nil {
			r.backend.end_render_pass(pass)
			return false
		}
		r.backend.render_set_pipeline(pass, cursor_pipeline)
		r.backend.render_set_bind_group(pass, 0, cursor_bind_group)
		r.backend.render_set_vertex_buffer(pass, 0, cursor_buffer, cursor_offset)
		r.backend.render_draw(pass, 6, 1)
	}
	r.backend.end_render_pass(pass)
	return true
}

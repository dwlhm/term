package fullscreen

// Phase 15 fullscreen fragment renderer: sibling path to the instance and
// tiled compute renderers on the same compiled input (packed V2 cells,
// Style_LUT, atlas view).
//
// Per frame the full grid is rewritten (one full N*8 upload plus the LUT
// when rebuilt) and a single fullscreen-triangle draw shades every surface
// pixel directly. No ring, no framebuffer, no tile list. The instance path
// is untouched.
//
// Data flow:
//   GridSSBO -> FullscreenPass -> SurfaceView -> Present
//   LutSSBO -> FullscreenPass, AtlasView -> FullscreenPass,
//   ParamsUniform -> FullscreenPass.
//
// Fullscreen shader bindings (must match fullscreen.wgsl):
//   0 params uniform, 1 cells ro storage, 2 lut ro storage,
//   3 atlas texture, 4 sampler.

import "base:runtime"
import "core:mem"
import gpu "../gpu"

// FULLSCREEN_PARAMS_SIZE is the params uniform buffer size in bytes.
// size_of(Fullscreen_Params) == 40; the trailing 24 bytes stay zero.
FULLSCREEN_PARAMS_SIZE :: 64

// FULLSCREEN_CELL_BYTES is one packed V2 cell (u64).
FULLSCREEN_CELL_BYTES :: 8

// FULLSCREEN_LUT_WORDS / FULLSCREEN_LUT_BYTES cover the raw Style_LUT
// fg+bg bytes (1024 u16 fg + 1024 u16 bg = 1024 u32 words).
FULLSCREEN_LUT_WORDS :: 1024
FULLSCREEN_LUT_BYTES :: 4096

// FULLSCREEN_ATLAS_TEX_W/H mirror the render atlas pixel dimensions
// (render.ATLAS_COLS * render.ATLAS_GLYPH_SIZE = 256,
// render.ATLAS_ROWS * render.ATLAS_GLYPH_SIZE = 512); fullscreen cannot
// import render (import cycle), so they are mirrored here.
FULLSCREEN_ATLAS_TEX_W :: 256
FULLSCREEN_ATLAS_TEX_H :: 512

// Fullscreen shader entry points (must match the WGSL source).
FULLSCREEN_VERTEX_ENTRY :: "fullscreen_vs_main"
FULLSCREEN_FRAGMENT_ENTRY :: "fullscreen_fs_main"

// Fullscreen_Params mirrors the WGSL Fullscreen_Params struct field for
// field (40 bytes, all 4-byte scalars, no padding). screen_w/h carry the
// framebuffer size in pixels.
Fullscreen_Params :: struct {
	screen_w: f32,
	screen_h: f32,
	cols:     u32,
	rows:     u32,
	cell_w:   f32,
	cell_h:   f32,
	pad_x:    f32,
	pad_y:    f32,
	atlas_w:  u32,
	atlas_h:  u32,
}

#assert(size_of(Fullscreen_Params) == 40)

// Fullscreen_Renderer holds the fullscreen path GPU state.
// available == false means every frame must take the instance fallback;
// the flag never latches (a later resize can recover).
Fullscreen_Renderer :: struct {
	backend:       ^gpu.Gpu_Backend_VTable,
	device:        gpu.Gpu_Device,
	queue:         gpu.Gpu_Queue,
	rows:          i32,
	cols:          i32,
	cell_w:        f32,
	cell_h:        f32,
	pad_x:         f32,
	pad_y:         f32,
	available:     bool,
	pipeline:      gpu.Gpu_RenderPipeline,
	params_buffer: gpu.Gpu_Buffer,
	cell_buffer:   gpu.Gpu_Buffer,
	lut_buffer:    gpu.Gpu_Buffer,
	atlas_view:    gpu.Gpu_TextureView,
	sampler:       gpu.Gpu_Sampler,
	bind_group:    gpu.Gpu_BindGroup,
	layout:        gpu.Gpu_BindGroupLayout,
	fb_w_px:       u32,
	fb_h_px:       u32,
	format:        gpu.Gpu_Format,
}

// _fullscreen_params builds the uniform value for the current geometry.
_fullscreen_params :: proc(r: ^Fullscreen_Renderer) -> Fullscreen_Params {
	return Fullscreen_Params{
		screen_w = f32(r.fb_w_px),
		screen_h = f32(r.fb_h_px),
		cols     = u32(r.cols),
		rows     = u32(r.rows),
		cell_w   = r.cell_w,
		cell_h   = r.cell_h,
		pad_x    = r.pad_x,
		pad_y    = r.pad_y,
		atlas_w  = FULLSCREEN_ATLAS_TEX_W,
		atlas_h  = FULLSCREEN_ATLAS_TEX_H,
	}
}

// fullscreen_init creates the storage buffers, the single render pipeline,
// and the one bind group. format is the surface (direct render target)
// format. A nil pipeline/group/layout marks the renderer unavailable (NOT
// fatal: the caller falls back per frame); nil handles, degenerate
// geometry, or buffer failure return false.
fullscreen_init :: proc(
	r: ^Fullscreen_Renderer,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
	rows: i32,
	cols: i32,
	cell_w: f32,
	cell_h: f32,
	pad_x: f32,
	pad_y: f32,
	format: gpu.Gpu_Format,
	atlas_view: gpu.Gpu_TextureView,
	wgsl: string,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	_ = allocator
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil {
		return false
	}
	if rawptr(atlas_view) == nil {
		return false
	}
	if rows <= 0 || cols <= 0 || cell_w <= 0 || cell_h <= 0 || pad_x < 0 || pad_y < 0 {
		return false
	}
	fb_w := u32(f32(cols) * cell_w)
	fb_h := u32(f32(rows) * cell_h)
	if fb_w == 0 || fb_h == 0 {
		return false
	}
	n := int(rows) * int(cols)

	r.backend = backend
	r.device = device
	r.queue = queue
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

	r.params_buffer = backend.create_buffer(device, FULLSCREEN_PARAMS_SIZE, gpu.Gpu_Buffer_Usage.Uniform | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	r.cell_buffer = backend.create_buffer(device, u64(n) * FULLSCREEN_CELL_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	r.lut_buffer = backend.create_buffer(device, FULLSCREEN_LUT_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
	if rawptr(r.params_buffer) == nil || rawptr(r.cell_buffer) == nil || rawptr(r.lut_buffer) == nil {
		fullscreen_destroy(r)
		return false
	}
	r.sampler = backend.create_sampler(device)
	if rawptr(r.sampler) == nil {
		fullscreen_destroy(r)
		return false
	}

	mod := backend.create_shader_module(device, wgsl)
	r.pipeline = backend.create_render_pipeline(
		device, mod, FULLSCREEN_VERTEX_ENTRY, mod, FULLSCREEN_FRAGMENT_ENTRY,
		nil, format, .Opaque, .Triangle_List,
	)
	backend.destroy_shader_module(mod)

	if rawptr(r.pipeline) == nil {
		return true
	}
	r.layout = backend.pipeline_get_bind_group_layout(r.pipeline, 0)
	if rawptr(r.layout) == nil {
		return true
	}

	entries := []gpu.Gpu_Bind_Entry{
		{binding = 0, buffer = r.params_buffer, offset = 0, size = FULLSCREEN_PARAMS_SIZE, entry_type = .Buffer},
		{binding = 1, buffer = r.cell_buffer, offset = 0, size = u64(n) * FULLSCREEN_CELL_BYTES, entry_type = .Buffer},
		{binding = 2, buffer = r.lut_buffer, offset = 0, size = FULLSCREEN_LUT_BYTES, entry_type = .Buffer},
		{binding = 3, view = atlas_view, entry_type = .Texture_View},
		{binding = 4, sampler = r.sampler, entry_type = .Sampler},
	}
	r.bind_group = backend.create_bind_group(device, r.layout, entries)

	if rawptr(r.bind_group) == nil {
		return true
	}

	fullscreen_write_params(r)
	r.available = true
	return true
}

// fullscreen_write_params uploads the current geometry to the params buffer
// (full 64 bytes: 40-byte params + trailing zero pad).
fullscreen_write_params :: proc(r: ^Fullscreen_Renderer) {
	if r.backend == nil || rawptr(r.queue) == nil || rawptr(r.params_buffer) == nil {
		return
	}
	p := _fullscreen_params(r)
	buf: [FULLSCREEN_PARAMS_SIZE]u8
	mem.copy(raw_data(buf[:]), &p, size_of(Fullscreen_Params))
	r.backend.write_buffer(r.queue, r.params_buffer, 0, raw_data(buf[:]), FULLSCREEN_PARAMS_SIZE)
}

// fullscreen_destroy frees GPU resources in pipeline → group → layout →
// buffers → sampler order. Nil-safe; resets all handles.
fullscreen_destroy :: proc(r: ^Fullscreen_Renderer) {
	if r.backend != nil {
		if rawptr(r.pipeline) != nil {
			r.backend.destroy_render_pipeline(r.pipeline)
			r.pipeline = gpu.Gpu_RenderPipeline(nil)
		}
		if rawptr(r.bind_group) != nil {
			r.backend.destroy_bind_group(r.bind_group)
			r.bind_group = gpu.Gpu_BindGroup(nil)
		}
		if rawptr(r.layout) != nil {
			r.backend.destroy_bind_group_layout(r.layout)
			r.layout = gpu.Gpu_BindGroupLayout(nil)
		}
		if rawptr(r.params_buffer) != nil {
			r.backend.destroy_buffer(r.params_buffer)
			r.params_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.cell_buffer) != nil {
			r.backend.destroy_buffer(r.cell_buffer)
			r.cell_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.lut_buffer) != nil {
			r.backend.destroy_buffer(r.lut_buffer)
			r.lut_buffer = gpu.Gpu_Buffer(nil)
		}
		if rawptr(r.sampler) != nil {
			r.backend.destroy_sampler(r.sampler)
			r.sampler = gpu.Gpu_Sampler(nil)
		}
	}
	r.available = false
}

// fullscreen_resize recreates size-dependent resources (cell buffer on N
// change), rebuilds the bind group, and rewrites params. Unchanged buffers
// are kept. The surface format is baked into the pipeline, so a format
// change returns false (old resources intact; the caller disables
// fullscreen). Returns false as well when the geometry is degenerate or a
// recreation fails.
fullscreen_resize :: proc(r: ^Fullscreen_Renderer, rows: i32, cols: i32, cell_w: f32, cell_h: f32, pad_x: f32, pad_y: f32, format: gpu.Gpu_Format) -> bool {
	if rows <= 0 || cols <= 0 || cell_w <= 0 || cell_h <= 0 || pad_x < 0 || pad_y < 0 {
		return false
	}
	if format != r.format {
		return false
	}
	if r.backend == nil || rawptr(r.device) == nil || rawptr(r.queue) == nil {
		return false
	}
	fb_w := u32(f32(cols) * cell_w)
	fb_h := u32(f32(rows) * cell_h)
	if fb_w == 0 || fb_h == 0 {
		return false
	}
	n := int(rows) * int(cols)
	old_n := int(r.rows) * int(r.cols)
	if n == old_n && fb_w == r.fb_w_px && fb_h == r.fb_h_px && rows == r.rows && cols == r.cols {
		fullscreen_write_params(r)
		return true
	}

	new_cell_buffer := r.cell_buffer
	if n != old_n {
		new_cell_buffer = r.backend.create_buffer(r.device, u64(n) * FULLSCREEN_CELL_BYTES, gpu.Gpu_Buffer_Usage.Storage | gpu.Gpu_Buffer_Usage.Copy_Dst, false)
		if rawptr(new_cell_buffer) == nil {
			return false
		}
	}

	new_group := r.bind_group
	if rawptr(r.layout) != nil {
		entries := []gpu.Gpu_Bind_Entry{
			{binding = 0, buffer = r.params_buffer, offset = 0, size = FULLSCREEN_PARAMS_SIZE, entry_type = .Buffer},
			{binding = 1, buffer = new_cell_buffer, offset = 0, size = u64(n) * FULLSCREEN_CELL_BYTES, entry_type = .Buffer},
			{binding = 2, buffer = r.lut_buffer, offset = 0, size = FULLSCREEN_LUT_BYTES, entry_type = .Buffer},
			{binding = 3, view = r.atlas_view, entry_type = .Texture_View},
			{binding = 4, sampler = r.sampler, entry_type = .Sampler},
		}
		new_group = r.backend.create_bind_group(r.device, r.layout, entries)
		if rawptr(new_group) == nil {
			if new_cell_buffer != r.cell_buffer {
				r.backend.destroy_buffer(new_cell_buffer)
			}
			return false
		}
	}

	if new_group != r.bind_group {
		if rawptr(r.bind_group) != nil {
			r.backend.destroy_bind_group(r.bind_group)
		}
		r.bind_group = new_group
	}
	if new_cell_buffer != r.cell_buffer {
		if rawptr(r.cell_buffer) != nil {
			r.backend.destroy_buffer(r.cell_buffer)
		}
		r.cell_buffer = new_cell_buffer
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
	fullscreen_write_params(r)
	r.available = rawptr(r.pipeline) != nil && rawptr(r.bind_group) != nil
	return true
}

// fullscreen_upload_grid writes the full grid plus (when rebuilt) the LUT.
// cells holds packed V2 u64s in row-major order; lut_words views the raw
// Style_LUT fg+bg bytes as FULLSCREEN_LUT_WORDS u32s. Byte math runs even
// with a nil backend (CPU-only accounting); write_buffer is issued only
// when backend, queue, and buffers are live. Full re-upload, no
// ranges/offsets. Returns total bytes that would be / were uploaded.
fullscreen_upload_grid :: proc(r: ^Fullscreen_Renderer, cells: []u64, lut_words: []u32, lut_changed: bool) -> u64 {
	bytes: u64 = 0
	live := r.backend != nil && rawptr(r.queue) != nil && rawptr(r.cell_buffer) != nil && rawptr(r.lut_buffer) != nil
	n := int(r.rows) * int(r.cols)
	if n > 0 && len(cells) * FULLSCREEN_CELL_BYTES >= n * FULLSCREEN_CELL_BYTES {
		size := u64(n) * FULLSCREEN_CELL_BYTES
		if live {
			r.backend.write_buffer(r.queue, r.cell_buffer, 0, &cells[0], size)
		}
		bytes += size
	}
	if lut_changed && len(lut_words) * 4 >= FULLSCREEN_LUT_BYTES {
		if live {
			r.backend.write_buffer(r.queue, r.lut_buffer, 0, &lut_words[0], FULLSCREEN_LUT_BYTES)
		}
		bytes += FULLSCREEN_LUT_BYTES
	}
	return bytes
}

// fullscreen_draw appends the fullscreen shade and optional cursor draw to
// encoder. It does not finish or submit the encoder; the caller owns the
// shared command buffer and surface lifecycle. Returns true iff encoding
// completed successfully.
fullscreen_draw :: proc(
	r: ^Fullscreen_Renderer,
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
	if rawptr(r.pipeline) == nil || rawptr(r.bind_group) == nil {
		return false
	}
	if rawptr(surface_view) == nil {
		return false
	}
	pass := r.backend.begin_render_pass(encoder, surface_view, {0, 0, 0, 1}, .Clear)
	if rawptr(pass) == nil {
		return false
	}
	r.backend.render_set_pipeline(pass, r.pipeline)
	r.backend.render_set_bind_group(pass, 0, r.bind_group)
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

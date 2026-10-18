package fullscreen

// Terminal Render Pillar - Strategy C: Fullscreen Quad Direct.
//
// Designed for flood updates and rapid vertical scrolling (> 65% dirty cells).
// Employs a single fullscreen triangle pass (3 vertices, no geometry buffer).
// The fragment shader reads directly from cell storage buffers and evaluates
// character ink against the 1024x2048 atlas in a single rendering pass.
//
// Invariant: ZERO Horizontal Dependencies (only base:runtime, core:mem, and contract).

import "base:runtime"
import "core:mem"
import contract "../../contract"

FULLSCREEN_PARAMS_SIZE :: 80
FULLSCREEN_CELL_BYTES :: 8
FULLSCREEN_LUT_WORDS :: 1025
FULLSCREEN_LUT_BYTES :: FULLSCREEN_LUT_WORDS * size_of(u32)

FULLSCREEN_ATLAS_TEX_W :: 1024
FULLSCREEN_ATLAS_TEX_H :: 2048

FULLSCREEN_VERTEX_ENTRY :: "fullscreen_vs_main"
FULLSCREEN_FRAGMENT_ENTRY :: "fullscreen_fs_main"

// Fullscreen_Params mirrors the WGSL/MSL Fullscreen_Params struct.
Fullscreen_Params :: struct {
	screen_w:      f32,
	screen_h:      f32,
	cols:          u32,
	rows:          u32,
	cell_w:        f32,
	cell_h:        f32,
	pad_x:         f32,
	pad_y:         f32,
	atlas_w:       u32,
	atlas_h:       u32,
	bg_opacity:    f32,
	cell_opacity:  f32,
	pane_x:        f32,
	pane_y:        f32,
	pane_w:        f32,
	pane_h:        f32,
	corner_radius: f32,
	_pad0:         f32,
	_pad1:         f32,
	_pad2:         f32,
}
#assert(size_of(Fullscreen_Params) == 80)

// Fullscreen_Renderer holds the fullscreen direct pass GPU state.
Fullscreen_Renderer :: struct {
	device:        contract.Gpu_Device,
	queue:         contract.Gpu_Queue,
	rows:          u32,
	cols:          u32,
	cell_w:        f32,
	cell_h:        f32,
	pad_x:         f32,
	pad_y:         f32,
	available:     bool,
	pipeline:      contract.Gpu_RenderPipeline,
	params_buffer: contract.Gpu_Buffer,
	cell_buffer:   contract.Gpu_Buffer,
	lut_buffer:    contract.Gpu_Buffer,
	atlas_view:    contract.Gpu_TextureView,
	sampler:       contract.Gpu_Sampler,
	bind_group:    contract.Gpu_BindGroup,
	layout:        contract.Gpu_BindGroupLayout,
	fb_w_px:       u32,
	fb_h_px:       u32,
	bg_opacity:    f32,
	cell_opacity:  f32,
	params:        Fullscreen_Params,
	has_params:    bool,
	allocator:     runtime.Allocator,
}

fullscreen_init :: proc(
	r: ^Fullscreen_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	rows: u32,
	cols: u32,
	cell_w: f32,
	cell_h: f32,
	atlas_view: contract.Gpu_TextureView,
	format: contract.Gpu_Format,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil do return false
	r.device = device
	r.queue = queue
	r.rows = rows
	r.cols = cols
	r.cell_w = cell_w
	r.cell_h = cell_h
	r.atlas_view = atlas_view
	r.allocator = allocator
	r.bg_opacity = 1.0
	r.cell_opacity = 1.0

	// Uniform parameters buffer (64 bytes)
	p_usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	r.params_buffer = contract.create_buffer(device, FULLSCREEN_PARAMS_SIZE, p_usage, false)
	if rawptr(r.params_buffer) == nil do return false

	// Cell storage buffer (u64 per cell)
	total_cells := u64(max(rows * cols, 1))
	c_usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	r.cell_buffer = contract.create_buffer(device, total_cells * FULLSCREEN_CELL_BYTES, c_usage, false)
	if rawptr(r.cell_buffer) == nil {
		fullscreen_destroy(r)
		return false
	}

	// LUT storage buffer (1025 u32 words)
	l_usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	r.lut_buffer = contract.create_buffer(device, FULLSCREEN_LUT_BYTES, l_usage, false)
	if rawptr(r.lut_buffer) == nil {
		fullscreen_destroy(r)
		return false
	}

	r.sampler = contract.create_sampler(device)
	r.available = true
	return true
}

fullscreen_destroy :: proc(r: ^Fullscreen_Renderer) {
	if r == nil do return

	if contract.destroy_buffer != nil {
		if rawptr(r.params_buffer) != nil {
			contract.destroy_buffer(r.params_buffer)
			r.params_buffer = contract.Gpu_Buffer(nil)
		}
		if rawptr(r.cell_buffer) != nil {
			contract.destroy_buffer(r.cell_buffer)
			r.cell_buffer = contract.Gpu_Buffer(nil)
		}
		if rawptr(r.lut_buffer) != nil {
			contract.destroy_buffer(r.lut_buffer)
			r.lut_buffer = contract.Gpu_Buffer(nil)
		}
	}
	if contract.destroy_sampler != nil && rawptr(r.sampler) != nil {
		contract.destroy_sampler(r.sampler)
		r.sampler = contract.Gpu_Sampler(nil)
	}
	if contract.destroy_bind_group != nil && rawptr(r.bind_group) != nil {
		contract.destroy_bind_group(r.bind_group)
		r.bind_group = contract.Gpu_BindGroup(nil)
	}
	if contract.destroy_bind_group_layout != nil && rawptr(r.layout) != nil {
		contract.destroy_bind_group_layout(r.layout)
		r.layout = contract.Gpu_BindGroupLayout(nil)
	}
	if contract.destroy_render_pipeline != nil && rawptr(r.pipeline) != nil {
		contract.destroy_render_pipeline(r.pipeline)
		r.pipeline = contract.Gpu_RenderPipeline(nil)
	}
	r.available = false
}

// fullscreen_draw encodes the single fullscreen-triangle draw pass.
fullscreen_draw :: proc(r: ^Fullscreen_Renderer, pass: contract.Gpu_RenderPassEncoder) {
	if r == nil || !r.available || rawptr(pass) == nil do return
	if rawptr(r.pipeline) == nil || rawptr(r.bind_group) == nil do return

	contract.render_set_pipeline(pass, r.pipeline)
	contract.render_set_bind_group(pass, 0, r.bind_group)
	// 3 vertices form a single oversized triangle covering [-1, 1] NDC
	contract.render_draw(pass, 3, 1)
}

package tile

// Terminal Render Pillar - Strategy B: Compute Tile Binning.
//
// Designed for moderate-to-dense screen updates (3% - 65% dirty cells).
// Evaluates screen damage in 16x16 pixel tile bins. A GPU compute shader
// shades only the dirty tiles directly into an off-screen framebuffer texture,
// and a lightweight blit presents it to the swapchain.
//
// Invariant: ZERO Horizontal Dependencies (only base:runtime, core:mem, and contract).

import "base:runtime"
import "core:mem"
import contract "../../contract"

TILE_DEFAULT_W :: 16
TILE_DEFAULT_H :: 16

TILE_PARAMS_SIZE :: 64
TILE_CELL_BYTES :: 8
TILE_LUT_WORDS :: 1025
TILE_LUT_BYTES :: TILE_LUT_WORDS * size_of(u32)

TILE_ATLAS_TEX_W :: 1024
TILE_ATLAS_TEX_H :: 2048

// Tile_Params mirrors the WGSL/MSL Tile_Params struct field for field.
Tile_Params :: struct {
	screen_w:     f32,
	screen_h:     f32,
	cols:         u32,
	rows:         u32,
	cell_w:       f32,
	cell_h:       f32,
	pad_x:        f32,
	pad_y:        f32,
	tile_w:       u32,
	tile_h:       u32,
	tiles_x:      u32,
	tiles_y:      u32,
	atlas_w:      u32,
	atlas_h:      u32,
	bg_opacity:   f32,
	cell_opacity: f32,
}
#assert(size_of(Tile_Params) == 64)

// Compute_Tile_Renderer holds the tiled compute path GPU state.
Compute_Tile_Renderer :: struct {
	device:             contract.Gpu_Device,
	queue:              contract.Gpu_Queue,
	tile_w:             u32,
	tile_h:             u32,
	rows:               u32,
	cols:               u32,
	cell_w:             f32,
	cell_h:             f32,
	pad_x:              f32,
	pad_y:              f32,
	available:          bool,
	compute_pipeline:   contract.Gpu_ComputePipeline,
	blit_pipeline:      contract.Gpu_RenderPipeline,
	framebuffer:        contract.Gpu_Texture,
	fb_view:            contract.Gpu_TextureView,
	params_buffer:      contract.Gpu_Buffer,
	tile_list_buffer:   contract.Gpu_Buffer,
	cell_buffer:        contract.Gpu_Buffer,
	lut_buffer:         contract.Gpu_Buffer,
	atlas_view:         contract.Gpu_TextureView,
	sampler:            contract.Gpu_Sampler,
	compute_bind_group: contract.Gpu_BindGroup,
	blit_bind_group:    contract.Gpu_BindGroup,
	compute_layout:     contract.Gpu_BindGroupLayout,
	blit_layout:        contract.Gpu_BindGroupLayout,
	fb_w_px:            u32,
	fb_h_px:            u32,
	tiles_x:            u32,
	tiles_y:            u32,
	tile_count:         u32,
	params:             Tile_Params,
	has_params:         bool,
	bg_opacity:         f32,
	cell_opacity:       f32,
	allocator:          runtime.Allocator,
}

compute_tile_init :: proc(
	r: ^Compute_Tile_Renderer,
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
	r.tile_w = TILE_DEFAULT_W
	r.tile_h = TILE_DEFAULT_H
	r.bg_opacity = 1.0
	r.cell_opacity = 1.0

	// Uniform parameters buffer (64 bytes)
	p_usage := contract.Gpu_Buffer_Usage.Uniform | contract.Gpu_Buffer_Usage.Copy_Dst
	r.params_buffer = contract.create_buffer(device, TILE_PARAMS_SIZE, p_usage, false)
	if rawptr(r.params_buffer) == nil do return false

	// Cell storage buffer (u64 per cell)
	total_cells := u64(max(rows * cols, 1))
	c_usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	r.cell_buffer = contract.create_buffer(device, total_cells * TILE_CELL_BYTES, c_usage, false)
	if rawptr(r.cell_buffer) == nil {
		compute_tile_destroy(r)
		return false
	}

	// LUT storage buffer (1025 u32 words)
	l_usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	r.lut_buffer = contract.create_buffer(device, TILE_LUT_BYTES, l_usage, false)
	if rawptr(r.lut_buffer) == nil {
		compute_tile_destroy(r)
		return false
	}

	// Tile list buffer
	r.tiles_x = max((u32(f32(cols) * cell_w) + r.tile_w - 1) / r.tile_w, 1)
	r.tiles_y = max((u32(f32(rows) * cell_h) + r.tile_h - 1) / r.tile_h, 1)
	r.tile_count = r.tiles_x * r.tiles_y
	t_usage := contract.Gpu_Buffer_Usage.Storage | contract.Gpu_Buffer_Usage.Copy_Dst
	r.tile_list_buffer = contract.create_buffer(device, u64(r.tile_count) * size_of(u32), t_usage, false)
	if rawptr(r.tile_list_buffer) == nil {
		compute_tile_destroy(r)
		return false
	}

	r.sampler = contract.create_sampler(device)
	r.available = true
	return true
}

compute_tile_destroy :: proc(r: ^Compute_Tile_Renderer) {
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
		if rawptr(r.tile_list_buffer) != nil {
			contract.destroy_buffer(r.tile_list_buffer)
			r.tile_list_buffer = contract.Gpu_Buffer(nil)
		}
	}
	if contract.destroy_texture != nil && rawptr(r.framebuffer) != nil {
		contract.destroy_texture(r.framebuffer)
		r.framebuffer = contract.Gpu_Texture(nil)
	}
	if contract.destroy_texture_view != nil && rawptr(r.fb_view) != nil {
		contract.destroy_texture_view(r.fb_view)
		r.fb_view = contract.Gpu_TextureView(nil)
	}
	if contract.destroy_sampler != nil && rawptr(r.sampler) != nil {
		contract.destroy_sampler(r.sampler)
		r.sampler = contract.Gpu_Sampler(nil)
	}
	if contract.destroy_bind_group != nil {
		if rawptr(r.compute_bind_group) != nil {
			contract.destroy_bind_group(r.compute_bind_group)
			r.compute_bind_group = contract.Gpu_BindGroup(nil)
		}
		if rawptr(r.blit_bind_group) != nil {
			contract.destroy_bind_group(r.blit_bind_group)
			r.blit_bind_group = contract.Gpu_BindGroup(nil)
		}
	}
	if contract.destroy_compute_pipeline != nil && rawptr(r.compute_pipeline) != nil {
		contract.destroy_compute_pipeline(r.compute_pipeline)
		r.compute_pipeline = contract.Gpu_ComputePipeline(nil)
	}
	if contract.destroy_render_pipeline != nil && rawptr(r.blit_pipeline) != nil {
		contract.destroy_render_pipeline(r.blit_pipeline)
		r.blit_pipeline = contract.Gpu_RenderPipeline(nil)
	}
	r.available = false
}

// compute_tile_dispatch encodes the compute dispatch pass for dirty tiles.
compute_tile_dispatch :: proc(r: ^Compute_Tile_Renderer, enc: contract.Gpu_CommandEncoder, dirty_tile_count: u32) {
	if r == nil || !r.available || rawptr(enc) == nil || dirty_tile_count == 0 do return
	if rawptr(r.compute_pipeline) == nil || rawptr(r.compute_bind_group) == nil do return

	cpass := contract.begin_compute_pass(enc)
	if rawptr(cpass) == nil do return
	defer contract.end_compute_pass(cpass)

	contract.compute_set_pipeline(cpass, r.compute_pipeline)
	contract.compute_set_bind_group(cpass, 0, r.compute_bind_group)
	// Dispatch 1 threadgroup per dirty tile (16x16 threads per group)
	contract.compute_dispatch(cpass, dirty_tile_count, 1, 1)
}

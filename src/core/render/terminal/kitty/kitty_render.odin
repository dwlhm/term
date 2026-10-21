package terminal_kitty

import "base:runtime"
import "core:time"
import contract "../../contract"
import core_terminal "../../../terminal"
import ext "../../../terminal/extension"

Kitty_Renderer :: struct {
	device:          contract.Gpu_Device,
	queue:           contract.Gpu_Queue,
	pipeline:        contract.Gpu_RenderPipeline,
	layout:          contract.Gpu_BindGroupLayout,
	sampler:         contract.Gpu_Sampler,
	instance_buffer: contract.Gpu_Buffer,
	uniform_buffer:  contract.Gpu_Buffer,
	buffer_capacity: int,
	draw_batches:    [dynamic]Kitty_Draw_Batch,
	instance_data:   [dynamic]contract.Instance_Record,
	available:       bool,
	allocator:       runtime.Allocator,
}

kitty_renderer_init :: proc(
	r: ^Kitty_Renderer,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
	pipeline: contract.Gpu_RenderPipeline,
	layout: contract.Gpu_BindGroupLayout,
	sampler: contract.Gpu_Sampler,
	uniform_buffer: contract.Gpu_Buffer,
	allocator: runtime.Allocator = context.allocator,
) -> bool {
	if r == nil || rawptr(device) == nil || rawptr(queue) == nil do return false
	r.device = device
	r.queue = queue
	r.pipeline = pipeline
	r.layout = layout
	r.sampler = sampler
	r.uniform_buffer = uniform_buffer
	r.allocator = allocator

	initial_cap := 4096
	r.buffer_capacity = initial_cap
	buffer_size := u64(initial_cap * size_of(contract.Instance_Record))
	r.instance_buffer = contract.create_buffer(device, buffer_size, .Vertex | .Copy_Dst, false)
	r.draw_batches = make([dynamic]Kitty_Draw_Batch, 0, 64, allocator)
	r.instance_data = make([dynamic]contract.Instance_Record, 0, initial_cap, allocator)
	r.available = rawptr(r.instance_buffer) != nil
	return r.available
}

kitty_renderer_destroy :: proc(r: ^Kitty_Renderer) {
	if r == nil do return
	if rawptr(r.instance_buffer) != nil do contract.destroy_buffer(r.instance_buffer)
	delete(r.draw_batches)
	delete(r.instance_data)
	r.available = false
}

_kitty_ensure_instance_capacity :: proc(r: ^Kitty_Renderer, needed: int) {
	if needed <= r.buffer_capacity do return
	new_cap := max(needed, r.buffer_capacity * 2)
	if rawptr(r.instance_buffer) != nil do contract.destroy_buffer(r.instance_buffer)
	buf_size := u64(new_cap * size_of(contract.Instance_Record))
	r.instance_buffer = contract.create_buffer(r.device, buf_size, .Vertex | .Copy_Dst, false)
	r.buffer_capacity = new_cap
}

_kitty_sync_single_image :: proc(r: ^Kitty_Renderer, img: ^ext.Kitty_Image) {
	if img.gpu_group != nil { contract.destroy_bind_group(contract.Gpu_BindGroup(img.gpu_group)); img.gpu_group = nil }
	if img.gpu_view != nil { contract.destroy_texture_view(contract.Gpu_TextureView(img.gpu_view)); img.gpu_view = nil }
	if img.gpu_texture != nil { contract.destroy_texture(contract.Gpu_Texture(img.gpu_texture)); img.gpu_texture = nil }

	if !img.is_active || len(img.pixels) == 0 {
		img.gpu_dirty = false
		return
	}

	w_u32 := u32(max(1, img.width))
	h_u32 := u32(max(1, img.height))
	tex := contract.create_texture(r.device, w_u32, h_u32, .RGBA8_Unorm, .Copy_Dst | .Texture_Binding)
	if rawptr(tex) == nil {
		img.gpu_dirty = false
		return
	}

	contract.write_texture(r.queue, tex, img.pixels, w_u32, h_u32)
	view := contract.create_texture_view(tex)

	entries := []contract.Gpu_Bind_Entry{
		{binding = 0, buffer = r.uniform_buffer, entry_type = .Buffer},
		{binding = 1, view = view, entry_type = .Texture_View},
		{binding = 2, sampler = r.sampler, entry_type = .Sampler},
	}
	group := contract.create_bind_group(r.device, r.layout, entries)

	img.gpu_texture = rawptr(tex)
	img.gpu_view = rawptr(view)
	img.gpu_group = rawptr(group)
	img.gpu_dirty = false
}

kitty_renderer_sync_images :: proc(r: ^Kitty_Renderer, term: ^core_terminal.Terminal) {
	if r == nil || !r.available || term == nil do return
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	for i in 0..<term.extensions.ext_count {
		e := &term.extensions.extensions[i]
		if e.name != "kitty_graphics" || e.user_data == nil do continue
		kstate := (^ext.Kitty_Extension)(e.user_data)
		for j in 0..<ext.MAX_KITTY_IMAGES {
			img := &kstate.images[j]
			if img.is_active {
				ext.kitty_animation_tick(img, now_ms)
			}
			if img.gpu_dirty do _kitty_sync_single_image(r, img)
		}
	}
}

kitty_renderer_has_images :: proc(r: ^Kitty_Renderer, term: ^core_terminal.Terminal) -> bool {
	if r == nil || !r.available || term == nil do return false
	for i in 0..<term.extensions.ext_count {
		e := &term.extensions.extensions[i]
		if e.name != "kitty_graphics" || e.user_data == nil do continue
		kstate := (^ext.Kitty_Extension)(e.user_data)
		for j in 0..<ext.MAX_KITTY_IMAGES {
			img := &kstate.images[j]
			if img.is_active {
				if img.is_virtual do return true
				for k in 0..<len(kstate.placements) {
					if kstate.placements[k].is_active && kstate.placements[k].image_id == img.id {
						return true
					}
				}
			}
		}
	}
	return false
}

_kitty_count_active :: proc(term: ^core_terminal.Terminal) -> int {
	count := 0
	for i in 0..<term.extensions.ext_count {
		e := &term.extensions.extensions[i]
		if e.name != "kitty_graphics" || e.user_data == nil do continue
		kstate := (^ext.Kitty_Extension)(e.user_data)
		for j in 0..<ext.MAX_KITTY_IMAGES {
			if kstate.images[j].is_active && kstate.images[j].gpu_group != nil do count += 1
		}
	}
	return count
}

kitty_renderer_prepare :: proc(
	r: ^Kitty_Renderer,
	term: ^core_terminal.Terminal,
	pane_rect: [4]f32,
	cell_w, cell_h, pad_x, pad_y: f32,
	scroll_offset: int = 0,
) {
	if r == nil || !r.available || term == nil do return
	kitty_renderer_sync_images(r, term)

	active_count := _kitty_count_active(term)
	clear(&r.instance_data)
	clear(&r.draw_batches)
	if active_count == 0 do return

	for i in 0..<term.extensions.ext_count {
		e := &term.extensions.extensions[i]
		if e.name != "kitty_graphics" || e.user_data == nil do continue
		kstate := (^ext.Kitty_Extension)(e.user_data)

		for j in 0..<ext.MAX_KITTY_IMAGES {
			img := &kstate.images[j]
			if !img.is_active || img.gpu_group == nil do continue

			start_idx := len(r.instance_data)
			if img.is_virtual {
				_kitty_collect_placeholder_cells(r, img, term, pane_rect, cell_w, cell_h, pad_x, pad_y, scroll_offset, active_count)
			} else {
				for k in 0..<len(kstate.placements) {
					p := &kstate.placements[k]
					if !p.is_active || p.image_id != img.id do continue
					if p.y_row + scroll_offset + p.rows <= 0 do continue
					if p.y_row + scroll_offset >= term.rows do continue
					rec := _kitty_calc_placement_record(p, img, pane_rect, cell_w, cell_h, pad_x, pad_y, scroll_offset)
					append(&r.instance_data, rec)
				}
			}

			count := len(r.instance_data) - start_idx
			if count > 0 {
				append(&r.draw_batches, Kitty_Draw_Batch{
					gpu_group      = img.gpu_group,
					start_instance = start_idx,
					instance_count = count,
					z_index        = 0,
				})
			}
		}
	}

	if len(r.instance_data) > 0 {
		_kitty_ensure_instance_capacity(r, len(r.instance_data))
		bytes := u64(len(r.instance_data) * size_of(contract.Instance_Record))
		contract.write_buffer(r.queue, r.instance_buffer, 0, raw_data(r.instance_data), bytes)
	}
}

kitty_renderer_draw :: proc(
	r: ^Kitty_Renderer,
	pass: contract.Gpu_RenderPassEncoder,
	term: ^core_terminal.Terminal,
) {
	if r == nil || !r.available || rawptr(pass) == nil || term == nil do return
	if len(r.draw_batches) == 0 do return

	contract.render_set_pipeline(pass, r.pipeline)
	for batch in r.draw_batches {
		if batch.gpu_group == nil || batch.instance_count <= 0 do continue
		contract.render_set_bind_group(pass, 0, contract.Gpu_BindGroup(batch.gpu_group))
		offset := u64(batch.start_instance * size_of(contract.Instance_Record))
		contract.render_set_vertex_buffer(pass, 0, r.instance_buffer, offset)
		contract.render_draw(pass, 6, u32(batch.instance_count))
	}
}

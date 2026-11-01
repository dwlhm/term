package main

// GPU colour-layout regression: instance, compute-tile and fullscreen must
// agree pixel-for-pixel for cells that carry truecolor fg/bg plus an SGR 4:3
// curly underline colour (58:2::255:0:0).
//
// This is the guard for the shared COLOR_WORDS_PER_CELL layout. If a host
// buffer/upload drifts back to two words per cell, the shaders read a
// neighbouring cell's word (or past the buffer) and the comparison fails.
// The run also renders the fullscreen target from a deliberately
// 2-word-per-cell upload and requires the comparator to catch it.

import "core:fmt"
import "vendor:wgpu"

import contract "../../core/render/contract"
import fullscreen "../../core/render/terminal/fullscreen"
import terminal_instance "../../core/render/terminal/instance"
import tile "../../core/render/terminal/tile"

_map_readback :: proc(h: ^Harness_State, buf: contract.Gpu_Buffer, size: u64) -> [^]u8 {
	done := false
	done_ptr := &done
	_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		if userdata1 != nil do (^bool)(userdata1)^ = true
	}
	_ = wgpu.BufferMapAsync(
		wgpu.Buffer(rawptr(buf)),
		{.Read},
		0,
		uint(size),
		wgpu.BufferMapCallbackInfo{mode = .AllowProcessEvents, callback = _on_map, userdata1 = done_ptr},
	)
	for !done {
		wgpu.InstanceProcessEvents(wgpu.Instance(h.instance))
		wgpu.DevicePoll(wgpu.Device(rawptr(h.device)), true, nil)
	}
	return ([^]u8)(wgpu.RawBufferGetConstMappedRange(wgpu.Buffer(rawptr(buf)), 0, uint(size)))
}

_compare_pixels :: proc(a, b: [^]u8, bytes_per_row: u32) -> (diff, first_x, first_y: int) {
	first_x = -1
	first_y = -1
	if a == nil || b == nil do return
	for y in 0..<int(COLOR_TEST_H) {
		row := y * int(bytes_per_row)
		for x in 0..<int(COLOR_TEST_W) {
			off := row + x * 4
			if a[off] != b[off] || a[off + 1] != b[off + 1] || a[off + 2] != b[off + 2] || a[off + 3] != b[off + 3] {
				diff += 1
				if first_x == -1 {
					first_x = x
					first_y = y
				}
			}
		}
	}
	return
}

_Color_Renderers :: struct {
	inst:  terminal_instance.Instance_Renderer,
	decor: terminal_instance.Instance_Renderer,
	tile:  tile.Compute_Tile_Renderer,
	fs:    fullscreen.Fullscreen_Renderer,
}

// _color_renderers_init builds the three strategy renderers plus the separate
// decoration batch (underlines must paint after glyphs, like the shaders).
_color_renderers_init :: proc(h: ^Harness_State, r: ^_Color_Renderers, sampler: contract.Gpu_Sampler) {
	terminal_instance.instance_renderer_init(&r.inst, h.device, h.queue, COLOR_TEST_COLS * COLOR_TEST_ROWS, h.atlas.gpu_view, h.format)
	terminal_instance.instance_renderer_init(&r.decor, h.device, h.queue, COLOR_TEST_COLS * COLOR_TEST_ROWS, h.atlas.gpu_view, h.format)
	tile.compute_tile_init(&r.tile, h.device, h.queue, COLOR_TEST_ROWS, COLOR_TEST_COLS, COLOR_TEST_CELL_W, COLOR_TEST_CELL_H, h.atlas.gpu_view, h.format)
	fullscreen.fullscreen_init(&r.fs, h.device, h.queue, COLOR_TEST_ROWS, COLOR_TEST_COLS, COLOR_TEST_CELL_W, COLOR_TEST_CELL_H, h.atlas.gpu_view, h.format)
	for ptr in ([]^terminal_instance.Instance_Renderer{&r.inst, &r.decor}) {
		if rawptr(ptr.sampler) != nil do contract.destroy_sampler(ptr.sampler)
		ptr.sampler = sampler
	}
	if rawptr(r.tile.sampler) != nil do contract.destroy_sampler(r.tile.sampler)
	r.tile.sampler = sampler
	if rawptr(r.fs.sampler) != nil do contract.destroy_sampler(r.fs.sampler)
	r.fs.sampler = sampler
	// Curly underlines emit one quad per band run, so reserve room per cell.
	_rebuild_instance_resources(h, &r.inst, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H), 48)
	_rebuild_instance_resources(h, &r.decor, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H), 48)
}

_color_renderers_destroy :: proc(r: ^_Color_Renderers) {
	// Pipelines and the shared sampler are owned by Harness_State.
	r.inst.sampler = contract.Gpu_Sampler(nil)
	r.inst.pipeline = contract.Gpu_RenderPipeline(nil)
	r.decor.sampler = contract.Gpu_Sampler(nil)
	r.decor.pipeline = contract.Gpu_RenderPipeline(nil)
	r.tile.sampler = contract.Gpu_Sampler(nil)
	r.tile.compute_pipeline = contract.Gpu_ComputePipeline(nil)
	r.tile.blit_pipeline = contract.Gpu_RenderPipeline(nil)
	r.fs.sampler = contract.Gpu_Sampler(nil)
	r.fs.pipeline = contract.Gpu_RenderPipeline(nil)
	terminal_instance.instance_renderer_destroy(&r.inst)
	terminal_instance.instance_renderer_destroy(&r.decor)
	tile.compute_tile_destroy(&r.tile)
	fullscreen.fullscreen_destroy(&r.fs)
}

_run_color_layout_regression :: proc(h: ^Harness_State) -> bool {
	fmt.println("================================================================================")
	fmt.println("     COLOUR LAYOUT REGRESSION: 3-WORD CELLs + UNDERLINE COLOUR (SGR 4:3)        ")
	fmt.println("================================================================================")

	bytes_per_row: u32 = ((COLOR_TEST_W * 4) + 255) & ~u32(255)
	buf_size: u64 = u64(bytes_per_row) * u64(COLOR_TEST_H)
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	buf_usage := contract.Gpu_Buffer_Usage.Map_Read | contract.Gpu_Buffer_Usage.Copy_Dst

	targets: [3]_Color_Target
	for &t in targets {
		t.tex = contract.create_texture(h.device, COLOR_TEST_W, COLOR_TEST_H, h.format, tex_usage)
		t.view = contract.create_texture_view(t.tex)
		t.buf = contract.create_buffer(h.device, buf_size, buf_usage, false)
	}
	defer for &t in targets {
		if rawptr(t.buf) != nil do contract.destroy_buffer(t.buf)
		if rawptr(t.view) != nil do contract.destroy_texture_view(t.view)
		if rawptr(t.tex) != nil do contract.destroy_texture(t.tex)
	}

	nearest := wgpu.SamplerDescriptor{
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		magFilter     = .Nearest,
		minFilter     = .Nearest,
		mipmapFilter  = .Nearest,
		lodMaxClamp   = 32.0,
		maxAnisotropy = 1,
	}
	nearest_sampler := contract.Gpu_Sampler(wgpu.DeviceCreateSampler(wgpu.Device(rawptr(h.device)), &nearest))
	defer if rawptr(nearest_sampler) != nil do contract.destroy_sampler(nearest_sampler)

	renderers: _Color_Renderers
	color_buf: contract.Gpu_Buffer
	defer if rawptr(color_buf) != nil do contract.destroy_buffer(color_buf)
	_color_renderers_init(h, &renderers, nearest_sampler)
	defer _color_renderers_destroy(&renderers)

	_rebuild_fullscreen_resources(h, &renderers.fs, &color_buf, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H))
	_rebuild_tile_resources(h, &renderers.tile, color_buf, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H))

	term: Synthetic_Terminal
	synthetic_terminal_init(&term, COLOR_TEST_COLS, COLOR_TEST_ROWS)
	defer synthetic_terminal_destroy(&term)
	_fill_color_test_cells(&term)

	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &renderers.inst, &renderers.decor, &term, targets[0].view)
	_encode_tile_target(h, enc, &renderers.tile, &term, color_buf, targets[1].view)
	_encode_fullscreen_target(h, enc, &renderers.fs, &term, color_buf, targets[2].view)
	for &t in targets do _encode_readback(enc, t.tex, t.buf, bytes_per_row)
	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd != nil {
		contract.submit(h.queue, cmd)
		contract.release_command_buffer(cmd)
	}
	contract.wait_for_idle(h.device)

	ptr_i := _map_readback(h, targets[0].buf, buf_size)
	ptr_t := _map_readback(h, targets[1].buf, buf_size)
	ptr_f := _map_readback(h, targets[2].buf, buf_size)
	d_it, x_it, y_it := _compare_pixels(ptr_i, ptr_t, bytes_per_row)
	d_if, x_if, y_if := _compare_pixels(ptr_i, ptr_f, bytes_per_row)
	d_tf, x_tf, y_tf := _compare_pixels(ptr_t, ptr_f, bytes_per_row)
	for &t in targets do wgpu.BufferUnmap(wgpu.Buffer(rawptr(t.buf)))

	ok := true
	if d_it > 0 || d_if > 0 || d_tf > 0 {
		fmt.printfln("[FAIL] Strategy pixels diverge: instance-tile=%d (%d,%d) instance-fullscreen=%d (%d,%d) tile-fullscreen=%d (%d,%d)",
			d_it, x_it, y_it, d_if, x_if, y_if, d_tf, x_tf, y_tf)
		ok = false
	} else {
		fmt.println("[PASS] instance == tile == fullscreen for 256 truecolor+underline cells (0 diff pixels)")
	}

	// Mutation probe: a host that lays the words out at the old two-word stride
	// must be caught even though the shaders still read COLOR_WORDS_PER_CELL.
	enc_mut := contract.create_command_encoder(h.device)
	if rawptr(enc_mut) == nil do return false
	_encode_fullscreen_target(h, enc_mut, &renderers.fs, &term, color_buf, targets[2].view, 2)
	_encode_readback(enc_mut, targets[2].tex, targets[2].buf, bytes_per_row)
	cmd_mut := contract.finish_command_buffer(enc_mut)
	contract.release_command_encoder(enc_mut)
	if cmd_mut != nil {
		contract.submit(h.queue, cmd_mut)
		contract.release_command_buffer(cmd_mut)
	}
	contract.wait_for_idle(h.device)

	ptr_i = _map_readback(h, targets[0].buf, buf_size)
	ptr_f = _map_readback(h, targets[2].buf, buf_size)
	d_mut, x_mut, y_mut := _compare_pixels(ptr_i, ptr_f, bytes_per_row)
	wgpu.BufferUnmap(wgpu.Buffer(rawptr(targets[0].buf)))
	wgpu.BufferUnmap(wgpu.Buffer(rawptr(targets[2].buf)))
	if d_mut > 0 {
		fmt.printfln("[PASS] Mutation: two-word colour stride caught (%d diff pixels, first at %d,%d)", d_mut, x_mut, y_mut)
	} else {
		fmt.println("[FAIL] Mutation: two-word colour stride was NOT caught!")
		ok = false
	}
	return ok
}

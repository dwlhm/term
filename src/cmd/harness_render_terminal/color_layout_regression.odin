package main

// GPU colour-layout and decoration regression for Instance_Renderer:
// verifies deterministic pixel output for cells carrying truecolor fg/bg,
// SGR 4:1..4:5 coloured underlines, strikethrough, and synthetic italic shear,
// and verifies that all mutation probes are caught.

import "core:fmt"
import "vendor:wgpu"

import contract "../../core/render/contract"
import terminal_instance "../../core/render/terminal/instance"

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
	inst_a: terminal_instance.Instance_Renderer,
	inst_b: terminal_instance.Instance_Renderer,
}

_color_renderers_init :: proc(h: ^Harness_State, r: ^_Color_Renderers, sampler: contract.Gpu_Sampler) {
	terminal_instance.instance_renderer_init(&r.inst_a, h.device, h.queue, COLOR_TEST_COLS * COLOR_TEST_ROWS, h.atlas.gpu_view, h.format)
	terminal_instance.instance_renderer_init(&r.inst_b, h.device, h.queue, COLOR_TEST_COLS * COLOR_TEST_ROWS, h.atlas.gpu_view, h.format)
	if rawptr(r.inst_a.sampler) != nil do contract.destroy_sampler(r.inst_a.sampler)
	r.inst_a.sampler = sampler
	if rawptr(r.inst_b.sampler) != nil do contract.destroy_sampler(r.inst_b.sampler)
	r.inst_b.sampler = sampler
	// Decorations emit one quad per band run, so reserve room per cell.
	_rebuild_instance_resources(h, &r.inst_a, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H), 48)
	_rebuild_instance_resources(h, &r.inst_b, COLOR_TEST_COLS, COLOR_TEST_ROWS, f32(COLOR_TEST_W), f32(COLOR_TEST_H), 48)
}

_color_renderers_destroy :: proc(r: ^_Color_Renderers) {
	r.inst_a.sampler = contract.Gpu_Sampler(nil)
	r.inst_a.pipeline = contract.Gpu_RenderPipeline(nil)
	r.inst_b.sampler = contract.Gpu_Sampler(nil)
	r.inst_b.pipeline = contract.Gpu_RenderPipeline(nil)
	terminal_instance.instance_renderer_destroy(&r.inst_a)
	terminal_instance.instance_renderer_destroy(&r.inst_b)
}

_run_color_layout_regression :: proc(h: ^Harness_State) -> bool {
	fmt.println("================================================================================")
	fmt.println("  COLOUR + DECORATION CONTRACT: STRIKE, SGR 4:n COLOUR, DECOR OVER GLYPHS        ")
	fmt.println("================================================================================")

	bytes_per_row: u32 = ((COLOR_TEST_W * 4) + 255) & ~u32(255)
	buf_size: u64 = u64(bytes_per_row) * u64(COLOR_TEST_H)
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	buf_usage := contract.Gpu_Buffer_Usage.Map_Read | contract.Gpu_Buffer_Usage.Copy_Dst

	targets: [2]_Color_Target
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
	_color_renderers_init(h, &renderers, nearest_sampler)
	defer _color_renderers_destroy(&renderers)

	term: Synthetic_Terminal
	synthetic_terminal_init(&term, COLOR_TEST_COLS, COLOR_TEST_ROWS)
	defer synthetic_terminal_destroy(&term)
	_fill_color_test_cells(&term)

	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	_encode_instance_target(h, enc, &renderers.inst_a, &term, targets[0].view)
	_encode_instance_target(h, enc, &renderers.inst_b, &term, targets[1].view)
	for &t in targets do _encode_readback(enc, t.tex, t.buf, bytes_per_row)
	_submit_encoder(h, enc)

	d_ab, x_ab, y_ab := _readback_compare(h, &targets[0], &targets[1], buf_size, bytes_per_row)

	ok := true
	if d_ab > 0 {
		fmt.printfln("[FAIL] Instance baseline targets diverge: diff=%d (%d,%d)", d_ab, x_ab, y_ab)
		ok = false
	} else {
		fmt.println("[PASS] Instance baseline deterministic for 256 strike + SGR 4:n + bold/italic cells (0 diff pixels)")
	}

	if !_run_color_layout_mutations(h, &renderers, &targets, &term, buf_size, bytes_per_row) {
		ok = false
	}
	return ok
}

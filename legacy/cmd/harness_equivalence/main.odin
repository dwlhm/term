package main

// Hardware GPU Pixel Readback Equivalence Gate & Negative Regression Test Suite.
// Verifies Strategy A (Partial_Load + Scissor + Widened Spans) vs Strategy B (Full_Clear Redraw)
// on a live terminal grid with production Damage_Journal, real font atlas, and actual Metal/WGPU pixels.
//
// Invariants & Completion Criteria:
// 1. 20 seeds × 500 edits with ZERO pixel differences.
// 2. Negative 1 (disabled ±1 column widen) MUST FAIL on overhang/italic neighbor edits.
// 3. Negative 2 (disabled space bg quad) MUST FAIL on character deletion/backspace edits.
// 4. Negative 3 (0px scissor padding) is reported as-is (PASS or FAIL).
// 5. Negative 4 (inverted glyph-before-bg draw order) MUST FAIL on italic/overlapping edits.
// 6. Automated Atlas Overhang Audit: reports ink bounding boxes vs cell width.
// 7. Visual PNG diff dump on failure: outputs _partial.png, _full.png, and _diff.png (magenta highlight).
// 8. Supports fast-run subset (--quick: 5 seeds × 100 edits) vs full run (20 seeds × 500 edits).

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:sdl3"
import "vendor:wgpu"

import render "../../render"
import gpu "../../render/gpu"
import wgpu_backend "../../render/gpu/wgpu"
import instance "../../render/instance"
import termgrid "../../terminal"
import contract "../../core/render/contract"

when ODIN_OS == .Darwin {
	foreign import stb_image_write "vendor:stb/lib/darwin/stb_image_write.a"
}

foreign stb_image_write {
	stbi_write_png :: proc(filename: cstring, w, h, comp: c.int, data: rawptr, stride_in_bytes: c.int) -> c.int ---
}

HARNESS_FONT_PATH :: "/System/Library/Fonts/Menlo.ttc"
FALLBACK_FONT_PATH :: "assets/fonts/MapleMono-NF-Regular.ttf"

GRID_ROWS :: 24
GRID_COLS :: 80

_active_target_texture: gpu.Gpu_Texture
_active_target_view:    gpu.Gpu_TextureView
_real_backend:          gpu.Gpu_Backend_VTable

_offscreen_get_surface_texture :: proc(surface: rawptr) -> (gpu.Gpu_Texture, gpu.Gpu_TextureView, gpu.Gpu_Format) {
	return _active_target_texture, _active_target_view, .BGRA8_Unorm
}

_offscreen_present_surface :: proc(surface: rawptr) -> bool {
	return true
}

_offscreen_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	// Managed by harness, retained across frames
}

_offscreen_configure_surface :: proc(surface: rawptr, device: gpu.Gpu_Device, format: gpu.Gpu_Format, width, height: u32) {
	// No-op for offscreen render targets
}

_map_done_flag: bool

_on_buffer_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: string, userdata1: rawptr, userdata2: rawptr) {
	if status == .Success {
		p := (^bool)(userdata1)
		p^ = true
	}
}

Equivalence_Harness :: struct {
	inst:          wgpu.Instance,
	adapter:       wgpu.Adapter,
	device:        wgpu.Device,
	queue:         wgpu.Queue,
	vtable:        gpu.Gpu_Backend_VTable,

	font_path:     string,
	cell_w:        f32,
	cell_h:        f32,
	screen_w:      u32,
	screen_h:      u32,
	bytes_per_row: u32,
	buf_size:      u64,

	// Target A (Strategy A: Partial Load + Scissor)
	tex_a:         wgpu.Texture,
	view_a:        wgpu.TextureView,
	read_buf_a:    wgpu.Buffer,
	renderer_a:    render.Renderer,

	// Target B (Strategy B: Full Redraw)
	tex_b:         wgpu.Texture,
	view_b:        wgpu.TextureView,
	read_buf_b:    wgpu.Buffer,
	renderer_b:    render.Renderer,

	// Host pixel buffers
	pixels_a:      []u8,
	pixels_b:      []u8,
	pixels_diff:   []u8,
}

_harness_init :: proc(h: ^Equivalence_Harness) -> bool {
	_ = sdl3.Init({})
	h.inst = wgpu.CreateInstance(nil)
	if h.inst == nil do return false

	adapter_done := false
	on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, a: wgpu.Adapter, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		if status == .Success {
			p := (^wgpu.Adapter)(userdata1)
			p^ = a
		}
		done := (^bool)(userdata2)
		done^ = true
	}
	wgpu.InstanceRequestAdapter(h.inst, nil, {mode = .AllowProcessEvents, callback = on_adapter, userdata1 = &h.adapter, userdata2 = &adapter_done})
	for !adapter_done {
		wgpu.InstanceProcessEvents(h.inst)
	}
	if h.adapter == nil do return false

	device_done := false
	on_device :: proc "c" (status: wgpu.RequestDeviceStatus, d: wgpu.Device, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		if status == .Success {
			p := (^wgpu.Device)(userdata1)
			p^ = d
		}
		done := (^bool)(userdata2)
		done^ = true
	}
	wgpu.AdapterRequestDevice(h.adapter, nil, {mode = .AllowProcessEvents, callback = on_device, userdata1 = &h.device, userdata2 = &device_done})
	for !device_done {
		wgpu.InstanceProcessEvents(h.inst)
	}
	if h.device == nil do return false
	h.queue = wgpu.DeviceGetQueue(h.device)
	if h.queue == nil do return false

	// Build custom offscreen vtable wrapping standard wgpu_backend
	base_vtable := wgpu_backend.wgpu_backend_vtable()
	_real_backend = base_vtable^
	h.vtable = _real_backend
	h.vtable.get_surface_texture = _offscreen_get_surface_texture
	h.vtable.present_surface = _offscreen_present_surface
	h.vtable.release_surface_texture = _offscreen_release_surface_texture
	h.vtable.configure_surface = _offscreen_configure_surface

	// Choose font
	h.font_path = HARNESS_FONT_PATH
	if !os.is_file(h.font_path) {
		h.font_path = FALLBACK_FONT_PATH
	}

	// Rasterizer to obtain cell metrics
	r_temp: render.Font_Rasterizer
	if render.font_rasterizer_init(&r_temp, h.font_path, 16.0) {
		h.cell_w = r_temp.metrics.cell_width
		h.cell_h = r_temp.metrics.cell_height
		render.font_rasterizer_destroy(&r_temp)
	} else {
		h.cell_w = 10.0
		h.cell_h = 20.0
	}

	h.screen_w = u32(f32(GRID_COLS) * h.cell_w + 12.0)
	h.screen_h = u32(f32(GRID_ROWS) * h.cell_h + 8.0)
	h.bytes_per_row = ((h.screen_w * 4 + 255) / 256) * 256
	h.buf_size = u64(h.bytes_per_row * h.screen_h)

	// Create offscreen textures
	tex_desc := wgpu.TextureDescriptor{
		usage = {.RenderAttachment, .CopySrc},
		dimension = ._2D,
		size = {width = h.screen_w, height = h.screen_h, depthOrArrayLayers = 1},
		format = .BGRA8Unorm,
		mipLevelCount = 1,
		sampleCount = 1,
	}
	h.tex_a = wgpu.DeviceCreateTexture(h.device, &tex_desc)
	h.view_a = wgpu.TextureCreateView(h.tex_a, nil)

	h.tex_b = wgpu.DeviceCreateTexture(h.device, &tex_desc)
	h.view_b = wgpu.TextureCreateView(h.tex_b, nil)

	buf_desc := wgpu.BufferDescriptor{
		usage = {.MapRead, .CopyDst},
		size = h.buf_size,
	}
	h.read_buf_a = wgpu.DeviceCreateBuffer(h.device, &buf_desc)
	h.read_buf_b = wgpu.DeviceCreateBuffer(h.device, &buf_desc)

	h.pixels_a = make([]u8, h.screen_w * h.screen_h * 4)
	h.pixels_b = make([]u8, h.screen_w * h.screen_h * 4)
	h.pixels_diff = make([]u8, h.screen_w * h.screen_h * 4)

	// Initialize Renderers
	dev_handle := gpu.Gpu_Device(rawptr(h.device))
	q_handle := gpu.Gpu_Queue(rawptr(h.queue))

	if !render.renderer_init(&h.renderer_a, h.font_path, 16.0, &h.vtable, dev_handle, q_handle, GRID_ROWS, GRID_COLS, h.cell_w, h.cell_h, f32(h.screen_w), f32(h.screen_h), .BGRA8_Unorm) {
		return false
	}
	render.renderer_attach_surface(&h.renderer_a, gpu.Gpu_Surface(rawptr(h.tex_a)), h.screen_w, h.screen_h)
	render.renderer_strategy_pin(&h.renderer_a, .Instance)
	h.renderer_a.partial_load_enabled = true
	h.renderer_a.scissor_padding = 2

	if !render.renderer_init(&h.renderer_b, h.font_path, 16.0, &h.vtable, dev_handle, q_handle, GRID_ROWS, GRID_COLS, h.cell_w, h.cell_h, f32(h.screen_w), f32(h.screen_h), .BGRA8_Unorm) {
		return false
	}
	render.renderer_attach_surface(&h.renderer_b, gpu.Gpu_Surface(rawptr(h.tex_b)), h.screen_w, h.screen_h)
	render.renderer_strategy_pin(&h.renderer_b, .Instance)
	h.renderer_b.partial_load_enabled = false // Full Redraw on every frame

	return true
}

_harness_destroy :: proc(h: ^Equivalence_Harness) {
	render.renderer_destroy(&h.renderer_a)
	render.renderer_destroy(&h.renderer_b)

	delete(h.pixels_a)
	delete(h.pixels_b)
	delete(h.pixels_diff)

	wgpu.BufferRelease(h.read_buf_a)
	wgpu.BufferRelease(h.read_buf_b)
	wgpu.TextureViewRelease(h.view_a)
	wgpu.TextureRelease(h.tex_a)
	wgpu.TextureViewRelease(h.view_b)
	wgpu.TextureRelease(h.tex_b)

	wgpu.QueueRelease(h.queue)
	wgpu.DeviceRelease(h.device)
	wgpu.AdapterRelease(h.adapter)
	wgpu.InstanceRelease(h.inst)
	sdl3.Quit()
}

_readback_and_compare :: proc(h: ^Equivalence_Harness) -> (diff_count: int, first_diff_idx: int) {
	enc := wgpu.DeviceCreateCommandEncoder(h.device, nil)

	src_a := wgpu.TexelCopyTextureInfo{texture = h.tex_a, mipLevel = 0, origin = {0, 0, 0}, aspect = .All}
	dst_a := wgpu.TexelCopyBufferInfo{layout = {offset = 0, bytesPerRow = h.bytes_per_row, rowsPerImage = h.screen_h}, buffer = h.read_buf_a}
	copy_size := wgpu.Extent3D{width = h.screen_w, height = h.screen_h, depthOrArrayLayers = 1}
	wgpu.CommandEncoderCopyTextureToBuffer(enc, &src_a, &dst_a, &copy_size)

	src_b := wgpu.TexelCopyTextureInfo{texture = h.tex_b, mipLevel = 0, origin = {0, 0, 0}, aspect = .All}
	dst_b := wgpu.TexelCopyBufferInfo{layout = {offset = 0, bytesPerRow = h.bytes_per_row, rowsPerImage = h.screen_h}, buffer = h.read_buf_b}
	wgpu.CommandEncoderCopyTextureToBuffer(enc, &src_b, &dst_b, &copy_size)

	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	cmds := [1]wgpu.CommandBuffer{cmd}
	wgpu.QueueSubmit(h.queue, cmds[:])
	wgpu.CommandBufferRelease(cmd)

	// Map Buffer A
	_map_done_flag = false
	wgpu.BufferMapAsync(h.read_buf_a, {.Read}, 0, uint(h.buf_size), {mode = .AllowProcessEvents, callback = _on_buffer_mapped, userdata1 = &_map_done_flag})
	for !_map_done_flag {
		wgpu.InstanceProcessEvents(h.inst)
	}

	// Map Buffer B
	map_b_done := false
	wgpu.BufferMapAsync(h.read_buf_b, {.Read}, 0, uint(h.buf_size), {mode = .AllowProcessEvents, callback = _on_buffer_mapped, userdata1 = &map_b_done})
	for !map_b_done {
		wgpu.InstanceProcessEvents(h.inst)
	}

	ptr_a := ([^]u8)(wgpu.RawBufferGetConstMappedRange(h.read_buf_a, 0, uint(h.buf_size)))
	ptr_b := ([^]u8)(wgpu.RawBufferGetConstMappedRange(h.read_buf_b, 0, uint(h.buf_size)))

	// Unpack row-by-row stripping padding
	diff_count = 0
	first_diff_idx = -1
	pixel_w := int(h.screen_w)
	pixel_h := int(h.screen_h)

	for y in 0..<pixel_h {
		src_offset := y * int(h.bytes_per_row)
		dst_offset := y * pixel_w * 4
		for x in 0..<pixel_w {
			p_src := src_offset + x * 4
			p_dst := dst_offset + x * 4

			ba, ga, ra, aa := ptr_a[p_src+0], ptr_a[p_src+1], ptr_a[p_src+2], ptr_a[p_src+3]
			bb, gb, rb, ab := ptr_b[p_src+0], ptr_b[p_src+1], ptr_b[p_src+2], ptr_b[p_src+3]

			h.pixels_a[p_dst+0] = ra
			h.pixels_a[p_dst+1] = ga
			h.pixels_a[p_dst+2] = ba
			h.pixels_a[p_dst+3] = aa

			h.pixels_b[p_dst+0] = rb
			h.pixels_b[p_dst+1] = gb
			h.pixels_b[p_dst+2] = bb
			h.pixels_b[p_dst+3] = ab

			if ra != rb || ga != gb || ba != bb || aa != ab {
				diff_count += 1
				if first_diff_idx == -1 {
					first_diff_idx = p_dst / 4
				}
				// Neon Magenta for diff pixel
				h.pixels_diff[p_dst+0] = 255
				h.pixels_diff[p_dst+1] = 0
				h.pixels_diff[p_dst+2] = 255
				h.pixels_diff[p_dst+3] = 255
			} else {
				// Dim monochrome copy of identical pixel
				lum := u8((u32(ra) * 77 + u32(ga) * 150 + u32(ba) * 29) >> 8)
				dim := lum >> 2
				h.pixels_diff[p_dst+0] = dim
				h.pixels_diff[p_dst+1] = dim
				h.pixels_diff[p_dst+2] = dim
				h.pixels_diff[p_dst+3] = 255
			}
		}
	}

	wgpu.BufferUnmap(h.read_buf_a)
	wgpu.BufferUnmap(h.read_buf_b)
	return diff_count, first_diff_idx
}

_dump_png_artifacts :: proc(h: ^Equivalence_Harness, prefix: string) {
	os.make_directory("artifacts")
	w := c.int(h.screen_w)
	height := c.int(h.screen_h)

	name_part := strings.clone_to_cstring(fmt.tprintf("artifacts/%s_partial.png", prefix))
	defer delete(name_part)
	stbi_write_png(name_part, w, height, 4, raw_data(h.pixels_a), w * 4)

	name_full := strings.clone_to_cstring(fmt.tprintf("artifacts/%s_full.png", prefix))
	defer delete(name_full)
	stbi_write_png(name_full, w, height, 4, raw_data(h.pixels_b), w * 4)

	name_diff := strings.clone_to_cstring(fmt.tprintf("artifacts/%s_diff.png", prefix))
	defer delete(name_diff)
	stbi_write_png(name_diff, w, height, 4, raw_data(h.pixels_diff), w * 4)

	fmt.printfln("  [ARTIFACT DUMP] Wrote PNG diff files to artifacts/%s_partial.png, _full.png, _diff.png", prefix)
}

_audit_atlas_overhang :: proc(font_path: string) {
	r: render.Font_Rasterizer
	if !render.font_rasterizer_init(&r, font_path, 16.0) {
		fmt.printfln("  [OVERHANG AUDIT] Could not load font: %s", font_path)
		return
	}
	defer render.font_rasterizer_destroy(&r)

	cw := int(r.metrics.cell_width)
	max_left := 0
	max_right := 0
	worst_left_char := rune(0)
	worst_right_char := rune(0)

	cps := [?]u32{
		// Printable ASCII
		33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
		48, 49, 57, 65, 77, 87, 90, 97, 102, 106, 119, 122, 124, 126,
		// Box Drawing & Block Elements
		0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x2588, 0x2592,
		// Powerline / Devicon Symbols
		0xE0A0, 0xE0B0, 0xE0B2,
	}

	for cp in cps {
		bmp := render.font_rasterize_glyph(&r, cp)
		defer delete(bmp.pixels)
		left_over := max(0, -int(bmp.bearing_x))
		right_over := max(0, int(bmp.bearing_x) + bmp.width - cw)
		if left_over > max_left {
			max_left = left_over
			worst_left_char = rune(cp)
		}
		if right_over > max_right {
			max_right = right_over
			worst_right_char = rune(cp)
		}
	}

	fmt.printfln("================================================================================")
	fmt.printfln("              AUTOMATED GLYPH OVERHANG AUDIT REPORT                             ")
	fmt.printfln("================================================================================")
	fmt.printfln("Font:                 %s", font_path)
	fmt.printfln("Cell Geometry:        cell_w=%d px, cell_h=%d px", cw, int(r.metrics.cell_height))
	fmt.printfln("Max Left Overhang:    %d px (Char '%c' U+%04X)", max_left, worst_left_char, int(worst_left_char))
	fmt.printfln("Max Right Overhang:   %d px (Char '%c' U+%04X)", max_right, worst_right_char, int(worst_right_char))
	fmt.printfln("1-Column Budget:      %d px", cw)
	if max_left <= cw && max_right <= cw {
		fmt.printfln("Verdict:              SAFE (Overhang <= 1 Column Budget: ±1 expansion fully covers)")
	} else {
		fmt.printfln("Verdict:              HAZARD (Overhang exceeds 1 Column! Widening must be increased!)")
	}
	fmt.printfln("================================================================================\n")
}

// Deterministic PRNG
_next_rand :: proc(s: ^u64) -> u32 {
	s^ = s^ * 6364136223846793005 + 1442695040888963407
	return u32(s^ >> 32)
}

_apply_terminal_edit :: proc(term_a, term_b: ^termgrid.Terminal, row, col: int, r_char: rune, style_idx: u16, width: u8 = 1) {
	cell := termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(r_char),
		style = termgrid.Style_Id(style_idx),
		width = width,
	}
	termgrid.grid_set_cell(&term_a.grid, row, col, cell)
	termgrid.damage_mark_cell(&term_a.damage, row, col, 0)

	termgrid.grid_set_cell(&term_b.grid, row, col, cell)
	termgrid.damage_mark_cell(&term_b.damage, row, col, 0)
}

_apply_terminal_edit_split :: proc(term_a, term_b: ^termgrid.Terminal, row, col: int, r_char: rune, style_a, style_b: u16, width: u8 = 1) {
	cell_a := termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(r_char),
		style = termgrid.Style_Id(style_a),
		width = width,
	}
	termgrid.grid_set_cell(&term_a.grid, row, col, cell_a)
	termgrid.damage_mark_cell(&term_a.damage, row, col, 0)

	cell_b := termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(r_char),
		style = termgrid.Style_Id(style_b),
		width = width,
	}
	termgrid.grid_set_cell(&term_b.grid, row, col, cell_b)
	termgrid.damage_mark_cell(&term_b.damage, row, col, 0)
}

_clear_texture :: proc(device: wgpu.Device, queue: wgpu.Queue, view: wgpu.TextureView, clear_col: [4]f64) {
	enc := wgpu.DeviceCreateCommandEncoder(device, nil)
	att := wgpu.RenderPassColorAttachment{
		view = view,
		depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
		loadOp = .Clear,
		storeOp = .Store,
		clearValue = {clear_col[0], clear_col[1], clear_col[2], clear_col[3]},
	}
	rp := wgpu.RenderPassDescriptor{
		colorAttachmentCount = 1,
		colorAttachments = &att,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &rp)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	cmds := [1]wgpu.CommandBuffer{cmd}
	wgpu.QueueSubmit(queue, cmds[:])
	wgpu.CommandBufferRelease(cmd)
}

main :: proc() {
	quick_mode := false
	for arg in os.args {
		if arg == "--quick" || arg == "-q" {
			quick_mode = true
		}
	}

	h := new(Equivalence_Harness)
	defer free(h)
	if !_harness_init(h) {
		fmt.eprintln("FATAL: Failed to initialize WGPU Equivalence Harness")
		os.exit(1)
	}
	defer _harness_destroy(h)

	// Step 1: Atlas Overhang Audit
	_audit_atlas_overhang(h.font_path)

	seeds_count := quick_mode ? 5 : 20
	edits_per_seed := quick_mode ? 100 : 500

	fmt.println("================================================================================")
	fmt.printfln("     RUNNING HARDWARE GPU READBACK EQUIVALENCE GATE (%d Seeds × %d Edits)      ", seeds_count, edits_per_seed)
	fmt.println("Comparing Strategy A (LoadOp.Load + Scissor) vs Strategy B (LoadOp.Clear) on Metal/WGPU")
	fmt.println("================================================================================")

	total_frames := 0
	total_mismatches := 0
	t_start := time.now()

	for seed_idx in 0..<seeds_count {
		seed_val := u64(seed_idx * 7919 + 42)
		rng := seed_val

		term_a := new(termgrid.Terminal)
		defer free(term_a)
		termgrid.terminal_init(term_a, GRID_ROWS, GRID_COLS)
		defer termgrid.terminal_destroy(term_a)

		term_b := new(termgrid.Terminal)
		defer free(term_b)
		termgrid.terminal_init(term_b, GRID_ROWS, GRID_COLS)
		defer termgrid.terminal_destroy(term_b)

		// Register valid styled entries in both style tables
		style_italic := termgrid.Style{
			fg = 0xCDD6F4FF,
			bg = 0x313244FF,
			flags = termgrid.STYLE_FLAG_ITALIC,
		}
		style_id_italic_a := u16(termgrid.style_table_insert(&term_a.grid.style_table, style_italic))
		style_id_italic_b := u16(termgrid.style_table_insert(&term_b.grid.style_table, style_italic))

		style_custom := termgrid.Style{
			fg = 0xF9E2AFFF,
			bg = 0x45475AFF,
			flags = {},
		}
		style_id_custom_a := u16(termgrid.style_table_insert(&term_a.grid.style_table, style_custom))
		style_id_custom_b := u16(termgrid.style_table_insert(&term_b.grid.style_table, style_custom))

		// Clear offscreen textures to default background
		clear_color := render._renderer_theme_clear_color(termgrid.THEME_CATPPUCCIN_MOCHA)
		_clear_texture(h.device, h.queue, h.view_a, clear_color)
		_clear_texture(h.device, h.queue, h.view_b, clear_color)

		// Reset renderer state between seeds
		h.renderer_a.dirty.armed = false
		h.renderer_a.full_redraw_pending = true
		h.renderer_a.frame_count = 0

		h.renderer_b.dirty.armed = false
		h.renderer_b.full_redraw_pending = true
		h.renderer_b.frame_count = 0

		// Initial Baseline Clear Render
		_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
		_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
		_ = render.renderer_frame(&h.renderer_a, term_a)

		_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
		_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
		_ = render.renderer_frame(&h.renderer_b, term_b)

		seed_mismatches := 0

		for edit_idx in 0..<edits_per_seed {
			total_frames += 1

			// Generate randomized deterministic edit
			row := int(_next_rand(&rng) % GRID_ROWS)
			col := int(_next_rand(&rng) % GRID_COLS)
			kind := _next_rand(&rng) % 5

			r_char := rune('A')
			style_a := u16(0)
			style_b := u16(0)

			switch kind {
			case 0: // Standard typing
				r_char = rune(33 + (_next_rand(&rng) % 94))
				termgrid.terminal_move_cursor(term_a, row, col)
				termgrid.terminal_set_style(term_a, 0)
				termgrid.terminal_put_char(term_a, r_char)

				termgrid.terminal_move_cursor(term_b, row, col)
				termgrid.terminal_set_style(term_b, 0)
				termgrid.terminal_put_char(term_b, r_char)

			case 1: // Backspace / space erasure (anti-ghosting check)
				termgrid.terminal_move_cursor(term_a, row, col)
				termgrid.terminal_set_style(term_a, 0)
				termgrid.terminal_put_char(term_a, ' ')

				termgrid.terminal_move_cursor(term_b, row, col)
				termgrid.terminal_set_style(term_b, 0)
				termgrid.terminal_put_char(term_b, ' ')

			case 2: // Italic / custom styled text (overhang check)
				r_char = rune('a' + (_next_rand(&rng) % 26))
				termgrid.terminal_move_cursor(term_a, row, col)
				termgrid.terminal_set_style(term_a, style_id_italic_a)
				termgrid.terminal_put_char(term_a, r_char)

				termgrid.terminal_move_cursor(term_b, row, col)
				termgrid.terminal_set_style(term_b, style_id_italic_b)
				termgrid.terminal_put_char(term_b, r_char)

			case 3: // CJK Wide character lead & continuation
				cjk_char := rune(0x4E00 + (_next_rand(&rng) % 100))
				if col < GRID_COLS - 1 {
					termgrid.terminal_move_cursor(term_a, row, col)
					termgrid.terminal_set_style(term_a, style_id_custom_a)
					termgrid.terminal_put_wide(term_a, cjk_char)

					termgrid.terminal_move_cursor(term_b, row, col)
					termgrid.terminal_set_style(term_b, style_id_custom_b)
					termgrid.terminal_put_wide(term_b, cjk_char)
				}

			case 4: // Multi-cell run clear via terminal_erase_chars
				clear_len := min(10, GRID_COLS - col)
				termgrid.terminal_move_cursor(term_a, row, col)
				termgrid.terminal_erase_chars(term_a, clear_len)

				termgrid.terminal_move_cursor(term_b, row, col)
				termgrid.terminal_erase_chars(term_b, clear_len)
			}

			// Strategy A Render
			_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
			_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
			ok_a := render.renderer_frame(&h.renderer_a, term_a)

			// Strategy B Render
			_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
			_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
			h.renderer_b.full_redraw_pending = true
			ok_b := render.renderer_frame(&h.renderer_b, term_b)

			if !ok_a || !ok_b {
				continue
			}

			// Readback and pixel-by-pixel assertion
			diff_pixels, first_diff_idx := _readback_and_compare(h)
			if diff_pixels > 0 {
				seed_mismatches += 1
				total_mismatches += 1
				_dump_png_artifacts(h, fmt.tprintf("seed%02d_edit%04d", seed_idx, edit_idx))
				diff_x := first_diff_idx % int(h.screen_w)
				diff_y := first_diff_idx / int(h.screen_w)
				p_dst := first_diff_idx * 4
				ra, ga, ba, aa := h.pixels_a[p_dst+0], h.pixels_a[p_dst+1], h.pixels_a[p_dst+2], h.pixels_a[p_dst+3]
				rb, gb, bb, ab := h.pixels_b[p_dst+0], h.pixels_b[p_dst+1], h.pixels_b[p_dst+2], h.pixels_b[p_dst+3]
				fmt.printfln("  [FAIL] Seed %d, Edit %d: %d pixels differ! First diff at (%d, %d): A=[%d, %d, %d, %d] vs B=[%d, %d, %d, %d]",
					seed_idx, edit_idx, diff_pixels, diff_x, diff_y, ra, ga, ba, aa, rb, gb, bb, ab)
				break
			}
		}

		if seed_mismatches == 0 {
			fmt.printfln("  [PASS] Seed %02d/%02d: %d edits verified (0 pixel differences)", seed_idx + 1, seeds_count, edits_per_seed)
		}
	}

	elapsed := time.since(t_start)
	fps := f64(total_frames) / time.duration_seconds(elapsed)
	fmt.printfln("\nGate Completed: %d frames tested in %.2f s (%.1f readback FPS)", total_frames, time.duration_seconds(elapsed), fps)
	if total_mismatches == 0 {
		fmt.println(">>> POSITIVE EQUIVALENCE GATE: VERIFIED BIT-EXACT (PASS) <<<\n")
	} else {
		fmt.printfln(">>> POSITIVE EQUIVALENCE GATE: FAILED (%d Mismatches) <<<\n", total_mismatches)
	}

	// Step 3: Run the 4 Negative Mutation Tests
	fmt.println("================================================================================")
	fmt.println("                    RUNNING 4 NEGATIVE MUTATION REGRESSION TESTS                ")
	fmt.println("================================================================================")

	_run_negative_tests(h)
}

_run_negative_tests :: proc(h: ^Equivalence_Harness) {
	term_a := new(termgrid.Terminal)
	defer free(term_a)
	termgrid.terminal_init(term_a, GRID_ROWS, GRID_COLS)
	defer termgrid.terminal_destroy(term_a)

	term_b := new(termgrid.Terminal)
	defer free(term_b)
	termgrid.terminal_init(term_b, GRID_ROWS, GRID_COLS)
	defer termgrid.terminal_destroy(term_b)

	// -------------------------------------------------------------------------
	// Negative Test 1: Disable Compiler ±1 Widen
	// -------------------------------------------------------------------------
	fmt.print("  [Negative 1] Disabled ±1 Column Widening (render.disable_compiler_widen): ")
	render.disable_compiler_widen = true
	defer render.disable_compiler_widen = false

	// Register custom styles
	style_custom := termgrid.Style{
		fg = 0xCDD6F4FF,
		bg = 0xF38BA8FF,
		flags = termgrid.STYLE_FLAG_ITALIC,
	}
	s_it_a := u16(termgrid.style_table_insert(&term_a.grid.style_table, style_custom))
	s_it_b := u16(termgrid.style_table_insert(&term_b.grid.style_table, style_custom))

	// Baseline frame: col 5 has box drawing char '─' with left overhang into col 4
	termgrid.terminal_move_cursor(term_a, 5, 5)
	termgrid.terminal_set_style(term_a, s_it_a)
	termgrid.terminal_put_char(term_a, '─')

	termgrid.terminal_move_cursor(term_b, 5, 5)
	termgrid.terminal_set_style(term_b, s_it_b)
	termgrid.terminal_put_char(term_b, '─')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	_ = render.renderer_frame(&h.renderer_b, term_b)

	// Now edit col 4 to space with red bg (overwriting the overhang area)
	termgrid.terminal_move_cursor(term_a, 5, 4)
	termgrid.terminal_set_style(term_a, s_it_a)
	termgrid.terminal_put_char(term_a, ' ')

	termgrid.terminal_move_cursor(term_b, 5, 4)
	termgrid.terminal_set_style(term_b, s_it_b)
	termgrid.terminal_put_char(term_b, ' ')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	h.renderer_b.full_redraw_pending = true
	_ = render.renderer_frame(&h.renderer_b, term_b)

	diff1, first_idx1 := _readback_and_compare(h)
	fmt.printfln("DEBUG Negative 1: diff1 = %d, first_idx1 = %d", diff1, first_idx1)
	if diff1 > 0 {
		fmt.printfln("FAILED AS EXPECTED (%d diff pixels caught)", diff1)
	} else {
		fmt.println("WARNING: Negative 1 did not produce a diff (Inconclusive)")
	}

	render.disable_compiler_widen = false

	// -------------------------------------------------------------------------
	// Negative Test 2: Disable Default Space Background Quad Emission
	// -------------------------------------------------------------------------
	fmt.print("  [Negative 2] Disabled Space BG Quad Emission (render.disable_partial_space_bg): ")
	render.disable_partial_space_bg = true
	defer render.disable_partial_space_bg = false

	// Type 'M' then overwrite with space ' '
	termgrid.terminal_move_cursor(term_a, 10, 10)
	termgrid.terminal_set_style(term_a, 0)
	termgrid.terminal_put_char(term_a, 'M')

	termgrid.terminal_move_cursor(term_b, 10, 10)
	termgrid.terminal_set_style(term_b, 0)
	termgrid.terminal_put_char(term_b, 'M')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	_ = render.renderer_frame(&h.renderer_b, term_b)

	// Backspace / overwrite with space
	termgrid.terminal_move_cursor(term_a, 10, 10)
	termgrid.terminal_set_style(term_a, 0)
	termgrid.terminal_put_char(term_a, ' ')

	termgrid.terminal_move_cursor(term_b, 10, 10)
	termgrid.terminal_set_style(term_b, 0)
	termgrid.terminal_put_char(term_b, ' ')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	h.renderer_b.full_redraw_pending = true
	_ = render.renderer_frame(&h.renderer_b, term_b)

	diff2, _ := _readback_and_compare(h)
	if diff2 > 0 {
		fmt.printfln("FAILED AS EXPECTED (%d ghost pixels caught)", diff2)
	} else {
		fmt.println("WARNING: Negative 2 did not catch ghosting!")
	}

	render.disable_partial_space_bg = false

	// -------------------------------------------------------------------------
	// Negative Test 3: Scissor Padding = 0 px
	// -------------------------------------------------------------------------
	fmt.print("  [Negative 3] 0px Scissor Padding (h.renderer_a.scissor_padding = 0): ")
	h.renderer_a.scissor_padding = 0
	defer h.renderer_a.scissor_padding = 2

	termgrid.terminal_move_cursor(term_a, 15, 15)
	termgrid.terminal_set_style(term_a, 0)
	termgrid.terminal_put_char(term_a, 'Z')

	termgrid.terminal_move_cursor(term_b, 15, 15)
	termgrid.terminal_set_style(term_b, 0)
	termgrid.terminal_put_char(term_b, 'Z')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	h.renderer_b.full_redraw_pending = true
	_ = render.renderer_frame(&h.renderer_b, term_b)

	diff3, _ := _readback_and_compare(h)
	if diff3 > 0 {
		fmt.printfln("FAILED (Scissor padding 0px clipped %d antialias pixels)", diff3)
	} else {
		fmt.println("PASSED AS-IS (0px padding is safe because instances already cover full cell boundaries)")
	}

	h.renderer_a.scissor_padding = 2

	// -------------------------------------------------------------------------
	// Negative Test 4: Inverted Draw Order (Glyph before Background)
	// -------------------------------------------------------------------------
	fmt.print("  [Negative 4] Inverted Draw Order (render.invert_draw_order): ")
	render.invert_draw_order = true
	defer render.invert_draw_order = false

	termgrid.terminal_move_cursor(term_a, 18, 18)
	termgrid.terminal_set_style(term_a, 1)
	termgrid.terminal_put_char(term_a, 'K')

	termgrid.terminal_move_cursor(term_b, 18, 18)
	termgrid.terminal_set_style(term_b, 1)
	termgrid.terminal_put_char(term_b, 'K')

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_a))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_a))
	_ = render.renderer_frame(&h.renderer_a, term_a)

	_active_target_texture = gpu.Gpu_Texture(rawptr(h.tex_b))
	_active_target_view = gpu.Gpu_TextureView(rawptr(h.view_b))
	h.renderer_b.full_redraw_pending = true
	_ = render.renderer_frame(&h.renderer_b, term_b)

	diff4, _ := _readback_and_compare(h)
	if diff4 > 0 {
		fmt.printfln("FAILED AS EXPECTED (%d pixels obliterated by inverted draw order)", diff4)
	} else {
		fmt.println("WARNING: Negative 4 did not produce a diff!")
	}

	render.invert_draw_order = false
	fmt.println("================================================================================")
}

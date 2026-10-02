package app_test

// Requirement-derived transaction tests. The trace backend uses opaque
// handles and records only publication boundaries, so these tests exercise
// the production lifecycle without a GPU or window system.

import "core:testing"
import "core:sync"
import app "../"
import render "../../render"
import gpu "../../render/gpu"
import instance "../../render/instance"
import termgrid "../../terminal"
import platform_tabs "../../platform/tabs"
import platform "../../platform"

FRAME_PANE_GPU_TRACE_ROWS :: 4
FRAME_PANE_GPU_TRACE_COLS :: 8
FRAME_PANE_GPU_TRACE_UPLOAD_BYTES :: instance.INSTANCE_STRIDE * 4

Pane_GPU_Trace_Event :: enum {
	Acquire,
	Encode,
	Submit,
	Present,
	Release,
}

Pane_GPU_Trace_State :: struct {
	events:      [32]Pane_GPU_Trace_Event,
	count:       int,
	submit_count: int,
	present_count: int,
	release_count: int,
	write_count: int,
	unlock_count: int,
	unlock_after_publication: bool,
	acquire_ok:  bool,
	encoder_ok:  bool,
	submit_ok:   bool,
	present_ok:  bool,
}

_pane_gpu_trace: Pane_GPU_Trace_State
_pane_gpu_trace_mutex: sync.Mutex
_PANE_GPU_TRACE_DEVICE := rawptr(uintptr(0x1001))
_PANE_GPU_TRACE_QUEUE := rawptr(uintptr(0x1002))
_PANE_GPU_TRACE_SURFACE := rawptr(uintptr(0x1003))
_PANE_GPU_TRACE_TEXTURE := rawptr(uintptr(0x1004))
_PANE_GPU_TRACE_VIEW := rawptr(uintptr(0x1005))
_PANE_GPU_TRACE_ENCODER := rawptr(uintptr(0x1006))
_PANE_GPU_TRACE_PASS := rawptr(uintptr(0x1007))
_PANE_GPU_TRACE_COMMAND := rawptr(uintptr(0x1008))
_PANE_GPU_TRACE_BUFFER := rawptr(uintptr(0x1009))
_PANE_GPU_TRACE_PIPELINE := rawptr(uintptr(0x100a))
_PANE_GPU_TRACE_BIND_GROUP := rawptr(uintptr(0x100b))

_pane_gpu_trace_reset :: proc() {
	_pane_gpu_trace = Pane_GPU_Trace_State{
		acquire_ok = true,
		encoder_ok = true,
		submit_ok = true,
		present_ok = true,
	}
}

_pane_gpu_trace_record :: proc(event: Pane_GPU_Trace_Event) {
	if _pane_gpu_trace.count < len(_pane_gpu_trace.events) {
		_pane_gpu_trace.events[_pane_gpu_trace.count] = event
		_pane_gpu_trace.count += 1
	}
}

_pane_gpu_trace_backend: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	get_surface_texture = _pane_gpu_trace_get_surface_texture,
	present_surface = _pane_gpu_trace_present_surface,
	create_buffer = _pane_gpu_trace_create_buffer,
	destroy_buffer = _pane_gpu_trace_destroy_buffer,
	write_buffer = _pane_gpu_trace_write_buffer,
	create_command_encoder = _pane_gpu_trace_create_command_encoder,
	release_command_encoder = _pane_gpu_trace_release_command_encoder,
	begin_render_pass = _pane_gpu_trace_begin_render_pass,
	end_render_pass = _pane_gpu_trace_end_render_pass,
	finish_command_buffer = _pane_gpu_trace_finish_command_buffer,
	release_command_buffer = _pane_gpu_trace_release_command_buffer,
	submit = _pane_gpu_trace_submit,
	wait_for_idle = _pane_gpu_trace_wait_for_idle,
	render_set_pipeline = _pane_gpu_trace_render_set_pipeline,
	render_set_bind_group = _pane_gpu_trace_render_set_bind_group,
	render_set_vertex_buffer = _pane_gpu_trace_render_set_vertex_buffer,
	render_draw = _pane_gpu_trace_render_draw,
	release_surface_texture = _pane_gpu_trace_release_surface_texture,
	}

_pane_gpu_trace_get_surface_texture :: proc(surface: rawptr) -> (texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView, format: gpu.Gpu_Format) {
	_pane_gpu_trace_record(.Acquire)
	if !_pane_gpu_trace.acquire_ok {
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), .BGRA8_Unorm
	}
	return gpu.Gpu_Texture(_PANE_GPU_TRACE_TEXTURE), gpu.Gpu_TextureView(_PANE_GPU_TRACE_VIEW), .BGRA8_Unorm
}

_pane_gpu_trace_present_surface :: proc(surface: rawptr) -> bool {
	_pane_gpu_trace_record(.Present)
	_pane_gpu_trace.present_count += 1
	return _pane_gpu_trace.present_ok
}

_pane_gpu_trace_create_buffer :: proc(device: gpu.Gpu_Device, size: u64, usage: gpu.Gpu_Buffer_Usage, mapped_at_creation: bool) -> gpu.Gpu_Buffer {
	return gpu.Gpu_Buffer(_PANE_GPU_TRACE_BUFFER)
}

_pane_gpu_trace_destroy_buffer :: proc(buffer: gpu.Gpu_Buffer) {}

_pane_gpu_trace_write_buffer :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	_pane_gpu_trace.write_count += 1
}

_pane_gpu_trace_create_command_encoder :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_CommandEncoder {
	if !_pane_gpu_trace.encoder_ok {
		return gpu.Gpu_CommandEncoder(nil)
	}
	_pane_gpu_trace_record(.Encode)
	return gpu.Gpu_CommandEncoder(_PANE_GPU_TRACE_ENCODER)
}

_pane_gpu_trace_release_command_encoder :: proc(encoder: gpu.Gpu_CommandEncoder) {}

_pane_gpu_trace_begin_render_pass :: proc(encoder: gpu.Gpu_CommandEncoder, color_view: gpu.Gpu_TextureView, clear_color: [4]f64, load_op: gpu.Gpu_Load_Op) -> gpu.Gpu_RenderPassEncoder {
	return gpu.Gpu_RenderPassEncoder(_PANE_GPU_TRACE_PASS)
}

_pane_gpu_trace_end_render_pass :: proc(pass: gpu.Gpu_RenderPassEncoder) {}

_pane_gpu_trace_finish_command_buffer :: proc(encoder: gpu.Gpu_CommandEncoder) -> rawptr {
	return _PANE_GPU_TRACE_COMMAND
}

_pane_gpu_trace_release_command_buffer :: proc(command_buffer: rawptr) {}

_pane_gpu_trace_wait_for_idle :: proc(device: gpu.Gpu_Device) -> bool {
	return true
}

_pane_gpu_trace_submit :: proc(queue: gpu.Gpu_Queue, command_buffer: rawptr) -> bool {
	_pane_gpu_trace_record(.Submit)
	_pane_gpu_trace.submit_count += 1
	return _pane_gpu_trace.submit_ok
}

_pane_gpu_trace_render_set_pipeline :: proc(pass: gpu.Gpu_RenderPassEncoder, pipeline: gpu.Gpu_RenderPipeline) {}
_pane_gpu_trace_render_set_bind_group :: proc(pass: gpu.Gpu_RenderPassEncoder, index: u32, group: gpu.Gpu_BindGroup) {}
_pane_gpu_trace_render_set_vertex_buffer :: proc(pass: gpu.Gpu_RenderPassEncoder, slot: u32, buffer: gpu.Gpu_Buffer, offset: u64) {}
_pane_gpu_trace_render_draw :: proc(pass: gpu.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {}

_pane_gpu_trace_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	_pane_gpu_trace_record(.Release)
	_pane_gpu_trace.release_count += 1
}

_pane_gpu_trace_renderer :: proc(r: ^render.Renderer) {
	r.rows = FRAME_PANE_GPU_TRACE_ROWS
	r.cols = FRAME_PANE_GPU_TRACE_COLS
	r.cell_width = 8
	r.cell_height = 16
	r.pad_x = 6
	r.pad_y = 4
	r.format = .BGRA8_Unorm
	r.device = gpu.Gpu_Device(_PANE_GPU_TRACE_DEVICE)
	r.queue = gpu.Gpu_Queue(_PANE_GPU_TRACE_QUEUE)
	r.surface = gpu.Gpu_Surface(_PANE_GPU_TRACE_SURFACE)
	r.backend = &_pane_gpu_trace_backend
	r.surface_w = 0
	r.surface_h = 0
	r.frame_prepared = true
	r.first_frame_pending = true
	r.full_redraw_pending = false
	r.instances.max_instances = 8
	r.instances.instance_data = make([]instance.Instance_Data, 8)
	r.instances.bg_pipeline = gpu.Gpu_RenderPipeline(_PANE_GPU_TRACE_PIPELINE)
	r.instances.glyph_pipeline = gpu.Gpu_RenderPipeline(_PANE_GPU_TRACE_PIPELINE)
	r.instances.bind_group_bg = gpu.Gpu_BindGroup(_PANE_GPU_TRACE_BIND_GROUP)
	r.instances.bind_group_glyph = gpu.Gpu_BindGroup(_PANE_GPU_TRACE_BIND_GROUP)
	r.fullscreen.backend = &_pane_gpu_trace_backend
	r.fullscreen.device = r.device
	r.fullscreen.queue = r.queue
	r.fullscreen.rows = FRAME_PANE_GPU_TRACE_ROWS
	r.fullscreen.cols = FRAME_PANE_GPU_TRACE_COLS
	r.fullscreen.cell_w = 8
	r.fullscreen.cell_h = 16
	r.fullscreen.available = true
	r.fullscreen.pipeline = gpu.Gpu_RenderPipeline(_PANE_GPU_TRACE_PIPELINE)
	r.fullscreen.bind_group = gpu.Gpu_BindGroup(_PANE_GPU_TRACE_BIND_GROUP)
	render.render_compiler_init_v2(&r.compiled_v2, FRAME_PANE_GPU_TRACE_ROWS, FRAME_PANE_GPU_TRACE_COLS)
	render.upload_ring_init(&r.upload_ring, &_pane_gpu_trace_backend, r.device, r.queue, FRAME_PANE_GPU_TRACE_UPLOAD_BYTES)
}

_pane_gpu_trace_renderer_destroy :: proc(r: ^render.Renderer) {
	render.render_compiler_destroy_v2(&r.compiled_v2)
	render.upload_ring_destroy(&r.upload_ring)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
}

_pane_gpu_trace_mark_damage :: proc(term: ^termgrid.Terminal) {
	termgrid.damage_mark_span(&term.damage, 1, 2, 4, 7)
	termgrid.damage_mark_row(&term.damage, 2, 9)
	termgrid.damage_record_scroll(&term.damage, 0, FRAME_PANE_GPU_TRACE_ROWS - 1, 1)
}

@(test)
test_app_pane_present_reaches_gpu_and_releases_borrowed_snapshots :: proc(t: ^testing.T) {
	_pane_gpu_trace_reset()
	a := new(app.App)
	defer free(a)
	app.session_manager_init(&a.session_mgr, 4)
	defer app.session_manager_destroy(&a.session_mgr)
	resize(&a.session_mgr.tabs, 1)
	a.session_mgr.active_idx = 0
	tab := &a.session_mgr.tabs[0]
	b := &tab.backend
	termgrid.terminal_init(&b.terminal, FRAME_PANE_GPU_TRACE_ROWS, FRAME_PANE_GPU_TRACE_COLS)
	termgrid.terminal_init(&b.front_terminal, FRAME_PANE_GPU_TRACE_ROWS, FRAME_PANE_GPU_TRACE_COLS)
	b.pty.master = -1
	b.pty.pid = -1
	b.wake_pipe_r = -1
	b.wake_pipe_w = -1
	second := new(app.Backend)
	termgrid.terminal_init(&second.terminal, FRAME_PANE_GPU_TRACE_ROWS, FRAME_PANE_GPU_TRACE_COLS)
	termgrid.terminal_init(&second.front_terminal, FRAME_PANE_GPU_TRACE_ROWS, FRAME_PANE_GPU_TRACE_COLS)
	second.pty.master = -1
	second.pty.pid = -1
	second.wake_pipe_r = -1
	second.wake_pipe_w = -1
	root := app.pane_tree_init(&tab.tree, b)
	_, ok := app.pane_tree_split(&tab.tree, root, .Vertical, second)
	testing.expect(t, ok)
	app.pane_tree_layout(&tab.tree, platform_tabs.Rect_f32{w = 800, h = 400}, 8, 16, 0, 0)
	_pane_gpu_trace_renderer(&a.renderer)
	defer _pane_gpu_trace_renderer_destroy(&a.renderer)
	delete(a.renderer.instances.instance_data)
	a.renderer.instances.max_instances = 512
	a.renderer.instances.instance_data = make([]instance.Instance_Data, 512)
	render.upload_ring_destroy(&a.renderer.upload_ring)
	render.upload_ring_init(&a.renderer.upload_ring, &_pane_gpu_trace_backend, a.renderer.device, a.renderer.queue, 512*instance.INSTANCE_STRIDE)
	_pane_gpu_trace_mark_damage(&b.front_terminal)
	_pane_gpu_trace_mark_damage(&second.front_terminal)
	// Non-running thread handles select front snapshots without racing a worker.
	b.thread = cast(type_of(b.thread))(uintptr(1))
	second.thread = cast(type_of(second.thread))(uintptr(2))
	defer { b.thread = nil; second.thread = nil }
	testing.expect(t, app.app_has_pending_damage(a), "nonfocused output schedules the composed frame")
	_pane_gpu_trace.present_ok = false
	testing.expect(t, !app.app_present(a))
	testing.expect_value(t, _pane_gpu_trace.present_count, 1)
	testing.expect(t, !b.render_locked && !second.render_locked, "failed publication releases both borrowed locks")
	testing.expect(t, a.renderer.full_redraw_pending && a.has_deferred_render)
	_pane_gpu_trace.present_ok = true
	testing.expect(t, app.app_present(a), "production composed frame must reach fake GPU present")
	testing.expect_value(t, _pane_gpu_trace.present_count, 2)
	testing.expect(t, !b.render_locked && !second.render_locked)
	b.front_terminal.synchronized_output = true
	b.sync_output_start_ns = u64(platform.platform_ticks_to_ns(platform.platform_now()))
	testing.expect(t, !app.app_present(a), "any visible synchronized terminal postpones composed publication")
	testing.expect_value(t, _pane_gpu_trace.present_count, 2)
	testing.expect(t, !b.render_locked && !second.render_locked)
}

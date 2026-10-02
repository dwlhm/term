package render_tests

// Requirement-derived transaction tests. The trace backend uses opaque
// handles and records only publication boundaries, so these tests exercise
// the production lifecycle without a GPU or window system.

import "core:testing"
import "core:sync"
import render "../"
import gpu "../gpu"
import instance "../instance"
import termgrid "../../terminal"

FRAME_TRACE_ROWS :: 4
FRAME_TRACE_COLS :: 8
FRAME_TRACE_UPLOAD_BYTES :: instance.INSTANCE_STRIDE * 4

Trace_Event :: enum {
	Acquire,
	Encode,
	Submit,
	Present,
	Release,
}

Trace_State :: struct {
	events:      [32]Trace_Event,
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

_trace: Trace_State
_trace_mutex: sync.Mutex
_TRACE_DEVICE := rawptr(uintptr(0x1001))
_TRACE_QUEUE := rawptr(uintptr(0x1002))
_TRACE_SURFACE := rawptr(uintptr(0x1003))
_TRACE_TEXTURE := rawptr(uintptr(0x1004))
_TRACE_VIEW := rawptr(uintptr(0x1005))
_TRACE_ENCODER := rawptr(uintptr(0x1006))
_TRACE_PASS := rawptr(uintptr(0x1007))
_TRACE_COMMAND := rawptr(uintptr(0x1008))
_TRACE_BUFFER := rawptr(uintptr(0x1009))
_TRACE_PIPELINE := rawptr(uintptr(0x100a))
_TRACE_BIND_GROUP := rawptr(uintptr(0x100b))

_trace_reset :: proc() {
	_trace = Trace_State{
		acquire_ok = true,
		encoder_ok = true,
		submit_ok = true,
		present_ok = true,
	}
}

_trace_record :: proc(event: Trace_Event) {
	if _trace.count < len(_trace.events) {
		_trace.events[_trace.count] = event
		_trace.count += 1
	}
}

_trace_backend: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	get_surface_texture = _trace_get_surface_texture,
	present_surface = _trace_present_surface,
	create_buffer = _trace_create_buffer,
	destroy_buffer = _trace_destroy_buffer,
	write_buffer = _trace_write_buffer,
	create_command_encoder = _trace_create_command_encoder,
	release_command_encoder = _trace_release_command_encoder,
	begin_render_pass = _trace_begin_render_pass,
	end_render_pass = _trace_end_render_pass,
	finish_command_buffer = _trace_finish_command_buffer,
	release_command_buffer = _trace_release_command_buffer,
	submit = _trace_submit,
	wait_for_idle = _trace_wait_for_idle,
	render_set_pipeline = _trace_render_set_pipeline,
	render_set_bind_group = _trace_render_set_bind_group,
	render_set_vertex_buffer = _trace_render_set_vertex_buffer,
	render_draw = _trace_render_draw,
	release_surface_texture = _trace_release_surface_texture,
	}

_trace_get_surface_texture :: proc(surface: rawptr) -> (texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView, format: gpu.Gpu_Format) {
	_trace_record(.Acquire)
	if !_trace.acquire_ok {
		return gpu.Gpu_Texture(nil), gpu.Gpu_TextureView(nil), .BGRA8_Unorm
	}
	return gpu.Gpu_Texture(_TRACE_TEXTURE), gpu.Gpu_TextureView(_TRACE_VIEW), .BGRA8_Unorm
}

_trace_present_surface :: proc(surface: rawptr) -> bool {
	_trace_record(.Present)
	_trace.present_count += 1
	return _trace.present_ok
}

_trace_create_buffer :: proc(device: gpu.Gpu_Device, size: u64, usage: gpu.Gpu_Buffer_Usage, mapped_at_creation: bool) -> gpu.Gpu_Buffer {
	return gpu.Gpu_Buffer(_TRACE_BUFFER)
}

_trace_destroy_buffer :: proc(buffer: gpu.Gpu_Buffer) {}

_trace_write_buffer :: proc(queue: gpu.Gpu_Queue, buffer: gpu.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	_trace.write_count += 1
}

_trace_create_command_encoder :: proc(device: gpu.Gpu_Device) -> gpu.Gpu_CommandEncoder {
	if !_trace.encoder_ok {
		return gpu.Gpu_CommandEncoder(nil)
	}
	_trace_record(.Encode)
	return gpu.Gpu_CommandEncoder(_TRACE_ENCODER)
}

_trace_release_command_encoder :: proc(encoder: gpu.Gpu_CommandEncoder) {}

_trace_begin_render_pass :: proc(encoder: gpu.Gpu_CommandEncoder, color_view: gpu.Gpu_TextureView, clear_color: [4]f64, load_op: gpu.Gpu_Load_Op) -> gpu.Gpu_RenderPassEncoder {
	return gpu.Gpu_RenderPassEncoder(_TRACE_PASS)
}

_trace_end_render_pass :: proc(pass: gpu.Gpu_RenderPassEncoder) {}

_trace_finish_command_buffer :: proc(encoder: gpu.Gpu_CommandEncoder) -> rawptr {
	return _TRACE_COMMAND
}

_trace_release_command_buffer :: proc(command_buffer: rawptr) {}

_trace_wait_for_idle :: proc(device: gpu.Gpu_Device) -> bool {
	return true
}

_trace_submit :: proc(queue: gpu.Gpu_Queue, command_buffer: rawptr) -> bool {
	_trace_record(.Submit)
	_trace.submit_count += 1
	return _trace.submit_ok
}

_trace_render_set_pipeline :: proc(pass: gpu.Gpu_RenderPassEncoder, pipeline: gpu.Gpu_RenderPipeline) {}
_trace_render_set_bind_group :: proc(pass: gpu.Gpu_RenderPassEncoder, index: u32, group: gpu.Gpu_BindGroup) {}
_trace_render_set_vertex_buffer :: proc(pass: gpu.Gpu_RenderPassEncoder, slot: u32, buffer: gpu.Gpu_Buffer, offset: u64) {}
_trace_render_draw :: proc(pass: gpu.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {}

_trace_release_surface_texture :: proc(texture: gpu.Gpu_Texture, view: gpu.Gpu_TextureView) {
	_trace_record(.Release)
	_trace.release_count += 1
}

_trace_renderer :: proc(r: ^render.Renderer) {
	r.rows = FRAME_TRACE_ROWS
	r.cols = FRAME_TRACE_COLS
	r.cell_width = 8
	r.cell_height = 16
	r.pad_x = 6
	r.pad_y = 4
	r.format = .BGRA8_Unorm
	r.device = gpu.Gpu_Device(_TRACE_DEVICE)
	r.queue = gpu.Gpu_Queue(_TRACE_QUEUE)
	r.surface = gpu.Gpu_Surface(_TRACE_SURFACE)
	r.backend = &_trace_backend
	r.surface_w = 0
	r.surface_h = 0
	r.frame_prepared = true
	r.first_frame_pending = true
	r.full_redraw_pending = false
	r.instances.max_instances = 8
	r.instances.instance_data = make([]instance.Instance_Data, 8)
	r.instances.bg_pipeline = gpu.Gpu_RenderPipeline(_TRACE_PIPELINE)
	r.instances.glyph_pipeline = gpu.Gpu_RenderPipeline(_TRACE_PIPELINE)
	r.instances.bind_group_bg = gpu.Gpu_BindGroup(_TRACE_BIND_GROUP)
	r.instances.bind_group_glyph = gpu.Gpu_BindGroup(_TRACE_BIND_GROUP)
	r.fullscreen.backend = &_trace_backend
	r.fullscreen.device = r.device
	r.fullscreen.queue = r.queue
	r.fullscreen.rows = FRAME_TRACE_ROWS
	r.fullscreen.cols = FRAME_TRACE_COLS
	r.fullscreen.cell_w = 8
	r.fullscreen.cell_h = 16
	r.fullscreen.available = true
	r.fullscreen.pipeline = gpu.Gpu_RenderPipeline(_TRACE_PIPELINE)
	r.fullscreen.bind_group = gpu.Gpu_BindGroup(_TRACE_BIND_GROUP)
	render.render_compiler_init_v2(&r.compiled_v2, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	render.upload_ring_init(&r.upload_ring, &_trace_backend, r.device, r.queue, FRAME_TRACE_UPLOAD_BYTES)
}

_trace_renderer_destroy :: proc(r: ^render.Renderer) {
	render.render_compiler_destroy_v2(&r.compiled_v2)
	render.upload_ring_destroy(&r.upload_ring)
	if r.instances.instance_data != nil {
		delete(r.instances.instance_data)
		r.instances.instance_data = nil
	}
}

_trace_mark_damage :: proc(term: ^termgrid.Terminal) {
	termgrid.damage_mark_span(&term.damage, 1, 2, 4, 7)
	termgrid.damage_mark_row(&term.damage, 2, 9)
	termgrid.damage_record_scroll(&term.damage, 0, FRAME_TRACE_ROWS - 1, 1)
}

_trace_expect_requeued :: proc(t: ^testing.T, term: ^termgrid.Terminal) {
	span_row := &term.damage.dirty_rows[1]
	full_row := &term.damage.dirty_rows[2]
	testing.expect(t, span_row.full || span_row.span_count > 0, "failed frame must restore spans")
	if !span_row.full {
		testing.expect_value(t, span_row.spans[0].col_start, u16(2))
		testing.expect_value(t, span_row.spans[0].col_end, u16(5))
	}
	testing.expect(t, full_row.full || full_row.span_count > 0, "failed frame must restore full rows")
	testing.expect_value(t, len(term.damage.scroll_ops), 1)
}

@(test)
test_frame_transaction_order :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	termgrid.damage_mark_row(&term.damage, 1, 7)
	lut := render.Style_LUT{}

	ok := render.renderer_frame_fullscreen(r, &term, &lut)
	testing.expect(t, ok, "complete transaction must publish")
	testing.expect_value(t, _trace.events[0], Trace_Event.Acquire)
	testing.expect_value(t, _trace.events[1], Trace_Event.Encode)
	testing.expect_value(t, _trace.events[2], Trace_Event.Submit)
	testing.expect_value(t, _trace.events[3], Trace_Event.Present)
	testing.expect_value(t, _trace.events[4], Trace_Event.Release)
	testing.expect_value(t, _trace.release_count, 1)
}

@(test)
test_frame_transaction_cursor_single_submit :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	termgrid.damage_mark_row(&term.damage, 0, 1)
	cursor := render.Cursor_Overlay{visible = true, blink_on = true, row = 0, col = 0}
	testing.expect(t, render.cursor_overlay_draw(r, &cursor), "cursor must stage")
	lut := render.Style_LUT{}
	before_slot := r.upload_ring.write_slot

	testing.expect(t, render.renderer_frame_fullscreen(r, &term, &lut), "cursor frame must publish")
	testing.expect_value(t, _trace.submit_count, 1)
	testing.expect_value(t, _trace.write_count, 1)
	testing.expect_value(t, r.upload_ring.write_slot, (before_slot + 1) % render.UPLOAD_RING_SLOTS)
}

@(test)
test_frame_transaction_surface_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	_trace.acquire_ok = false
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	_trace_mark_damage(&term)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_fullscreen(r, &term, &lut), "acquisition failure must abort")
	_trace_expect_requeued(t, &term)
	testing.expect_value(t, _trace.present_count, 0)
	testing.expect_value(t, _trace.release_count, 0)
}

@(test)
test_frame_transaction_encoder_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	_trace.encoder_ok = false
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	_trace_mark_damage(&term)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_fullscreen(r, &term, &lut), "encoder failure must abort")
	_trace_expect_requeued(t, &term)
	testing.expect_value(t, _trace.present_count, 0)
	testing.expect_value(t, _trace.release_count, 1)
}

@(test)
test_frame_transaction_submit_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	_trace.submit_ok = false
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	_trace_mark_damage(&term)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_fullscreen(r, &term, &lut), "submit failure must abort")
	_trace_expect_requeued(t, &term)
	testing.expect_value(t, _trace.present_count, 0)
	testing.expect_value(t, _trace.release_count, 1)
}

@(test)
test_frame_transaction_present_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	_trace.present_ok = false
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	_trace_mark_damage(&term)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_fullscreen(r, &term, &lut), "present failure must abort")
	_trace_expect_requeued(t, &term)
	testing.expect_value(t, _trace.present_count, 1)
	testing.expect_value(t, _trace.release_count, 1)
	testing.expect(t, r.first_frame_pending, "failed present must not publish first frame")
}

@(test)
test_frame_transaction_strategy_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	_trace.submit_ok = false
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	r.strategy_state.pinned = true
	r.strategy_state.pin = .Fullscreen
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	termgrid.damage_mark_row(&term.damage, 1, 1)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_auto(r, &term, &lut), "sibling failure must not retry inline")
	testing.expect(t, r.fallback_pending, "failed sibling must defer fallback")
	_trace.submit_ok = true
	testing.expect(t, render.renderer_frame_auto(r, &term, &lut), "fallback must publish on next frame")
	testing.expect_value(t, r.strategy, render.Render_Strategy.Instance)
	testing.expect(t, !r.fallback_pending, "deferred fallback must be consumed")
}

@(test)
test_frame_transaction_empty_damage :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	_trace_reset()
	r_storage := make([]render.Renderer, 1)
	defer delete(r_storage)
	r := &r_storage[0]
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	r.first_frame_pending = false
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	lut := render.Style_LUT{}

	testing.expect(t, !render.renderer_frame_fullscreen(r, &term, &lut), "empty damage must skip")
	testing.expect_value(t, _trace.count, 0)
}

@(test)
test_frame_transaction_out_of_range_journal :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
	defer termgrid.terminal_destroy(&term)
	rows := make([]termgrid.Dirty_Row, 1)
	ops := make([]termgrid.Scroll_Op, 1)
	defer delete(rows)
	defer delete(ops)
	rows[0].span_count = 1
	rows[0].spans[0] = termgrid.Span{col_start = 99, col_end = 200}
	ops[0] = termgrid.Scroll_Op{top = 99, bottom = 200, rows = 1}
	journal := termgrid.Damage_Journal{dirty_rows = rows, scroll_ops = ops}

	termgrid.damage_requeue_journal(&term.damage, &journal)
	testing.expect_value(t, term.damage.dirty_rows[0].span_count, u8(0))
	testing.expect_value(t, len(term.damage.scroll_ops), 0)
}

@(test)
test_pane_frame_damage_and_overlay_transaction :: proc(t: ^testing.T) {
	sync.mutex_lock(&_trace_mutex)
	defer sync.mutex_unlock(&_trace_mutex)
	r := new(render.Renderer)
	defer free(r)
	_trace_renderer(r)
	defer _trace_renderer_destroy(r)
	delete(r.instances.instance_data)
	r.instances.max_instances = 128
	r.instances.instance_data = make([]instance.Instance_Data, 128)
	render.upload_ring_destroy(&r.upload_ring)
	render.upload_ring_init(&r.upload_ring, &_trace_backend, r.device, r.queue, 128 * instance.INSTANCE_STRIDE)
	terms := make([]termgrid.Terminal, 2)
	defer delete(terms)
	defer { for &term in terms { termgrid.terminal_destroy(&term) } }
	panes := make([]render.Pane_Viewport, 2)
	defer delete(panes)
	for i in 0 ..< len(terms) {
		termgrid.terminal_init(&terms[i], FRAME_TRACE_ROWS, FRAME_TRACE_COLS)
		_trace_mark_damage(&terms[i])
		panes[i] = render.Pane_Viewport{terminal = &terms[i], x = f32(i)*16, w = 16, h = 32, rows = 2, cols = 2, dim_factor = 1, is_active = i == 0}
	}
	r.cursor_staged = true
	r.ui_staged = true
	r.ui_bg_count = 1
	r.ui_bg_data[0] = instance.Instance_Data{cw = 4, ch = 4}
	r.interaction_staged = true
	r.interaction_slot_start = 126
	r.interaction_quad_count = 1
	_trace_reset()
	_trace.submit_ok = false
	testing.expect(t, !render.renderer_frame_panes(r, panes))
	for &term in terms { _trace_expect_requeued(t, &term) }
	testing.expect_value(t, _trace.present_count, 0)
	testing.expect_value(t, _trace.release_count, 1)
	testing.expect(t, r.cursor_staged && r.ui_staged && r.interaction_staged && r.first_frame_pending, "failed frame must preserve pending overlays")
	_trace_reset()
	r.unlock_cb = _trace_pane_unlock
	r.unlock_data = r
	testing.expect(t, render.renderer_frame_panes(r, panes))
	testing.expect_value(t, _trace.unlock_count, 1)
	testing.expect(t, _trace.unlock_after_publication, "pane callback must follow publication and borrowed-state cleanup")
	testing.expect_value(t, _trace.submit_count, 1)
	testing.expect_value(t, _trace.present_count, 1)
	testing.expect_value(t, _trace.release_count, 1)
	testing.expect(t, !r.cursor_staged && !r.ui_staged && !r.interaction_staged && !r.first_frame_pending)
	for &term in terms {
		testing.expect_value(t, len(term.damage.scroll_ops), 0)
	}
	_trace_reset()
	panes[0].cols = 0
	testing.expect(t, !render.renderer_frame_panes(r, panes))
	testing.expect_value(t, _trace.count, 0)
	panes[0].cols = 2
	r.instances.max_instances = 2
	testing.expect(t, !render.renderer_frame_panes(r, panes), "capacity failure must precede surface acquisition")
	testing.expect_value(t, _trace.count, 0)
}

_trace_pane_unlock :: proc(data: rawptr) {
	r := (^render.Renderer)(data)
	_trace.unlock_count += 1
	_trace.unlock_after_publication = _trace.present_count > 0 && !r.first_frame_pending && !r.ui_staged
}

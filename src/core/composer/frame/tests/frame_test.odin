package frame_tests

// Production frame loop CPU-only test suite.
// Drives frame.frame_tick through a counting mock contract.* vtable and an injected
// virtual clock (u64 ns advanced by the test; ZERO wall-clock APIs). No GPU required.
//
// Pass definitions (K2):
//   Raster pass    = begin_render_pass whose color_view is a layer backing view.
//   Composite pass = begin_render_pass whose color_view is the frame target view.

import "core:hash"
import "core:mem"
import "core:testing"

import composer "../../"
import frame "../"
import layer "../../layer"
import pipeline "../../pipeline"
import scheduler "../../scheduler"
import transition "../../transition"
import contract "../../../render/contract"

NS_PER_MS :: u64(1_000_000)
NS_PER_S  :: u64(1_000_000_000)

SCREEN_W :: f32(1920)
SCREEN_H :: f32(1080)

T0_NS :: u64(5) * NS_PER_S

// ============================================================================
// Counting mock contract vtable
// ============================================================================

// Fake handle ranges. Layer backing views live in [VIEW_BASE, TARGET_VIEW_ID).
@(private = "file")
TEX_BASE: uintptr : 0x0100_0000
@(private = "file")
VIEW_BASE: uintptr : 0x0200_0000
@(private = "file")
TARGET_TEX_ID: uintptr : 0x0E00_0000
@(private = "file")
TARGET_VIEW_ID: uintptr : 0x0F00_0000
@(private = "file")
MOCK_DEVICE :: contract.Gpu_Device(rawptr(uintptr(0x8000)))
@(private = "file")
MOCK_QUEUE :: contract.Gpu_Queue(rawptr(uintptr(0x9000)))
@(private = "file")
MOCK_HANDLE :: rawptr(uintptr(0xA000))

Mock_Counts :: struct {
	raster_passes:    int,
	composite_passes: int,
	other_passes:     int,
	submits:          int,
	create_texture:   int,
	destroy_texture:  int,
}

@(private = "file")
_mock: Mock_Counts
@(private = "file")
_next_tex: uintptr
@(private = "file")
_next_view: uintptr

@(private = "file")
_mock_create_texture :: proc(device: contract.Gpu_Device, width, height: u32, format: contract.Gpu_Format, usage: contract.Gpu_Texture_Usage) -> contract.Gpu_Texture {
	_mock.create_texture += 1
	_next_tex += 1
	return contract.Gpu_Texture(rawptr(_next_tex))
}

@(private = "file")
_mock_destroy_texture :: proc(texture: contract.Gpu_Texture) {
	_mock.destroy_texture += 1
}

@(private = "file")
_mock_create_texture_view :: proc(texture: contract.Gpu_Texture) -> contract.Gpu_TextureView {
	_next_view += 1
	return contract.Gpu_TextureView(rawptr(_next_view))
}

@(private = "file")
_mock_destroy_texture_view :: proc(view: contract.Gpu_TextureView) {}

@(private = "file")
_mock_create_sampler :: proc(device: contract.Gpu_Device) -> contract.Gpu_Sampler {
	return contract.Gpu_Sampler(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_sampler :: proc(sampler: contract.Gpu_Sampler) {}

@(private = "file")
_mock_create_buffer :: proc(device: contract.Gpu_Device, size: u64, usage: contract.Gpu_Buffer_Usage, mapped_at_creation: bool) -> contract.Gpu_Buffer {
	return contract.Gpu_Buffer(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_buffer :: proc(buffer: contract.Gpu_Buffer) {}

@(private = "file")
_mock_write_buffer :: proc(queue: contract.Gpu_Queue, buffer: contract.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {}

@(private = "file")
_mock_create_shader_module :: proc(device: contract.Gpu_Device, source: string) -> contract.Gpu_ShaderModule {
	return contract.Gpu_ShaderModule(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_shader_module :: proc(module: contract.Gpu_ShaderModule) {}

@(private = "file")
_mock_create_render_pipeline :: proc(
	device: contract.Gpu_Device,
	vertex_shader: contract.Gpu_ShaderModule,
	vertex_entry: string,
	fragment_shader: contract.Gpu_ShaderModule,
	fragment_entry: string,
	vertex_layouts: []contract.Gpu_Vertex_Layout,
	format: contract.Gpu_Format,
	blend: contract.Gpu_Blend_Mode,
	topology: contract.Gpu_Primitive_Topology,
) -> contract.Gpu_RenderPipeline {
	return contract.Gpu_RenderPipeline(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_render_pipeline :: proc(p: contract.Gpu_RenderPipeline) {}

@(private = "file")
_mock_pipeline_get_bind_group_layout :: proc(p: contract.Gpu_RenderPipeline, index: u32) -> contract.Gpu_BindGroupLayout {
	return contract.Gpu_BindGroupLayout(MOCK_HANDLE)
}

@(private = "file")
_mock_create_bind_group_layout :: proc(device: contract.Gpu_Device, entries: []contract.Gpu_Bind_Layout_Entry) -> contract.Gpu_BindGroupLayout {
	return contract.Gpu_BindGroupLayout(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_bind_group_layout :: proc(l: contract.Gpu_BindGroupLayout) {}

@(private = "file")
_mock_create_bind_group :: proc(device: contract.Gpu_Device, l: contract.Gpu_BindGroupLayout, entries: []contract.Gpu_Bind_Entry) -> contract.Gpu_BindGroup {
	return contract.Gpu_BindGroup(MOCK_HANDLE)
}

@(private = "file")
_mock_destroy_bind_group :: proc(group: contract.Gpu_BindGroup) {}

@(private = "file")
_mock_create_command_encoder :: proc(device: contract.Gpu_Device) -> contract.Gpu_CommandEncoder {
	return contract.Gpu_CommandEncoder(MOCK_HANDLE)
}

@(private = "file")
_mock_release_command_encoder :: proc(encoder: contract.Gpu_CommandEncoder) {}

@(private = "file")
_mock_begin_render_pass :: proc(encoder: contract.Gpu_CommandEncoder, color_view: contract.Gpu_TextureView, clear_color: [4]f64, load_op: contract.Gpu_Load_Op) -> contract.Gpu_RenderPassEncoder {
	v := uintptr(rawptr(color_view))
	switch {
	case v == TARGET_VIEW_ID:
		_mock.composite_passes += 1
	case v > VIEW_BASE && v < TARGET_VIEW_ID:
		_mock.raster_passes += 1
	case:
		_mock.other_passes += 1
	}
	return contract.Gpu_RenderPassEncoder(MOCK_HANDLE)
}

@(private = "file")
_mock_end_render_pass :: proc(pass: contract.Gpu_RenderPassEncoder) {}

@(private = "file")
_mock_finish_command_buffer :: proc(encoder: contract.Gpu_CommandEncoder) -> rawptr {
	return MOCK_HANDLE
}

@(private = "file")
_mock_release_command_buffer :: proc(command_buffer: rawptr) {}

@(private = "file")
_mock_submit :: proc(queue: contract.Gpu_Queue, command_buffer: rawptr) -> bool {
	_mock.submits += 1
	return true
}

@(private = "file")
_mock_render_set_pipeline :: proc(pass: contract.Gpu_RenderPassEncoder, p: contract.Gpu_RenderPipeline) {}

@(private = "file")
_mock_render_set_bind_group :: proc(pass: contract.Gpu_RenderPassEncoder, index: u32, group: contract.Gpu_BindGroup) {}

@(private = "file")
_mock_render_draw :: proc(pass: contract.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {}

@(private = "file")
_install_mock_vtable :: proc() {
	_mock = {}
	_next_tex = TEX_BASE
	_next_view = VIEW_BASE

	contract.create_texture                 = _mock_create_texture
	contract.destroy_texture                = _mock_destroy_texture
	contract.create_texture_view            = _mock_create_texture_view
	contract.destroy_texture_view           = _mock_destroy_texture_view
	contract.create_sampler                 = _mock_create_sampler
	contract.destroy_sampler                = _mock_destroy_sampler
	contract.create_buffer                  = _mock_create_buffer
	contract.destroy_buffer                 = _mock_destroy_buffer
	contract.write_buffer                   = _mock_write_buffer
	contract.create_shader_module           = _mock_create_shader_module
	contract.destroy_shader_module          = _mock_destroy_shader_module
	contract.create_render_pipeline         = _mock_create_render_pipeline
	contract.destroy_render_pipeline        = _mock_destroy_render_pipeline
	contract.pipeline_get_bind_group_layout = _mock_pipeline_get_bind_group_layout
	contract.create_bind_group_layout       = _mock_create_bind_group_layout
	contract.destroy_bind_group_layout      = _mock_destroy_bind_group_layout
	contract.create_bind_group              = _mock_create_bind_group
	contract.destroy_bind_group             = _mock_destroy_bind_group
	contract.create_command_encoder         = _mock_create_command_encoder
	contract.release_command_encoder        = _mock_release_command_encoder
	contract.begin_render_pass              = _mock_begin_render_pass
	contract.end_render_pass                = _mock_end_render_pass
	contract.finish_command_buffer          = _mock_finish_command_buffer
	contract.release_command_buffer         = _mock_release_command_buffer
	contract.submit                         = _mock_submit
	contract.render_set_pipeline            = _mock_render_set_pipeline
	contract.render_set_bind_group          = _mock_render_set_bind_group
	contract.render_draw                    = _mock_render_draw
}

// ============================================================================
// Test frame driver (acquire / raster / present)
// ============================================================================

Test_Driver_State :: struct {
	acquire_fail_remaining: int,
	present_calls:          int,
}

@(private = "file")
_drv_acquire :: proc(user: rawptr) -> (tex: contract.Gpu_Texture, view: contract.Gpu_TextureView, ok: bool) {
	st := (^Test_Driver_State)(user)
	if st.acquire_fail_remaining > 0 {
		st.acquire_fail_remaining -= 1
		return nil, nil, false
	}
	return contract.Gpu_Texture(rawptr(TARGET_TEX_ID)), contract.Gpu_TextureView(rawptr(TARGET_VIEW_ID)), true
}

// _drv_raster opens and closes one render pass on the layer backing view so the mock
// observes a raster pass.
@(private = "file")
_drv_raster :: proc(user: rawptr, enc: contract.Gpu_CommandEncoder, l: ^composer.Composer_Layer) -> bool {
	pass := contract.begin_render_pass(enc, l.view, {0, 0, 0, 1}, .Clear)
	if rawptr(pass) == nil do return false
	contract.end_render_pass(pass)
	return true
}

@(private = "file")
_drv_present :: proc(user: rawptr, tex: contract.Gpu_Texture, view: contract.Gpu_TextureView) -> bool {
	st := (^Test_Driver_State)(user)
	st.present_calls += 1
	return true
}

// ============================================================================
// Fixture
// ============================================================================

Fixture :: struct {
	s:          scheduler.Frame_Scheduler,
	cp:         pipeline.Composer_Pipeline,
	tm:         transition.Transition_Manager,
	drv_state:  Test_Driver_State,
	drv:        frame.Frame_Driver,

	// Accumulated across _tick calls (reset via _reset_totals).
	totals:     Mock_Counts,
	outcomes:   Mock_Counts, // raster/composite/submits summed from Frame_Outcome
	mismatches: int,         // ticks where mock deltas disagreed with Frame_Outcome
}

@(private = "file")
_fixture_init :: proc(t: ^testing.T, fx: ^Fixture) -> bool {
	_install_mock_vtable()
	fx^ = {}
	scheduler.scheduler_init(&fx.s)
	transition.transition_manager_init(&fx.tm)
	ok := pipeline.composer_pipeline_init(&fx.cp, MOCK_DEVICE, MOCK_QUEUE, .BGRA8_Unorm, SCREEN_W, SCREEN_H)
	testing.expect(t, ok, "composer_pipeline_init must succeed against mock vtable")
	fx.drv = frame.Frame_Driver{
		user    = &fx.drv_state,
		acquire = _drv_acquire,
		raster  = _drv_raster,
		present = _drv_present,
	}
	return ok
}

@(private = "file")
_fixture_destroy :: proc(fx: ^Fixture) {
	pipeline.composer_pipeline_destroy(&fx.cp)
}

@(private = "file")
_reset_totals :: proc(fx: ^Fixture) {
	fx.totals = {}
	fx.outcomes = {}
	fx.mismatches = 0
}

// _tick runs one frame_tick and cross-checks mock per-frame deltas against Frame_Outcome.
// Performs no allocation and no testing.* calls (safe inside allocation-tracked loops).
@(private = "file")
_tick :: proc(fx: ^Fixture, now_ns: u64, use_tm: bool = true) -> frame.Frame_Outcome {
	before := _mock
	tm := &fx.tm if use_tm else nil
	out := frame.frame_tick(&fx.s, &fx.cp, tm, &fx.drv, now_ns)

	d_raster := _mock.raster_passes - before.raster_passes
	d_composite := _mock.composite_passes - before.composite_passes
	d_submits := _mock.submits - before.submits

	if d_raster != out.raster_calls || d_composite != out.composite_calls || d_submits != out.submits {
		fx.mismatches += 1
	}

	fx.totals.raster_passes += d_raster
	fx.totals.composite_passes += d_composite
	fx.totals.submits += d_submits
	fx.outcomes.raster_passes += out.raster_calls
	fx.outcomes.composite_passes += out.composite_calls
	fx.outcomes.submits += out.submits
	return out
}

@(private = "file")
_expect_totals :: proc(t: ^testing.T, fx: ^Fixture, raster, composite, submits: int, loc := #caller_location) {
	testing.expect_value(t, fx.mismatches, 0, loc = loc)
	testing.expect_value(t, fx.totals.raster_passes, raster, loc = loc)
	testing.expect_value(t, fx.totals.composite_passes, composite, loc = loc)
	testing.expect_value(t, fx.totals.submits, submits, loc = loc)
	testing.expect_value(t, fx.outcomes.raster_passes, raster, loc = loc)
	testing.expect_value(t, fx.outcomes.composite_passes, composite, loc = loc)
	testing.expect_value(t, fx.outcomes.submits, submits, loc = loc)
}

// ============================================================================
// Invariance / idle tests
// ============================================================================

@test
test_idle_zero_submits :: proc(t: ^testing.T) {
	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	_, ok1 := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(1), .Terminal, 256, 256)
	_, ok2 := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(2), .Terminal, 256, 256)
	testing.expect(t, ok1 && ok2, "Acquiring 2 layers must succeed")

	// First frame forced by scheduler_init.
	_tick(fx, T0_NS)
	testing.expect_value(t, fx.totals.submits, 1)
	testing.expect_value(t, fx.mismatches, 0)

	_reset_totals(fx)
	for ms in u64(1)..=10_000 {
		_tick(fx, T0_NS + ms * NS_PER_MS)
	}
	_expect_totals(t, fx, 0, 0, 0)
}

// Blink_Controller is a test-local, deadline-driven, drift-free cursor blink.
Blink_Controller :: struct {
	pane:        composer.Layer_Id,
	interval_ns: u64,
	next_ns:     u64,
	visible:     bool,
	toggles:     int,
}

@(private = "file")
_blink_arm :: proc(b: ^Blink_Controller, s: ^scheduler.Frame_Scheduler, start_ns: u64) {
	b.next_ns = start_ns + b.interval_ns
	scheduler.scheduler_set_deadline(s, b.next_ns)
}

@(private = "file")
_blink_update :: proc(b: ^Blink_Controller, s: ^scheduler.Frame_Scheduler, cp: ^pipeline.Composer_Pipeline, now_ns: u64) {
	if now_ns < b.next_ns do return
	b.visible = !b.visible
	b.toggles += 1
	pipeline.composer_pipeline_mark_dirty(cp, b.pane)
	scheduler.scheduler_mark_damage(s, b.pane)
	b.next_ns += b.interval_ns // drift-free: prev_deadline + interval, never now + interval
	scheduler.scheduler_set_deadline(s, b.next_ns)
}

@(private = "file")
_run_blink :: proc(t: ^testing.T, step_ns: u64, loc := #caller_location) {
	BLINK_INTERVAL_NS :: 500 * NS_PER_MS
	WINDOW_NS :: 10 * NS_PER_S
	EXPECTED_TOGGLES :: 20

	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	pane := composer.Layer_Id(1)
	other := composer.Layer_Id(2)
	_, ok1 := pipeline.composer_pipeline_acquire_layer(&fx.cp, pane, .Terminal, 256, 256)
	_, ok2 := pipeline.composer_pipeline_acquire_layer(&fx.cp, other, .Chrome, 256, 256)
	testing.expect(t, ok1 && ok2, "Acquiring layers must succeed", loc = loc)

	_tick(fx, T0_NS) // forced first frame rasterizes both new layers
	_reset_totals(fx)

	b := Blink_Controller{pane = pane, interval_ns = BLINK_INTERVAL_NS}
	_blink_arm(&b, &fx.s, T0_NS)

	// Window (t0, t0 + 10 s], inclusive end: final tick is clamped to the window end.
	end_ns := T0_NS + WINDOW_NS
	now := T0_NS
	for now < end_ns {
		now = min(now + step_ns, end_ns)
		_blink_update(&b, &fx.s, &fx.cp, now)
		_tick(fx, now)
	}

	testing.expect_value(t, b.toggles, EXPECTED_TOGGLES, loc = loc)
	_expect_totals(t, fx, EXPECTED_TOGGLES, EXPECTED_TOGGLES, EXPECTED_TOGGLES, loc = loc)
}

@test
test_blink_exactly_20_in_10s :: proc(t: ^testing.T) {
	_run_blink(t, 1 * NS_PER_MS)
	_run_blink(t, 7 * NS_PER_MS) // deadlines land between ticks
}

@test
test_clean_moving_layer_composites_without_raster :: proc(t: ^testing.T) {
	DURATION_MS :: u64(200)

	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	id := composer.Layer_Id(1)
	_, ok := pipeline.composer_pipeline_acquire_layer(&fx.cp, id, .Overlay, 256, 256)
	testing.expect(t, ok, "Acquiring layer must succeed")

	_tick(fx, T0_NS) // forced first frame cleans the layer
	testing.expect(t, !pipeline.composer_pipeline_is_dirty(&fx.cp, id), "Layer must be clean before transition")
	_reset_totals(fx)

	start_ns := T0_NS + NS_PER_S
	from_rect := composer.rect_make(0, 0, 256, 256)
	to_rect := composer.rect_make(500, 300, 256, 256)
	h := transition.transition_start_rect(&fx.tm, &fx.s, id, from_rect, to_rect, start_ns, DURATION_MS * NS_PER_MS, .Linear)
	testing.expect(t, h != 0, "Transition handle must be non-zero")

	should_render_true_frames := 0
	for ms in u64(0)..=DURATION_MS {
		_tick(fx, start_ns + ms * NS_PER_MS)
		if pipeline.composer_pipeline_should_render(&fx.cp) {
			should_render_true_frames += 1
		}
	}
	_expect_totals(t, fx, 0, int(DURATION_MS) + 1, int(DURATION_MS) + 1)
	testing.expect_value(t, should_render_true_frames, 0)

	l := pipeline.composer_pipeline_get_layer(&fx.cp, id)
	testing.expect(t, l != nil && l.dest_rect == to_rect, "Layer must land on target rect")

	_reset_totals(fx)
	tail_start := start_ns + DURATION_MS * NS_PER_MS
	for ms in u64(1)..=1_000 {
		_tick(fx, tail_start + ms * NS_PER_MS)
	}
	_expect_totals(t, fx, 0, 0, 0)
}

@test
test_one_shot_deadline_consumed :: proc(t: ^testing.T) {
	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	_, ok := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(1), .Terminal, 256, 256)
	testing.expect(t, ok, "Acquiring layer must succeed")

	_tick(fx, T0_NS)
	_reset_totals(fx)

	scheduler.scheduler_set_deadline(&fx.s, T0_NS + 100 * NS_PER_MS)
	for ms in u64(1)..=1_000 {
		_tick(fx, T0_NS + ms * NS_PER_MS)
	}
	_expect_totals(t, fx, 0, 1, 1)
	testing.expect_value(t, fx.s.next_deadline, u64(0))
}

// Documents the scheduler-level behavior frame_tick compensates for:
// scheduler_frame_done does NOT clear an expired next_deadline.
@test
test_scheduler_deadline_not_cleared_by_frame_done :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_init(&s)
	scheduler.scheduler_frame_done(&s)

	deadline := T0_NS + 100 * NS_PER_MS
	scheduler.scheduler_set_deadline(&s, deadline)

	needs, _ := scheduler.scheduler_needs_frame(&s, deadline)
	testing.expect(t, needs, "Expired deadline must request a frame")

	scheduler.scheduler_frame_done(&s)

	needs_after, _ := scheduler.scheduler_needs_frame(&s, deadline + NS_PER_MS)
	testing.expect(t, needs_after, "[MEASURED] frame_done leaves expired deadline armed -> needs_frame stays true")
	testing.expect_value(t, s.next_deadline, deadline)
}

@test
test_acquire_failure_retries :: proc(t: ^testing.T) {
	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	id := composer.Layer_Id(1)
	_, ok := pipeline.composer_pipeline_acquire_layer(&fx.cp, id, .Terminal, 256, 256)
	testing.expect(t, ok, "Acquiring layer must succeed")

	fx.drv_state.acquire_fail_remaining = 1
	rendered_before := fx.s.rendered_frames

	out1 := _tick(fx, T0_NS)
	testing.expect_value(t, out1.fail, frame.Frame_Fail.Acquire_Failed)
	testing.expect_value(t, out1.submits, 1)
	testing.expect_value(t, out1.presented, false)
	testing.expect_value(t, out1.composite_calls, 0)
	testing.expect_value(t, out1.raster_calls, 1)
	testing.expect_value(t, fx.s.rendered_frames, rendered_before)
	testing.expect(t, !pipeline.composer_pipeline_is_dirty(&fx.cp, id), "Raster work must not be lost: layer clean after submit")

	out2 := _tick(fx, T0_NS + NS_PER_MS)
	testing.expect_value(t, out2.fail, frame.Frame_Fail.None)
	testing.expect_value(t, out2.composite_calls, 1)
	testing.expect_value(t, out2.raster_calls, 0)
	testing.expect_value(t, out2.presented, true)
	testing.expect_value(t, fx.s.rendered_frames, rendered_before + 1)
	testing.expect_value(t, fx.mismatches, 0)
}

// ============================================================================
// Capacity / leak / allocation tests
// ============================================================================

@(private = "file")
_hash_val :: proc(h: u64, v: ^$T) -> u64 {
	return hash.fnv64a(mem.ptr_to_bytes(v), h)
}

// _logical_hash hashes ONLY logical layer fields (no GPU handles, no padding, no raw memory).
@(private = "file")
_logical_hash :: proc(cp: ^pipeline.Composer_Pipeline) -> u64 {
	h := u64(0xcbf29ce484222325)
	for i in 0..<layer.MAX_COMPOSER_LAYERS {
		l := &cp.layer_pool.layers[i]
		h = _hash_val(h, &l.id)
		h = _hash_val(h, &l.slot_index)
		h = _hash_val(h, &l.kind)
		h = _hash_val(h, &l.width)
		h = _hash_val(h, &l.height)
		h = _hash_val(h, &l.in_use)
		h = _hash_val(h, &l.is_dirty)
		h = _hash_val(h, &l.version)
		h = _hash_val(h, &l.dest_rect.x)
		h = _hash_val(h, &l.dest_rect.y)
		h = _hash_val(h, &l.dest_rect.w)
		h = _hash_val(h, &l.dest_rect.h)
		h = _hash_val(h, &l.scissor_rect.x)
		h = _hash_val(h, &l.scissor_rect.y)
		h = _hash_val(h, &l.scissor_rect.w)
		h = _hash_val(h, &l.scissor_rect.h)
		h = _hash_val(h, &l.opacity)
		h = _hash_val(h, &l.corner_radius)
	}
	for i in 0..<cp.layer_count {
		h = _hash_val(h, &cp.layer_order[i])
	}
	h = _hash_val(h, &cp.layer_count)
	return h
}

@test
test_capacity_rejection_logical_hash :: proc(t: ^testing.T) {
	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	for i in 1..=layer.MAX_COMPOSER_LAYERS {
		_, ok := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(i), .Terminal, 128, 128)
		testing.expect(t, ok, "Acquisition within capacity must succeed")
	}
	testing.expect_value(t, fx.cp.layer_count, layer.MAX_COMPOSER_LAYERS)

	hash_before := _logical_hash(&fx.cp)
	creates_before := _mock.create_texture

	l, ok := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(layer.MAX_COMPOSER_LAYERS + 1), .Terminal, 128, 128)
	testing.expect_value(t, ok, false)
	testing.expect(t, l == nil, "Rejected acquisition must return nil")
	testing.expect_value(t, _logical_hash(&fx.cp), hash_before)
	testing.expect_value(t, _mock.create_texture, creates_before)
}

@test
test_lifecycle_net_zero_10k :: proc(t: ^testing.T) {
	ITERATIONS :: 10_000

	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	heap_track: mem.Tracking_Allocator
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_track, context.allocator)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&heap_track)
	defer mem.tracking_allocator_destroy(&temp_track)

	creates_base := _mock.create_texture
	destroys_base := _mock.destroy_texture
	heap_bytes_base, heap_entries_base: i64
	temp_bytes_base, temp_entries_base: i64
	id := composer.Layer_Id(1)
	failures := 0

	{
		context.allocator = mem.tracking_allocator(&heap_track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)

		heap_bytes_base = heap_track.current_memory_allocated
		heap_entries_base = i64(len(heap_track.allocation_map))
		temp_bytes_base = temp_track.current_memory_allocated
		temp_entries_base = i64(len(temp_track.allocation_map))

		for _ in 0..<ITERATIONS {
			_, ok_a := pipeline.composer_pipeline_acquire_layer(&fx.cp, id, .Terminal, 256, 256)
			_, ok_b := pipeline.composer_pipeline_acquire_layer(&fx.cp, id, .Terminal, 512, 384) // resize
			if !ok_a || !ok_b do failures += 1
			pipeline.composer_pipeline_release_layer(&fx.cp, id)
		}
	}

	testing.expect_value(t, failures, 0)
	testing.expect_value(t, heap_track.current_memory_allocated, heap_bytes_base)
	testing.expect_value(t, i64(len(heap_track.allocation_map)), heap_entries_base)
	testing.expect_value(t, temp_track.current_memory_allocated, temp_bytes_base)
	testing.expect_value(t, i64(len(temp_track.allocation_map)), temp_entries_base)
	testing.expect_value(t, _mock.create_texture - creates_base, ITERATIONS * 2)
	testing.expect_value(t, _mock.create_texture - creates_base, _mock.destroy_texture - destroys_base)
	testing.expect_value(t, _mock.create_texture, _mock.destroy_texture)
	testing.expect_value(t, fx.cp.layer_count, 0)
}

@test
test_steady_state_zero_alloc :: proc(t: ^testing.T) {
	WARMUP_TICKS :: 10
	MEASURED_TICKS :: 1_000

	fx := new(Fixture)
	defer free(fx)
	if !_fixture_init(t, fx) do return
	defer _fixture_destroy(fx)

	id := composer.Layer_Id(1)
	_, ok1 := pipeline.composer_pipeline_acquire_layer(&fx.cp, id, .Terminal, 256, 256)
	_, ok2 := pipeline.composer_pipeline_acquire_layer(&fx.cp, composer.Layer_Id(2), .Chrome, 256, 256)
	testing.expect(t, ok1 && ok2, "Acquiring layers must succeed")

	now := T0_NS
	for _ in 0..<WARMUP_TICKS {
		pipeline.composer_pipeline_mark_dirty(&fx.cp, id)
		scheduler.scheduler_mark_damage(&fx.s, id)
		_tick(fx, now)
		now += NS_PER_MS
	}
	_reset_totals(fx)

	heap_track: mem.Tracking_Allocator
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_track, context.allocator)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&heap_track)
	defer mem.tracking_allocator_destroy(&temp_track)

	{
		context.allocator = mem.tracking_allocator(&heap_track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)

		for _ in 0..<MEASURED_TICKS {
			pipeline.composer_pipeline_mark_dirty(&fx.cp, id)
			scheduler.scheduler_mark_damage(&fx.s, id)
			_tick(fx, now)
			now += NS_PER_MS
		}
	}

	testing.expect_value(t, heap_track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
	_expect_totals(t, fx, MEASURED_TICKS, MEASURED_TICKS, MEASURED_TICKS)
}

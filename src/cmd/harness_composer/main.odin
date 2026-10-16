package main

// Standalone Native GUI Harness & Comprehensive Benchmark for core_composer.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Principles & Invariants:
// 1. Composer-only: Backing layers are pre-filled ONCE at startup with solid colors
//    via GPU clear render passes. Zero raster functions, font atlas lookups, or terminal/chrome
//    draw lists are called throughout the entire benchmark.
// 2. 100% Measured Cost Belongs to Composer: Isolates pure compositor pipeline overhead,
//    command buffer encoding, hardware blits, and surface presentation.
// 3. Zero Heap Allocation Invariant: Zero dynamic heap allocations during steady-state frames
//    verified via mem.Tracking_Allocator.
// 4. Strict adherence to Odin -strict-style.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/unix"
import "core:time"
import "vendor:sdl3"
import "vendor:wgpu"

import plat_win "../../platform/window"
import helper "../harness_helper"
import contract "../../core/render/contract"
import wgpu_backend "../../platform/gpu/wgpu"
import composer "../../core/composer"
import pipeline "../../core/composer/pipeline"
import layer "../../core/composer/layer"
import transition "../../core/composer/transition"

GIT_COMMIT :: #config(GIT_COMMIT, "dev")

// Pre-defined layer identifiers (1..16)
LAYER_IDS: [layer.MAX_COMPOSER_LAYERS]composer.Layer_Id = {
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
}

// High-contrast distinct RGBA palette for pre-filled layers
LAYER_PALETTE: [layer.MAX_COMPOSER_LAYERS][4]f64 = {
	{0.85, 0.15, 0.15, 1.0}, //  1: Red
	{0.15, 0.75, 0.20, 1.0}, //  2: Green
	{0.20, 0.40, 0.90, 1.0}, //  3: Blue
	{0.92, 0.78, 0.12, 1.0}, //  4: Yellow
	{0.80, 0.20, 0.80, 1.0}, //  5: Magenta
	{0.15, 0.75, 0.80, 1.0}, //  6: Cyan
	{0.90, 0.50, 0.10, 1.0}, //  7: Orange
	{0.55, 0.25, 0.75, 1.0}, //  8: Purple
	{0.45, 0.85, 0.25, 1.0}, //  9: Lime
	{0.95, 0.40, 0.60, 1.0}, // 10: Pink
	{0.10, 0.60, 0.55, 1.0}, // 11: Teal
	{0.60, 0.35, 0.20, 1.0}, // 12: Brown
	{0.70, 0.65, 0.90, 1.0}, // 13: Lavender
	{0.95, 0.70, 0.05, 1.0}, // 14: Amber
	{0.95, 0.45, 0.35, 1.0}, // 15: Coral
	{0.30, 0.85, 0.65, 1.0}, // 16: Mint
}

Harness_State :: struct {
	window:              plat_win.Window,
	instance:            rawptr,
	surface:             rawptr,
	device:              contract.Gpu_Device,
	queue:               contract.Gpu_Queue,
	format:              contract.Gpu_Format,
	running:             bool,
	screen_w:            f32,
	screen_h:            f32,

	// Core Composer Pipeline
	composer_pipe:       pipeline.Composer_Pipeline,
	tm:                  transition.Transition_Manager,

	// Hardware GPU Timestamp Query Benchmarking Resources
	ts_query_set:        wgpu.QuerySet,
	ts_resolve_buf:      wgpu.Buffer,
	ts_readback_buf:     wgpu.Buffer,
	ts_supported:        bool,
	ts_period:           f32,
}

Size_Mode :: enum {
	Fullscreen,
	Popup,
	Cursor,
	Grid,
	Checkerboard_4K,
	Pathological_Scissor,
}

Dirty_Mode :: enum {
	None,
	One,
	All,
}

Anim_Kind :: enum {
	None,
	Slide_Popup,
	Fade_In_Out,
	Crossfade_Tab,
	Scroll_Offset,
	Moving_Layers,
}

Scenario_Kind :: enum {
	Layer_Count,
	Layer_Size,
	Overdraw,
	Dirty_Count,
	Offscreen_Res,
	Clear_Mode,
}

Scenario_Config :: struct {
	name:         string,
	kind:         Scenario_Kind,
	anim_kind:    Anim_Kind,
	anim_count:   int,
	layer_count:  int,
	size_mode:    Size_Mode,
	dirty_mode:   Dirty_Mode,
	load_op:      contract.Gpu_Load_Op,
	is_offscreen: bool,
	target_w:     u32,
	target_h:     u32,
}

Single_Run_Result :: struct {
	cpu_us:    f64,
	presented: int,
	failed:    int,
	calls:     int,
}

// ============================================================================
// Darwin Native Helpers (QoS, Low Power Mode & Power Source)
// ============================================================================

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
	foreign import libobjc "system:objc"
	foreign import CoreFoundation "system:CoreFoundation.framework"
	foreign import IOKit "system:IOKit.framework"

	@(default_calling_convention="c")
	foreign libc {
		pthread_set_qos_class_self_np :: proc(qos_class: u32, relative_priority: i32) -> i32 ---
	}

	@(default_calling_convention="c")
	foreign libobjc {
		objc_getClass :: proc(name: cstring) -> rawptr ---
		sel_registerName :: proc(name: cstring) -> rawptr ---
		object_getClass :: proc(obj: rawptr) -> rawptr ---
		class_getMethodImplementation :: proc(cls: rawptr, name: rawptr) -> rawptr ---
	}

	@(default_calling_convention="c")
	foreign CoreFoundation {
		CFRelease :: proc(cf: rawptr) ---
		CFStringGetCString :: proc(theString: rawptr, buffer: [^]u8, bufferSize: int, encoding: u32) -> bool ---
	}

	@(default_calling_convention="c")
	foreign IOKit {
		IOPSCopyPowerSourcesInfo :: proc() -> rawptr ---
		IOPSGetProvidingPowerSourceType :: proc(blob: rawptr) -> rawptr ---
	}

	term_macos_set_user_interactive_qos :: proc() -> i32 {
		QOS_CLASS_USER_INTERACTIVE: u32 : 0x21
		return pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
	}

	term_macos_is_low_power_mode :: proc() -> i32 {
		cls := objc_getClass("NSProcessInfo")
		if cls == nil do return 0
		sel_proc := sel_registerName("processInfo")
		imp_proc := class_getMethodImplementation(object_getClass(cls), sel_proc)
		if imp_proc == nil do return 0
		Get_Proc :: #type proc "c" (cls: rawptr, sel: rawptr) -> rawptr
		proc_info := (Get_Proc(imp_proc))(cls, sel_proc)
		if proc_info == nil do return 0

		sel_lpm := sel_registerName("isLowPowerModeEnabled")
		imp_lpm := class_getMethodImplementation(object_getClass(proc_info), sel_lpm)
		if imp_lpm == nil do return 0
		Get_Bool :: #type proc "c" (target: rawptr, sel: rawptr) -> bool
		return 1 if (Get_Bool(imp_lpm))(proc_info, sel_lpm) else 0
	}

	term_macos_get_thermal_state :: proc() -> i32 {
		cls := objc_getClass("NSProcessInfo")
		if cls == nil do return 0
		sel_proc := sel_registerName("processInfo")
		imp_proc := class_getMethodImplementation(object_getClass(cls), sel_proc)
		if imp_proc == nil do return 0
		Get_Proc :: #type proc "c" (cls: rawptr, sel: rawptr) -> rawptr
		proc_info := (Get_Proc(imp_proc))(cls, sel_proc)
		if proc_info == nil do return 0

		sel_ts := sel_registerName("thermalState")
		imp_ts := class_getMethodImplementation(object_getClass(proc_info), sel_ts)
		if imp_ts == nil do return 0
		Get_Int :: #type proc "c" (target: rawptr, sel: rawptr) -> int
		return i32((Get_Int(imp_ts))(proc_info, sel_ts))
	}

	term_macos_get_power_source :: proc(buf: [^]u8, max_len: i32) {
		if buf == nil || max_len <= 0 do return
		buf[0] = 0
		blob := IOPSCopyPowerSourcesInfo()
		if blob != nil {
			defer CFRelease(blob)
			psType := IOPSGetProvidingPowerSourceType(blob)
			if psType != nil {
				kCFStringEncodingUTF8: u32 : 0x08000100
				CFStringGetCString(psType, buf, int(max_len), kCFStringEncodingUTF8)
			}
		}
		if buf[0] == 0 {
			unknown := "AC Power / Battery (Unknown)"
			n := min(int(max_len) - 1, len(unknown))
			for i in 0..<n {
				buf[i] = unknown[i]
			}
			buf[n] = 0
		}
	}
} else {
	term_macos_set_user_interactive_qos :: proc() -> i32 { return 0 }
	term_macos_is_low_power_mode :: proc() -> i32 { return 0 }
	term_macos_get_thermal_state :: proc() -> i32 { return 0 }
	term_macos_get_power_source :: proc(buf: [^]u8, max_len: i32) {
		if buf != nil && max_len > 0 do buf[0] = 0
	}
}

// ============================================================================
// WGPU Call Counting Wrappers (Verified Empirical Counter)
// ============================================================================

@(private = "file")
g_wgpu_call_counter: int = 0
@(private = "file")
g_hooks_installed: bool = false

@(private = "file")
g_orig_write_buffer: proc(queue: contract.Gpu_Queue, buffer: contract.Gpu_Buffer, offset: u64, data: rawptr, size: u64)
@(private = "file")
g_orig_render_set_pipeline: proc(pass: contract.Gpu_RenderPassEncoder, pipeline: contract.Gpu_RenderPipeline)
@(private = "file")
g_orig_render_set_bind_group: proc(pass: contract.Gpu_RenderPassEncoder, index: u32, group: contract.Gpu_BindGroup)
@(private = "file")
g_orig_render_draw: proc(pass: contract.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32)
@(private = "file")
g_orig_begin_render_pass: proc(encoder: contract.Gpu_CommandEncoder, color_view: contract.Gpu_TextureView, clear_color: [4]f64, load_op: contract.Gpu_Load_Op) -> contract.Gpu_RenderPassEncoder
@(private = "file")
g_orig_end_render_pass: proc(pass: contract.Gpu_RenderPassEncoder)

@(private = "file")
_hook_write_buffer :: proc(queue: contract.Gpu_Queue, buffer: contract.Gpu_Buffer, offset: u64, data: rawptr, size: u64) {
	g_wgpu_call_counter += 1
	g_orig_write_buffer(queue, buffer, offset, data, size)
}

@(private = "file")
_hook_render_set_pipeline :: proc(pass: contract.Gpu_RenderPassEncoder, pipeline: contract.Gpu_RenderPipeline) {
	g_wgpu_call_counter += 1
	g_orig_render_set_pipeline(pass, pipeline)
}

@(private = "file")
_hook_render_set_bind_group :: proc(pass: contract.Gpu_RenderPassEncoder, index: u32, group: contract.Gpu_BindGroup) {
	g_wgpu_call_counter += 1
	g_orig_render_set_bind_group(pass, index, group)
}

@(private = "file")
_hook_render_draw :: proc(pass: contract.Gpu_RenderPassEncoder, vertex_count: u32, instance_count: u32) {
	g_wgpu_call_counter += 1
	g_orig_render_draw(pass, vertex_count, instance_count)
}

@(private = "file")
_hook_begin_render_pass :: proc(encoder: contract.Gpu_CommandEncoder, color_view: contract.Gpu_TextureView, clear_color: [4]f64, load_op: contract.Gpu_Load_Op) -> contract.Gpu_RenderPassEncoder {
	g_wgpu_call_counter += 1
	return g_orig_begin_render_pass(encoder, color_view, clear_color, load_op)
}

@(private = "file")
_hook_end_render_pass :: proc(pass: contract.Gpu_RenderPassEncoder) {
	g_wgpu_call_counter += 1
	g_orig_end_render_pass(pass)
}

install_wgpu_call_counter_hooks :: proc() {
	if g_hooks_installed do return
	g_orig_write_buffer = contract.write_buffer
	g_orig_render_set_pipeline = contract.render_set_pipeline
	g_orig_render_set_bind_group = contract.render_set_bind_group
	g_orig_render_draw = contract.render_draw
	g_orig_begin_render_pass = contract.begin_render_pass
	g_orig_end_render_pass = contract.end_render_pass

	contract.write_buffer = _hook_write_buffer
	contract.render_set_pipeline = _hook_render_set_pipeline
	contract.render_set_bind_group = _hook_render_set_bind_group
	contract.render_draw = _hook_render_draw
	contract.begin_render_pass = _hook_begin_render_pass
	contract.end_render_pass = _hook_end_render_pass
	g_hooks_installed = true
}

// ============================================================================
// Machine Diagnostics & Environment Logging
// ============================================================================

Bench_Environment :: struct {
	os_str:        string,
	macos_version: string,
	cpu_brand:     string,
	logical_cpu:   int,
	physical_cpu:  int,
	mem_bytes:     u64,
	power_source:  string,
	low_power:     bool,
	thermal_state: string,
	thread_qos:    string,
	swapchain_res: string,
	surface_fmt:   string,
	refresh_rate:  f32,
	git_commit:    string,
	odin_ver:      string,
	wgpu_ver:      string,
	prng_seed:     string,
}

get_bench_environment :: proc(h: ^Harness_State, seed: u64) -> Bench_Environment {
	env: Bench_Environment
	env.git_commit = strings.trim(GIT_COMMIT, "\"")
	env.odin_ver = ODIN_VERSION
	env.wgpu_ver = strings.clone(fmt.tprintf("0x%08x", wgpu.GetVersion()))
	env.prng_seed = strings.clone(fmt.tprintf("0x%016x", seed))
	env.thread_qos = "User Interactive (QOS_CLASS_USER_INTERACTIVE)"
	env.swapchain_res = strings.clone(fmt.tprintf("%dx%d", int(h.screen_w), int(h.screen_h)))
	env.surface_fmt = strings.clone(fmt.tprintf("%v", h.format))

	when ODIN_OS == .Darwin {
		brand_buf: [256]u8
		ncpu: i32
		phys_cpu: i32
		memsize: u64
		os_ver_buf: [64]u8

		unix.sysctlbyname("machdep.cpu.brand_string", &brand_buf)
		unix.sysctlbyname("hw.ncpu", &ncpu)
		unix.sysctlbyname("hw.physicalcpu", &phys_cpu)
		unix.sysctlbyname("hw.memsize", &memsize)
		unix.sysctlbyname("kern.osproductversion", &os_ver_buf)

		brand_str := strings.truncate_to_byte(string(brand_buf[:]), 0)
		os_ver_str := strings.truncate_to_byte(string(os_ver_buf[:]), 0)
		env.cpu_brand = strings.clone(brand_str)
		env.macos_version = strings.clone(os_ver_str)
		env.os_str = strings.clone(fmt.tprintf("Darwin (macOS %s)", os_ver_str))
		env.logical_cpu = int(ncpu)
		env.physical_cpu = int(phys_cpu)
		env.mem_bytes = memsize

		ps_buf: [64]u8
		term_macos_get_power_source(raw_data(ps_buf[:]), 64)
		ps_str := strings.truncate_to_byte(string(ps_buf[:]), 0)
		env.power_source = strings.clone(ps_str)

		env.low_power = term_macos_is_low_power_mode() != 0
		ts := term_macos_get_thermal_state()
		switch ts {
		case 1: env.thermal_state = "Fair (1)"
		case 2: env.thermal_state = "Serious (2)"
		case 3: env.thermal_state = "Critical (3)"
		case:   env.thermal_state = "Nominal (0)"
		}

		display_id := sdl3.GetDisplayForWindow(h.window.handle)
		disp_mode := sdl3.GetCurrentDisplayMode(display_id)
		env.refresh_rate = disp_mode.refresh_rate if disp_mode != nil else 60.0
	} else {
		env.os_str = ODIN_OS
		env.macos_version = "N/A"
		env.cpu_brand = "Generic"
		env.logical_cpu = 1
		env.physical_cpu = 1
		env.mem_bytes = 0
		env.power_source = "AC Power"
		env.low_power = false
		env.thermal_state = "Nominal (0)"
		env.refresh_rate = 60.0
	}

	return env
}

log_machine_diagnostics :: proc(h: ^Harness_State, seed: u64) {
	env := get_bench_environment(h, seed)
	fmt.println("================================================================================")
	fmt.println("                     MACHINE DIAGNOSTICS & ENVIRONMENT                          ")
	fmt.println("================================================================================")
	fmt.printfln("OS:            %s", env.os_str)
	fmt.printfln("CPU Model:     %s", env.cpu_brand)
	fmt.printfln("Core Count:    %d logical cores (%d physical)", env.logical_cpu, env.physical_cpu)
	gib := f64(env.mem_bytes) / (1024.0 * 1024.0 * 1024.0)
	fmt.printfln("Memory:        %d bytes (%.2f GiB)", env.mem_bytes, gib)
	fmt.printfln("Power Source:  %s", env.power_source)
	fmt.printfln("Low Power:     %s", "ENABLED (Throttled)" if env.low_power else "Disabled (Full Performance)")
	fmt.printfln("Thermal State: %s", env.thermal_state)
	fmt.println("Thread QoS:    User Interactive (QOS_CLASS_USER_INTERACTIVE)")
	mp := (h.screen_w * h.screen_h) / 1_000_000.0
	fmt.printfln("Swapchain:     %d x %d physical pixels (%.2f Megapixels per layer)", int(h.screen_w), int(h.screen_h), mp)
	fmt.printfln("Surface Format: %s", env.surface_fmt)
	fmt.printfln("Refresh Rate:  %.1f Hz", env.refresh_rate)
	fmt.printfln("Git Commit:    %s", env.git_commit)
	fmt.printfln("Odin Version:  %s", env.odin_ver)
	fmt.printfln("wgpu Version:  %s", env.wgpu_ver)
	fmt.printfln("PRNG Seed:     %s", env.prng_seed)
	fmt.println("================================================================================")
	fmt.println()
}

// ============================================================================
// Hardware Timestamp Query Routines
// ============================================================================

_init_timestamp_query :: proc(h: ^Harness_State) {
	wgpu_dev := wgpu.Device(rawptr(h.device))
	wgpu_q := wgpu.Queue(rawptr(h.queue))
	if wgpu_dev == nil do return

	has_ts := wgpu.DeviceHasFeature(wgpu_dev, .TimestampQuery)
	if !has_ts do return

	qs_desc := wgpu.QuerySetDescriptor{
		type  = .Timestamp,
		count = 2,
	}
	h.ts_query_set = wgpu.DeviceCreateQuerySet(wgpu_dev, &qs_desc)
	if h.ts_query_set == nil do return

	resolve_desc := wgpu.BufferDescriptor{
		usage = { .QueryResolve, .CopySrc },
		size  = 2 * size_of(u64),
	}
	h.ts_resolve_buf = wgpu.DeviceCreateBuffer(wgpu_dev, &resolve_desc)

	readback_desc := wgpu.BufferDescriptor{
		usage = { .CopyDst, .MapRead },
		size  = 2 * size_of(u64),
	}
	h.ts_readback_buf = wgpu.DeviceCreateBuffer(wgpu_dev, &readback_desc)

	h.ts_supported = (h.ts_resolve_buf != nil && h.ts_readback_buf != nil)
	if h.ts_supported {
		h.ts_period = wgpu.QueueGetTimestampPeriod(wgpu_q)
		if h.ts_period <= 0.0 {
			h.ts_period = 1.0
		}
	}
}

_destroy_timestamp_query :: proc(h: ^Harness_State) {
	if h.ts_query_set != nil {
		wgpu.QuerySetRelease(h.ts_query_set)
		h.ts_query_set = nil
	}
	if h.ts_resolve_buf != nil {
		wgpu.BufferRelease(h.ts_resolve_buf)
		h.ts_resolve_buf = nil
	}
	if h.ts_readback_buf != nil {
		wgpu.BufferRelease(h.ts_readback_buf)
		h.ts_readback_buf = nil
	}
	h.ts_supported = false
}

_emit_timestamp_query :: proc(h: ^Harness_State, query_idx: u32, view: contract.Gpu_TextureView) -> rawptr {
	if !h.ts_supported || rawptr(view) == nil do return nil
	wgpu_dev := wgpu.Device(rawptr(h.device))
	enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
	if enc == nil do return nil

	ts_writes := wgpu.PassTimestampWrites{
		querySet                  = h.ts_query_set,
		beginningOfPassWriteIndex = query_idx,
		endOfPassWriteIndex       = wgpu.QUERY_SET_INDEX_UNDEFINED,
	}
	color_att := [1]wgpu.RenderPassColorAttachment{
		{
			view       = wgpu.TextureView(rawptr(view)),
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Load,
			storeOp    = .Store,
		},
	}
	pass_desc := wgpu.RenderPassDescriptor{
		colorAttachmentCount = 1,
		colorAttachments     = raw_data(color_att[:]),
		timestampWrites      = &ts_writes,
	}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &pass_desc)
	if pass != nil {
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	return rawptr(cmd)
}

_resolve_and_copy_timestamps :: proc(h: ^Harness_State) -> rawptr {
	if !h.ts_supported do return nil
	wgpu_dev := wgpu.Device(rawptr(h.device))
	enc := wgpu.DeviceCreateCommandEncoder(wgpu_dev, nil)
	if enc == nil do return nil

	wgpu.CommandEncoderResolveQuerySet(enc, h.ts_query_set, 0, 2, h.ts_resolve_buf, 0)
	wgpu.CommandEncoderCopyBufferToBuffer(enc, h.ts_resolve_buf, 0, h.ts_readback_buf, 0, 2 * size_of(u64))
	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.CommandEncoderRelease(enc)
	return rawptr(cmd)
}

_read_gpu_timestamp_duration :: proc(h: ^Harness_State) -> u64 {
	if !h.ts_supported do return 0
	wgpu_inst := wgpu.Instance(h.instance)
	wgpu_dev := wgpu.Device(rawptr(h.device))

	_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		done := (^bool)(userdata2)
		if done != nil do done^ = true
	}

	done := false
	_ = wgpu.BufferMapAsync(
		h.ts_readback_buf,
		{ .Read },
		0,
		2 * size_of(u64),
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map,
			userdata2 = &done,
		},
	)

	for !done {
		wgpu.InstanceProcessEvents(wgpu_inst)
		wgpu.DevicePoll(wgpu_dev, true, nil)
	}

	ptr := wgpu.RawBufferGetConstMappedRange(h.ts_readback_buf, 0, 2 * size_of(u64))
	if ptr == nil {
		wgpu.BufferUnmap(h.ts_readback_buf)
		return 0
	}
	ts := ([^]u64)(ptr)
	diff: u64 = 0
	if ts[1] > ts[0] {
		raw_ticks := ts[1] - ts[0]
		period := f64(h.ts_period)
		if period <= 0.0 do period = 1.0
		diff = u64(f64(raw_ticks) * period)
	}
	wgpu.BufferUnmap(h.ts_readback_buf)
	return diff
}

// ============================================================================
// Pre-Filling Layers (No Raster Invariant)
// ============================================================================

prefill_backing_layers :: proc(h: ^Harness_State, w, h_pixels: u32) -> bool {
	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false

	for i in 0..<layer.MAX_COMPOSER_LAYERS {
		id := LAYER_IDS[i]
		layer_ptr, ok := pipeline.composer_pipeline_acquire_layer(
			&h.composer_pipe,
			id,
			.Overlay,
			w,
			h_pixels,
			false,
		)
		if !ok || layer_ptr == nil {
			contract.release_command_encoder(enc)
			return false
		}

		color := LAYER_PALETTE[i]
		pass := contract.begin_render_pass(enc, layer_ptr.view, color, .Clear)
		if rawptr(pass) == nil {
			contract.release_command_encoder(enc)
			return false
		}
		contract.end_render_pass(pass)

		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, id)
	}

	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd == nil do return false

	contract.submit(h.queue, cmd)
	contract.release_command_buffer(cmd)
	contract.wait_for_idle(h.device)

	return true
}

// ============================================================================
// Correctness Suite
// ============================================================================

run_correctness_suite :: proc(h: ^Harness_State) -> bool {
	fmt.println("================================================================================")
	fmt.println("                           CORRECTNESS SUITE                                    ")
	fmt.println("================================================================================")

	all_passed := true

	// Test 1: Layer Ordering & 1-Pixel Readback Verification
	test1_ok := _test_layer_order_and_readback(h)
	if test1_ok {
		fmt.println("[PASS] Test 1: Layer Order & 1-Pixel Readback (Back-to-front composite invariant)")
	} else {
		fmt.println("[FAIL] Test 1: Layer Order & 1-Pixel Readback")
		all_passed = false
	}

	// Test 2: MAX Layer Pool Capacity (Boundary Check)
	test2_ok := _test_max_layer_capacity(h)
	if test2_ok {
		fmt.println("[PASS] Test 2: MAX Layer Capacity Boundary Check (Acquire ID 17 returns nil, false)")
	} else {
		fmt.println("[FAIL] Test 2: MAX Layer Capacity Boundary Check")
		all_passed = false
	}

	// Test 3: Presented Count & Composite Success Rate
	test3_ok := _test_presented_and_composite_success(h)
	if test3_ok {
		fmt.println("[PASS] Test 3: Presented Count & Composite Success (10/10 frames presented, 0 failures)")
	} else {
		fmt.println("[FAIL] Test 3: Presented Count & Composite Success")
		all_passed = false
	}

	// Test 4: Straight Alpha Blending 1-Pixel Readback
	test4_ok := _test_straight_alpha_blending_readback(h)
	if test4_ok {
		fmt.println("[PASS] Test 4: Straight Alpha Blending Readback (C_blend = C_src*a + C_dst*(1-a) ± 4 tolerance)")
	} else {
		fmt.println("[FAIL] Test 4: Straight Alpha Blending Readback")
		all_passed = false
	}

	// Test 5: Moving Quad Spatial Transition Readback
	test5_ok := _test_moving_quad_transition_readback(h)
	if test5_ok {
		fmt.println("[PASS] Test 5: Moving Quad Spatial Transition (Discrete integer pixel position coverage)")
	} else {
		fmt.println("[FAIL] Test 5: Moving Quad Spatial Transition")
		all_passed = false
	}

	// Test 6: Extreme Scissor Bounds Safety
	test6_ok := _test_extreme_scissor_bounds(h)
	if test6_ok {
		fmt.println("[PASS] Test 6: Extreme Scissor Bounds Safety (Negative, out-of-bounds, zero dims clamped)")
	} else {
		fmt.println("[FAIL] Test 6: Extreme Scissor Bounds Safety")
		all_passed = false
	}

	// Test 7: Full-Texture Pixel Readback Equivalence (Partial Load vs Full Clear)
	test7_ok := _test_partial_vs_full_pixel_equivalence(h)
	if test7_ok {
		fmt.println("[PASS] Test 7: Strategy A Partial vs Full Pixel Equivalence (25,600 pixels byte-for-byte match)")
	} else {
		fmt.println("[FAIL] Test 7: Strategy A Partial vs Full Pixel Equivalence")
		all_passed = false
	}

	// Test 8: Negative Ghosting Test (Deliberate un-erased bug detected by pixel diff)
	test8_ok := _test_partial_negative_ghosting_detection(h)
	if test8_ok {
		fmt.println("[PASS] Test 8: Negative Ghosting Test (Deliberate un-erased bug detected by pixel diff)")
	} else {
		fmt.println("[FAIL] Test 8: Negative Ghosting Test")
		all_passed = false
	}

	fmt.println("--------------------------------------------------------------------------------")
	if all_passed {
		fmt.println("Correctness Suite Result: PASS (All invariants verified)")
	} else {
		fmt.println("Correctness Suite Result: FAIL (One or more invariant checks failed)")
	}
	fmt.println("================================================================================")
	fmt.println()

	return all_passed
}

@(private = "file")
_readback_one_pixel :: proc(
	h: ^Harness_State,
	target_tex: contract.Gpu_Texture,
	x, y: u32,
) -> (r, g, b, a: u8, ok: bool) {
	wgpu_inst := wgpu.Instance(h.instance)
	wgpu_dev := wgpu.Device(rawptr(h.device))
	if wgpu_dev == nil do return 0, 0, 0, 0, false

	staging_buf := wgpu.DeviceCreateBuffer(wgpu_dev, &wgpu.BufferDescriptor{
		usage = { .CopyDst, .MapRead },
		size  = 256,
	})
	if staging_buf == nil do return 0, 0, 0, 0, false
	defer wgpu.BufferRelease(staging_buf)

	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return 0, 0, 0, 0, false

	src_info := wgpu.TexelCopyTextureInfo{
		texture  = wgpu.Texture(rawptr(target_tex)),
		mipLevel = 0,
		origin   = { x = x, y = y, z = 0 },
		aspect   = .All,
	}
	dst_info := wgpu.TexelCopyBufferInfo{
		layout = {
			offset       = 0,
			bytesPerRow  = 256,
			rowsPerImage = 1,
		},
		buffer = staging_buf,
	}
	copy_size := wgpu.Extent3D{
		width              = 1,
		height             = 1,
		depthOrArrayLayers = 1,
	}
	wgpu.CommandEncoderCopyTextureToBuffer(wgpu.CommandEncoder(rawptr(enc)), &src_info, &dst_info, &copy_size)

	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd == nil do return 0, 0, 0, 0, false

	contract.submit(h.queue, cmd)
	contract.release_command_buffer(cmd)

	_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		done := (^bool)(userdata2)
		if done != nil do done^ = true
	}

	done := false
	_ = wgpu.BufferMapAsync(
		staging_buf,
		{ .Read },
		0,
		256,
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map,
			userdata2 = &done,
		},
	)
	for !done {
		wgpu.InstanceProcessEvents(wgpu_inst)
		wgpu.DevicePoll(wgpu_dev, true, nil)
	}

	ptr := wgpu.RawBufferGetConstMappedRange(staging_buf, 0, 256)
	if ptr == nil {
		wgpu.BufferUnmap(staging_buf)
		return 0, 0, 0, 0, false
	}
	px := ([^]u8)(ptr)
	p0 := px[0]
	p1 := px[1]
	p2 := px[2]
	p3 := px[3]
	wgpu.BufferUnmap(staging_buf)

	if h.format == .BGRA8_Unorm {
		return p2, p1, p0, p3, true
	} else {
		return p0, p1, p2, p3, true
	}
}

@(private = "file")
_test_layer_order_and_readback :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 64
	target_h: u32 = 64

	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	target_tex := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(target_tex) == nil do return false
	defer contract.destroy_texture(target_tex)

	target_view := contract.create_texture_view(target_tex)
	if rawptr(target_view) == nil do return false
	defer contract.destroy_texture_view(target_view)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	test_ids := [3]composer.Layer_Id{1, 2, 3}
	for id in test_ids {
		l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
		if l != nil {
			l.dest_rect = composer.rect_make(0, 0, f32(target_w), f32(target_h))
			l.scissor_rect = l.dest_rect
			l.opacity = 1.0
			l.corner_radius = 0.0
		}
	}

	// 1. Order A, B, C -> Blue on top
	order_blue_top := [3]composer.Layer_Id{1, 2, 3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_blue_top[:])

	enc1 := contract.create_command_encoder(h.device)
	if rawptr(enc1) == nil do return false
	if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc1, target_view) {
		contract.release_command_encoder(enc1)
		return false
	}
	cmd1 := contract.finish_command_buffer(enc1)
	contract.release_command_encoder(enc1)
	contract.submit(h.queue, cmd1)
	contract.release_command_buffer(cmd1)

	r1, _, b1, _, ok1 := _readback_one_pixel(h, target_tex, 32, 32)
	if !ok1 do return false
	if !(b1 > 180 && r1 < 100) do return false

	// 2. Reverse order C, B, A -> Red on top
	order_red_top := [3]composer.Layer_Id{3, 2, 1}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_red_top[:])

	enc2 := contract.create_command_encoder(h.device)
	if rawptr(enc2) == nil do return false
	if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc2, target_view) {
		contract.release_command_encoder(enc2)
		return false
	}
	cmd2 := contract.finish_command_buffer(enc2)
	contract.release_command_encoder(enc2)
	contract.submit(h.queue, cmd2)
	contract.release_command_buffer(cmd2)

	r2, _, b2, _, ok2 := _readback_one_pixel(h, target_tex, 32, 32)
	if !ok2 do return false
	return (r2 > 180 && b2 < 100)
}

@(private = "file")
_test_straight_alpha_blending_readback :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 64
	target_h: u32 = 64
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	target_tex := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(target_tex) == nil do return false
	defer contract.destroy_texture(target_tex)

	target_view := contract.create_texture_view(target_tex)
	if rawptr(target_view) == nil do return false
	defer contract.destroy_texture_view(target_view)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	// Layer 1: Red (0.85, 0.15, 0.15, 1.0) @ opacity 1.0
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 1)
	if l1 == nil do return false
	l1.dest_rect = composer.rect_make(0, 0, f32(target_w), f32(target_h))
	l1.scissor_rect = l1.dest_rect
	l1.opacity = 1.0
	l1.corner_radius = 0.0

	// Layer 3: Blue (0.20, 0.40, 0.90, 1.0) @ opacity 0.5
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 3)
	if l3 == nil do return false
	l3.dest_rect = composer.rect_make(0, 0, f32(target_w), f32(target_h))
	l3.scissor_rect = l3.dest_rect
	l3.opacity = 0.5
	l3.corner_radius = 0.0

	order := [2]composer.Layer_Id{1, 3} // Red on bottom, Blue on top
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:])

	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false
	if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc, target_view) {
		contract.release_command_encoder(enc)
		return false
	}
	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	contract.submit(h.queue, cmd)
	contract.release_command_buffer(cmd)

	r, g, b, _, ok := _readback_one_pixel(h, target_tex, 32, 32)
	if !ok do return false

	// Straight Alpha formula: C_blend = C_src * alpha + C_dst * (1 - alpha)
	// Red (Dst): (0.85, 0.15, 0.15), Blue (Src): (0.20, 0.40, 0.90), alpha = 0.5
	// Exp R: 0.20 * 0.5 + 0.85 * 0.5 = 0.525 -> round(0.525 * 255) = 134
	// Exp G: 0.40 * 0.5 + 0.15 * 0.5 = 0.275 -> round(0.275 * 255) = 70
	// Exp B: 0.90 * 0.5 + 0.15 * 0.5 = 0.525 -> round(0.525 * 255) = 134
	exp_r := 134
	exp_g := 70
	exp_b := 134

	tol := 4
	ok_r := abs(int(r) - exp_r) <= tol
	ok_g := abs(int(g) - exp_g) <= tol
	ok_b := abs(int(b) - exp_b) <= tol

	return ok_r && ok_g && ok_b
}

@(private = "file")
_test_moving_quad_transition_readback :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 100
	target_h: u32 = 100
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	target_tex := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(target_tex) == nil do return false
	defer contract.destroy_texture(target_tex)

	target_view := contract.create_texture_view(target_tex)
	if rawptr(target_view) == nil do return false
	defer contract.destroy_texture_view(target_view)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	// Layer 1: Red background fullscreen
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 1)
	if l1 == nil do return false
	l1.dest_rect = composer.rect_make(0, 0, f32(target_w), f32(target_h))
	l1.scissor_rect = l1.dest_rect
	l1.opacity = 1.0

	// Layer 3: Blue moving popup (40x40)
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 3)
	if l3 == nil do return false
	l3.opacity = 1.0

	order := [2]composer.Layer_Id{1, 3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:])

	// Step A: popup at (0, 0, 40, 40). Sample point (60, 60) is Red!
	l3.dest_rect = composer.rect_make(0, 0, 40, 40)
	l3.scissor_rect = l3.dest_rect

	enc1 := contract.create_command_encoder(h.device)
	if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc1, target_view) {
		contract.release_command_encoder(enc1)
		return false
	}
	cmd1 := contract.finish_command_buffer(enc1)
	contract.release_command_encoder(enc1)
	contract.submit(h.queue, cmd1)
	contract.release_command_buffer(cmd1)

	r1, _, b1, _, ok1 := _readback_one_pixel(h, target_tex, 60, 60)
	if !ok1 do return false
	is_red := (int(r1) > 180 && int(b1) < 100)

	// Step B: popup moved to (40, 40, 40, 40). Sample point (60, 60) is now Blue!
	l3.dest_rect = composer.rect_make(40, 40, 40, 40)
	l3.scissor_rect = l3.dest_rect

	enc2 := contract.create_command_encoder(h.device)
	if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc2, target_view) {
		contract.release_command_encoder(enc2)
		return false
	}
	cmd2 := contract.finish_command_buffer(enc2)
	contract.release_command_encoder(enc2)
	contract.submit(h.queue, cmd2)
	contract.release_command_buffer(cmd2)

	r2, _, b2, _, ok2 := _readback_one_pixel(h, target_tex, 60, 60)
	if !ok2 do return false
	is_blue := (int(b2) > 180 && int(r2) < 100)

	return is_red && is_blue
}

@(private = "file")
_test_extreme_scissor_bounds :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 64
	target_h: u32 = 64
	tex_usage := contract.Gpu_Texture_Usage.Render_Attach
	target_tex := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(target_tex) == nil do return false
	defer contract.destroy_texture(target_tex)

	target_view := contract.create_texture_view(target_tex)
	if rawptr(target_view) == nil do return false
	defer contract.destroy_texture_view(target_view)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 1)
	if l1 == nil do return false
	l1.dest_rect = composer.rect_make(0, 0, f32(target_w), f32(target_h))
	l1.opacity = 1.0

	order := [1]composer.Layer_Id{1}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:])

	extreme_scissors := [3]composer.Composer_Rect{
		composer.rect_make(-100.0, -100.0, 50.0, 50.0),
		composer.rect_make(5000.0, 5000.0, 2000.0, 2000.0),
		composer.rect_make(0.0, 0.0, 0.0, 0.0),
	}

	for sc in extreme_scissors {
		l1.scissor_rect = sc
		enc := contract.create_command_encoder(h.device)
		if rawptr(enc) == nil do return false
		if !pipeline.composer_pipeline_composite(&h.composer_pipe, enc, target_view) {
			contract.release_command_encoder(enc)
			return false
		}
		cmd := contract.finish_command_buffer(enc)
		contract.release_command_encoder(enc)
		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
		}
	}
	contract.wait_for_idle(h.device)
	return true
}

@(private = "file")
_readback_texture_rect :: proc(
	h: ^Harness_State,
	target_tex: contract.Gpu_Texture,
	w, h_pixels: u32,
	out_buf: []u8,
) -> bool {
	wgpu_inst := wgpu.Instance(h.instance)
	wgpu_dev := wgpu.Device(rawptr(h.device))
	if wgpu_dev == nil do return false

	bytes_per_row := ((w * 4 + 255) / 256) * 256
	staging_size := u64(bytes_per_row * h_pixels)

	staging_buf := wgpu.DeviceCreateBuffer(wgpu_dev, &wgpu.BufferDescriptor{
		usage = { .CopyDst, .MapRead },
		size  = staging_size,
	})
	if staging_buf == nil do return false
	defer wgpu.BufferRelease(staging_buf)

	enc := contract.create_command_encoder(h.device)
	if rawptr(enc) == nil do return false

	src_info := wgpu.TexelCopyTextureInfo{
		texture  = wgpu.Texture(rawptr(target_tex)),
		mipLevel = 0,
		origin   = { x = 0, y = 0, z = 0 },
		aspect   = .All,
	}
	dst_info := wgpu.TexelCopyBufferInfo{
		layout = {
			offset       = 0,
			bytesPerRow  = bytes_per_row,
			rowsPerImage = h_pixels,
		},
		buffer = staging_buf,
	}
	copy_size := wgpu.Extent3D{
		width              = w,
		height             = h_pixels,
		depthOrArrayLayers = 1,
	}
	wgpu.CommandEncoderCopyTextureToBuffer(wgpu.CommandEncoder(rawptr(enc)), &src_info, &dst_info, &copy_size)

	cmd := contract.finish_command_buffer(enc)
	contract.release_command_encoder(enc)
	if cmd == nil do return false

	contract.submit(h.queue, cmd)
	contract.release_command_buffer(cmd)

	_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1: rawptr, userdata2: rawptr) {
		done := (^bool)(userdata2)
		if done != nil do done^ = true
	}

	done := false
	_ = wgpu.BufferMapAsync(
		staging_buf,
		{ .Read },
		0,
		uint(staging_size),
		wgpu.BufferMapCallbackInfo{
			mode      = .AllowProcessEvents,
			callback  = _on_map,
			userdata2 = &done,
		},
	)
	for !done {
		wgpu.InstanceProcessEvents(wgpu_inst)
		wgpu.DevicePoll(wgpu_dev, true, nil)
	}

	ptr := wgpu.RawBufferGetConstMappedRange(staging_buf, 0, uint(staging_size))
	if ptr == nil {
		wgpu.BufferUnmap(staging_buf)
		return false
	}
	src_ptr := ([^]u8)(ptr)
	row_bytes := int(w * 4)

	for y in 0..<int(h_pixels) {
		src_row := src_ptr[y * int(bytes_per_row) :]
		dst_row := out_buf[y * row_bytes : (y + 1) * row_bytes]
		copy(dst_row, src_row[:row_bytes])
	}

	wgpu.BufferUnmap(staging_buf)
	return true
}

@(private = "file")
_test_partial_vs_full_pixel_equivalence :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 160
	target_h: u32 = 160
	pixels_count := int(target_w * target_h * 4)

	buf_a := make([]u8, pixels_count)
	buf_b := make([]u8, pixels_count)
	defer delete(buf_a)
	defer delete(buf_b)

	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	tex_a := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	tex_b := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(tex_a) == nil || rawptr(tex_b) == nil do return false
	defer contract.destroy_texture(tex_a)
	defer contract.destroy_texture(tex_b)

	view_a := contract.create_texture_view(tex_a)
	view_b := contract.create_texture_view(tex_b)
	if rawptr(view_a) == nil || rawptr(view_b) == nil do return false
	defer contract.destroy_texture_view(view_a)
	defer contract.destroy_texture_view(view_b)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	saved_clear := h.composer_pipe.clear_color
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		h.composer_pipe.clear_color = saved_clear
		pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	// Layer 1 is Red (theme default background)
	l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 1)
	// Layer 3 is Blue (text / foreground)
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 3)
	// Layer 5 is Purple (selection highlight)
	l5 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 5)
	if l1 == nil || l3 == nil || l5 == nil do return false

	l1.opacity = 1.0; l1.corner_radius = 0.0
	l3.opacity = 1.0; l3.corner_radius = 0.0
	l5.opacity = 1.0; l5.corner_radius = 0.0

	// 1. Initial State: Clear both textures to Red
	h.composer_pipe.clear_color = LAYER_PALETTE[0] // Red
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	order_empty := [0]composer.Layer_Id{}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_empty[:])

	enc_init := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_init, view_a)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_init, view_b)
	cmd_init := contract.finish_command_buffer(enc_init)
	contract.release_command_encoder(enc_init)
	contract.submit(h.queue, cmd_init)
	contract.release_command_buffer(cmd_init)

	// Step 1: Type text at x=16, y=16, w=48, h=16
	// Texture A: Partial_Load with scissor
	l3.dest_rect = composer.rect_make(16, 16, 48, 16)
	l3.scissor_rect = l3.dest_rect
	order_step1 := [1]composer.Layer_Id{3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step1[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Load)
	enc1 := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc1, view_a)
	cmd1 := contract.finish_command_buffer(enc1)
	contract.release_command_encoder(enc1)
	contract.submit(h.queue, cmd1)
	contract.release_command_buffer(cmd1)

	// Texture B: Full_Clear
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	enc1_b := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc1_b, view_b)
	cmd1_b := contract.finish_command_buffer(enc1_b)
	contract.release_command_encoder(enc1_b)
	contract.submit(h.queue, cmd1_b)
	contract.release_command_buffer(cmd1_b)

	// Verify Step 1: byte-for-byte readback match
	if !_readback_texture_rect(h, tex_a, target_w, target_h, buf_a) do return false
	if !_readback_texture_rect(h, tex_b, target_w, target_h, buf_b) do return false
	for i in 0..<pixels_count {
		if buf_a[i] != buf_b[i] do return false
	}

	// Step 2: Backspace last 16px (x=48..64)
	// Texture A: Partial_Load - overwrite erased area with Layer 1 (Red default bg)
	l1.dest_rect = composer.rect_make(48, 16, 16, 16)
	l1.scissor_rect = l1.dest_rect
	order_step2 := [1]composer.Layer_Id{1}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step2[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Load)
	enc2 := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc2, view_a)
	cmd2 := contract.finish_command_buffer(enc2)
	contract.release_command_encoder(enc2)
	contract.submit(h.queue, cmd2)
	contract.release_command_buffer(cmd2)

	// Texture B: Full_Clear - render remaining text (w=32) from scratch
	l3.dest_rect = composer.rect_make(16, 16, 32, 16)
	l3.scissor_rect = l3.dest_rect
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step1[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	enc2_b := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc2_b, view_b)
	cmd2_b := contract.finish_command_buffer(enc2_b)
	contract.release_command_encoder(enc2_b)
	contract.submit(h.queue, cmd2_b)
	contract.release_command_buffer(cmd2_b)

	// Verify Step 2: Backspace erased old pixels with 0 ghosting!
	if !_readback_texture_rect(h, tex_a, target_w, target_h, buf_a) do return false
	if !_readback_texture_rect(h, tex_b, target_w, target_h, buf_b) do return false
	for i in 0..<pixels_count {
		if buf_a[i] != buf_b[i] do return false
	}

	// Step 3: Selection Highlight (x=16..32, Purple Layer 5)
	l5.dest_rect = composer.rect_make(16, 16, 16, 16)
	l5.scissor_rect = l5.dest_rect
	order_step3 := [1]composer.Layer_Id{5}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step3[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Load)
	enc3 := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc3, view_a)
	cmd3 := contract.finish_command_buffer(enc3)
	contract.release_command_encoder(enc3)
	contract.submit(h.queue, cmd3)
	contract.release_command_buffer(cmd3)

	// Texture B: Full_Clear with text + selection
	order_step3_b := [2]composer.Layer_Id{3, 5}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step3_b[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	enc3_b := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc3_b, view_b)
	cmd3_b := contract.finish_command_buffer(enc3_b)
	contract.release_command_encoder(enc3_b)
	contract.submit(h.queue, cmd3_b)
	contract.release_command_buffer(cmd3_b)

	if !_readback_texture_rect(h, tex_a, target_w, target_h, buf_a) do return false
	if !_readback_texture_rect(h, tex_b, target_w, target_h, buf_b) do return false
	for i in 0..<pixels_count {
		if buf_a[i] != buf_b[i] do return false
	}

	// Step 4: Clear Selection (revert to Blue text on Red background)
	// Texture A: Partial_Load - overwrite with Red bg then Blue text
	l1.dest_rect = composer.rect_make(16, 16, 16, 16)
	l1.scissor_rect = l1.dest_rect
	l3.dest_rect = composer.rect_make(16, 16, 16, 16)
	l3.scissor_rect = l3.dest_rect
	order_step4 := [2]composer.Layer_Id{1, 3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step4[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Load)
	enc4 := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc4, view_a)
	cmd4 := contract.finish_command_buffer(enc4)
	contract.release_command_encoder(enc4)
	contract.submit(h.queue, cmd4)
	contract.release_command_buffer(cmd4)

	// Texture B: Full_Clear
	l3.dest_rect = composer.rect_make(16, 16, 32, 16)
	l3.scissor_rect = l3.dest_rect
	order_step4_b := [1]composer.Layer_Id{3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_step4_b[:])
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	enc4_b := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc4_b, view_b)
	cmd4_b := contract.finish_command_buffer(enc4_b)
	contract.release_command_encoder(enc4_b)
	contract.submit(h.queue, cmd4_b)
	contract.release_command_buffer(cmd4_b)

	if !_readback_texture_rect(h, tex_a, target_w, target_h, buf_a) do return false
	if !_readback_texture_rect(h, tex_b, target_w, target_h, buf_b) do return false
	for i in 0..<pixels_count {
		if buf_a[i] != buf_b[i] do return false
	}

	return true
}

@(private = "file")
_test_partial_negative_ghosting_detection :: proc(h: ^Harness_State) -> bool {
	target_w: u32 = 160
	target_h: u32 = 160
	pixels_count := int(target_w * target_h * 4)

	buf_a := make([]u8, pixels_count)
	buf_b := make([]u8, pixels_count)
	defer delete(buf_a)
	defer delete(buf_b)

	tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
	tex_a := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	tex_b := contract.create_texture(h.device, target_w, target_h, h.format, tex_usage)
	if rawptr(tex_a) == nil || rawptr(tex_b) == nil do return false
	defer contract.destroy_texture(tex_a)
	defer contract.destroy_texture(tex_b)

	view_a := contract.create_texture_view(tex_a)
	view_b := contract.create_texture_view(tex_b)
	if rawptr(view_a) == nil || rawptr(view_b) == nil do return false
	defer contract.destroy_texture_view(view_a)
	defer contract.destroy_texture_view(view_b)

	saved_w := h.composer_pipe.screen_w
	saved_h := h.composer_pipe.screen_h
	saved_order := h.composer_pipe.layer_order
	saved_count := h.composer_pipe.layer_count
	saved_clear := h.composer_pipe.clear_color
	defer {
		pipeline.composer_pipeline_resize(&h.composer_pipe, saved_w, saved_h)
		pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, saved_order[:saved_count])
		h.composer_pipe.clear_color = saved_clear
		pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
		_restore_default_layers(h)
	}

	pipeline.composer_pipeline_resize(&h.composer_pipe, f32(target_w), f32(target_h))

	// Layer 3 (Blue text) initially drawn on both A and B
	l3 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, 3)
	if l3 == nil do return false
	l3.dest_rect = composer.rect_make(16, 16, 48, 16)
	l3.scissor_rect = l3.dest_rect
	l3.opacity = 1.0; l3.corner_radius = 0.0

	h.composer_pipe.clear_color = LAYER_PALETTE[0] // Red
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	order_txt := [1]composer.Layer_Id{3}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_txt[:])

	enc_init := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_init, view_a)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_init, view_b)
	cmd_init := contract.finish_command_buffer(enc_init)
	contract.release_command_encoder(enc_init)
	contract.submit(h.queue, cmd_init)
	contract.release_command_buffer(cmd_init)

	// NOW SIMULATE GHOSTING BUG on Texture A:
	// A character is backspaced (deleted), BUT the background overwrite quad is deliberately OMITTED.
	// In Texture A: we do .Load with empty draw (simulating space emitting nothing)
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Load)
	order_empty := [0]composer.Layer_Id{}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_empty[:])
	enc_bug := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_bug, view_a)
	cmd_bug := contract.finish_command_buffer(enc_bug)
	contract.release_command_encoder(enc_bug)
	contract.submit(h.queue, cmd_bug)
	contract.release_command_buffer(cmd_bug)

	// On Texture B: the correct backspaced state is rendered (text shortened to 32px on clean Red background)
	l3.dest_rect = composer.rect_make(16, 16, 32, 16)
	l3.scissor_rect = l3.dest_rect
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order_txt[:])
	enc_correct := contract.create_command_encoder(h.device)
	_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc_correct, view_b)
	cmd_correct := contract.finish_command_buffer(enc_correct)
	contract.release_command_encoder(enc_correct)
	contract.submit(h.queue, cmd_correct)
	contract.release_command_buffer(cmd_correct)

	// Readback and count ghost pixels
	if !_readback_texture_rect(h, tex_a, target_w, target_h, buf_a) do return false
	if !_readback_texture_rect(h, tex_b, target_w, target_h, buf_b) do return false

	ghost_diff_count := 0
	for i in 0..<pixels_count {
		if buf_a[i] != buf_b[i] {
			ghost_diff_count += 1
		}
	}

	// The negative test PASSES iff ghost pixels WERE detected!
	// (Proves the test suite is capable of catching un-erased ghost pixels)
	return ghost_diff_count > 0
}

@(private = "file")
_test_max_layer_capacity :: proc(h: ^Harness_State) -> bool {
	// Pool is currently full with 16 layers. Try acquiring 17th layer ID (999)
	layer_17, ok := pipeline.composer_pipeline_acquire_layer(
		&h.composer_pipe,
		999,
		.Overlay,
		100,
		100,
		false,
	)
	if ok || layer_17 != nil {
		return false
	}

	// Verify existing 16 layers are still intact
	for id in LAYER_IDS {
		l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
		if l == nil || !l.in_use {
			return false
		}
	}

	return true
}

_pump_events :: proc() {
	event: sdl3.Event
	for sdl3.PollEvent(&event) {}
}

_acquire_surface :: proc(h: ^Harness_State) -> (contract.Gpu_Texture, contract.Gpu_TextureView) {
	for attempt in 0..<10 {
		surf := (^wgpu_backend.Wgpu_Surface)(h.surface)
		if surf != nil && surf.handle != nil {
			st := wgpu.SurfaceGetCurrentTexture(surf.handle)
			if st.status == .SuccessOptimal || st.status == .SuccessSuboptimal || st.status == .Occluded {
				if st.texture != nil {
					tv := wgpu.TextureCreateView(st.texture, nil)
					if tv != nil {
						return contract.Gpu_Texture(st.texture), contract.Gpu_TextureView(tv)
					}
				}
			} else {
				fmt.printfln("DEBUG: attempt %d st.status=%v (texture=%v)", attempt, st.status, st.texture)
			}
		}
		_pump_events()
		if h.window.handle != nil {
			sdl3.RaiseWindow(h.window.handle)
		}
		plat_win.window_update_pixel_size(&h.window)
		h.screen_w = f32(h.window.pixel_w)
		h.screen_h = f32(h.window.pixel_h)
		contract.configure_surface(h.surface, h.device, h.format, u32(h.screen_w), u32(h.screen_h))
		contract.poll_device(h.device, true)
	}
	return contract.Gpu_Texture(nil), contract.Gpu_TextureView(nil)
}

@(private = "file")
_test_presented_and_composite_success :: proc(h: ^Harness_State) -> bool {
	presented_count := 0
	failed_composite := 0
	frames_to_test := 10

	for f in 0..<frames_to_test {
		_pump_events()

		tex, view := _acquire_surface(h)
		if rawptr(view) == nil do return false

		pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		enc := contract.create_command_encoder(h.device)
		if rawptr(enc) == nil do return false

		ok := pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view)
		if !ok do failed_composite += 1

		cmd := contract.finish_command_buffer(enc)
		contract.release_command_encoder(enc)

		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
		}

		if contract.present_surface(h.surface) {
			presented_count += 1
		}
		contract.release_surface_texture(tex, view)

		pipeline.composer_pipeline_end_frame(&h.composer_pipe)
	}

	return presented_count == frames_to_test && failed_composite == 0
}

// ============================================================================
// Lifecycle Benchmark
// ============================================================================

run_lifecycle_benchmark :: proc(h: ^Harness_State) {
	fmt.println("================================================================================")
	fmt.println("                           LIFECYCLE BENCHMARK                                  ")
	fmt.println("================================================================================")
	fmt.println("Single-operation latency measurements (GPU resource creation, destruction & ordering):")

	test_cp: pipeline.Composer_Pipeline
	if !pipeline.composer_pipeline_init(&test_cp, h.device, h.queue, h.format, 800, 600) {
		fmt.eprintln("Error initializing lifecycle test pipeline")
		return
	}
	defer pipeline.composer_pipeline_destroy(&test_cp)

	// 1. acquire_layer (texture + view GPU allocation)
	t0 := helper.platform_now()
	_, _ = pipeline.composer_pipeline_acquire_layer(
		&test_cp,
		1,
		.Overlay,
		800,
		600,
		false,
	)
	t1 := helper.platform_now()
	acquire_us := f64(helper.platform_ticks_to_ns(t1 - t0)) / 1000.0

	// 2. resize (pipeline dimension update and layer texture reallocation)
	t0 = helper.platform_now()
	pipeline.composer_pipeline_resize(&test_cp, 1024, 768)
	_, _ = pipeline.composer_pipeline_acquire_layer(
		&test_cp,
		1,
		.Overlay,
		1024,
		768,
		false,
	)
	t1 = helper.platform_now()
	resize_us := f64(helper.platform_ticks_to_ns(t1 - t0)) / 1000.0

	// 3. set_layer_order (reordering layer draw list back-to-front)
	order_test := [1]composer.Layer_Id{1}
	t0 = helper.platform_now()
	pipeline.composer_pipeline_set_layer_order(&test_cp, order_test[:])
	t1 = helper.platform_now()
	order_us := f64(helper.platform_ticks_to_ns(t1 - t0)) / 1000.0

	// 4. release_layer (GPU texture & view release)
	t0 = helper.platform_now()
	pipeline.composer_pipeline_release_layer(&test_cp, 1)
	t1 = helper.platform_now()
	release_us := f64(helper.platform_ticks_to_ns(t1 - t0)) / 1000.0

	fmt.println("--------------------------------------------------------------------------------")
	fmt.printfln("%-32s : %10s", "acquire_layer (Texture+View)", fmt.tprintf("%.2f µs", acquire_us))
	fmt.printfln("%-32s : %10s", "resize (Dimension Realloc)", fmt.tprintf("%.2f µs", resize_us))
	fmt.printfln("%-32s : %10s", "set_layer_order (Reorder)", fmt.tprintf("%.2f µs", order_us))
	fmt.printfln("%-32s : %10s", "release_layer (Resource Free)", fmt.tprintf("%.2f µs", release_us))
	fmt.println("================================================================================")
	fmt.println()
}

// ============================================================================
// VRAM Memory Modeling Report
// ============================================================================

print_vram_report :: proc() {
	fmt.println("================================================================================")
	fmt.println("                     VRAM MEMORY MODELING REPORT                                ")
	fmt.println("================================================================================")
	fmt.println("Estimated VRAM consumption per backing layer: w × h × 4 bytes (+ depth if enabled):")
	fmt.println()

	Resolutions := [3]struct {
		name: string,
		w, h: u64,
	}{
		{"1080p (1920x1080)", 1920, 1080},
		{"1440p (2560x1440)", 2560, 1440},
		{"4K    (3840x2160)", 3840, 2160},
	}

	layer_counts := [5]int{1, 2, 4, 8, 16}

	fmt.printfln("%-20s %10s %10s %10s %10s %10s", "Resolution", "1 Layer", "2 Layers", "4 Layers", "8 Layers", "16 Layers")
	fmt.println("--------------------------------------------------------------------------------")

	for res in Resolutions {
		b_color := res.w * res.h * 4
		b_depth := res.w * res.h * 8 // color + 4-byte depth

		// Color only row
		fmt.printf("%-20s", res.name)
		for count in layer_counts {
			mb := f64(b_color * u64(count)) / 1_000_000.0
			fmt.printf(" %10s", fmt.tprintf("%.2fMB", mb))
		}
		fmt.println()

		// Color + Depth row
		name_depth := fmt.tprintf("%s +D", res.name)
		fmt.printf("%-20s", name_depth)
		for count in layer_counts {
			mb := f64(b_depth * u64(count)) / 1_000_000.0
			fmt.printf(" %10s", fmt.tprintf("%.2fMB", mb))
		}
		fmt.println()
	}

	fmt.println("--------------------------------------------------------------------------------")
	fmt.println("Key Anchor Values:")
	fmt.println("  • At 4K, 1 layer fullscreen  = ~33.18 MB (31.64 MiB)")
	fmt.println("  • At 4K, 16 layers fullscreen = ~530.84 MB (506.25 MiB)")
	fmt.println("================================================================================")
	fmt.println()
}

// ============================================================================
// Multi-Scenario Benchmark Matrix Execution
// ============================================================================

_setup_scenario_layers :: proc(h: ^Harness_State, cfg: ^Scenario_Config) {
	screen_w := f32(cfg.target_w) if cfg.is_offscreen else h.screen_w
	screen_h := f32(cfg.target_h) if cfg.is_offscreen else h.screen_h

	pipeline.composer_pipeline_resize(&h.composer_pipe, screen_w, screen_h)
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, cfg.load_op)

	order: [layer.MAX_COMPOSER_LAYERS]composer.Layer_Id
	for i in 0..<cfg.layer_count {
		order[i] = LAYER_IDS[i]
	}
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, order[:cfg.layer_count])

	for i in 0..<cfg.layer_count {
		id := LAYER_IDS[i]
		l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
		if l == nil do continue

		l.opacity = 1.0
		l.corner_radius = 0.0

		switch cfg.size_mode {
		case .Fullscreen:
			l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
			l.scissor_rect = l.dest_rect

		case .Popup:
			pop_w: f32 = 400.0
			pop_h: f32 = 300.0
			offset := f32(i) * 30.0
			l.dest_rect = composer.rect_make(
				(screen_w - pop_w) * 0.5 + offset,
				(screen_h - pop_h) * 0.5 + offset,
				pop_w,
				pop_h,
			)
			l.scissor_rect = l.dest_rect

		case .Cursor:
			cur_w: f32 = 24.0
			cur_h: f32 = 36.0
			offset := f32(i) * 40.0
			l.dest_rect = composer.rect_make(100.0 + offset, 100.0 + offset, cur_w, cur_h)
			l.scissor_rect = l.dest_rect

		case .Grid:
			half_w := screen_w * 0.5
			half_h := screen_h * 0.5
			gx := f32(i % 2) * half_w
			gy := f32(i / 2) * half_h
			l.dest_rect = composer.rect_make(gx, gy, half_w, half_h)
			l.scissor_rect = l.dest_rect

		case .Checkerboard_4K:
			cols := 4
			cw := screen_w / f32(cols)
			ch := screen_h / f32(cols)
			col := i % cols
			row := i / cols
			parity_offset: f32 = 40.0 if (col + row) % 2 == 1 else 0.0
			l.dest_rect = composer.rect_make(f32(col) * cw + parity_offset, f32(row) * ch + parity_offset, cw, ch)
			l.scissor_rect = l.dest_rect

		case .Pathological_Scissor:
			l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
			switch i {
			case 0:
				l.scissor_rect = composer.rect_make(100, 100, 0, 0)
			case 1:
				l.scissor_rect = composer.rect_make(-100, -100, 300, 300)
			case 2:
				l.scissor_rect = composer.rect_make(screen_w + 200, screen_h + 200, 500, 500)
			case:
				l.scissor_rect = l.dest_rect
			}
		}

		// Initial animation setup
		switch cfg.anim_kind {
		case .None:
			// Follow size_mode
		case .Slide_Popup:
			if i == 0 {
				transition.transition_manager_init(&h.tm)
				l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
				l.scissor_rect = l.dest_rect
			} else if i == 1 {
				pop_w: f32 = 400.0
				pop_h: f32 = 300.0
				start_rect := composer.rect_make((screen_w - pop_w) * 0.5, 50.0, pop_w, pop_h)
				target_rect := composer.rect_make((screen_w - pop_w) * 0.5, screen_h - 350.0, pop_w, pop_h)
				l.dest_rect = start_rect
				l.scissor_rect = start_rect
				l.opacity = 1.0
				_ = transition.transition_start_rect(&h.tm, nil, id, start_rect, target_rect, 0, 1_000_000_000, .Smoothstep)
			}
		case .Fade_In_Out:
			if i == 0 {
				transition.transition_manager_init(&h.tm)
				l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
				l.scissor_rect = l.dest_rect
				l.opacity = 1.0
			}
			if i == 1 {
				l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
				l.scissor_rect = l.dest_rect
				l.opacity = 0.0
				_ = transition.transition_start_opacity(&h.tm, nil, id, 0.0, 1.0, 0, 1_000_000_000, .Smoothstep)
			}
		case .Crossfade_Tab:
			if i == 0 {
				transition.transition_manager_init(&h.tm)
				l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
				l.scissor_rect = l.dest_rect
				l.opacity = 1.0
			}
			if i == 1 {
				l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h)
				l.scissor_rect = l.dest_rect
				l.opacity = 0.0
				_, _ = transition.transition_crossfade(&h.tm, nil, LAYER_IDS[0], LAYER_IDS[1], 0, 1_000_000_000, .Smoothstep)
			}
		case .Scroll_Offset:
			l.dest_rect = composer.rect_make(0, 0, screen_w, screen_h + 400.0)
			l.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
		case .Moving_Layers:
			cols := 4
			grid_w := screen_w / f32(cols)
			grid_h := screen_h / f32(cols)
			gx := f32(i % cols) * grid_w
			gy := f32(i / cols) * grid_h
			pad: f32 = 8.0
			l.dest_rect = composer.rect_make(gx + pad, gy + pad, grid_w - pad * 2.0, grid_h - pad * 2.0)
			l.scissor_rect = l.dest_rect
		}

		// Apply dirty flag variations (WITHOUT ANY RASTERIZATION!)
		switch cfg.dirty_mode {
		case .None:
			pipeline.composer_pipeline_mark_clean(&h.composer_pipe, id)
		case .One:
			if i == 0 {
				pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, id)
			} else {
				pipeline.composer_pipeline_mark_clean(&h.composer_pipe, id)
			}
		case .All:
			pipeline.composer_pipeline_mark_dirty(&h.composer_pipe, id)
		}
	}
}

_update_scenario_animation :: proc(
	h: ^Harness_State,
	cfg: ^Scenario_Config,
	frame_idx: int,
	total_frames: int,
	dt: f32,
) {
	screen_w := f32(cfg.target_w) if cfg.is_offscreen else h.screen_w
	screen_h := f32(cfg.target_h) if cfg.is_offscreen else h.screen_h
	t := f32(frame_idx) * dt

	switch cfg.anim_kind {
	case .None:
		// Static

	case .Slide_Popup, .Fade_In_Out, .Crossfade_Tab:
		now_ns := u64(f64(frame_idx) * (1_000_000_000.0 / 60.0))
		_ = transition.transition_update(&h.tm, nil, h.composer_pipe.layer_pool.layers[:], now_ns)

	case .Scroll_Offset:
		l1 := pipeline.composer_pipeline_get_layer(&h.composer_pipe, LAYER_IDS[0])
		if l1 != nil {
			scroll_cycle: f32 = 400.0
			y_shift := math.floor(math.mod(f32(frame_idx) * 6.0, scroll_cycle) + 0.5)
			l1.dest_rect = composer.rect_make(0, -y_shift, screen_w, screen_h + scroll_cycle)
			l1.scissor_rect = composer.rect_make(0, 0, screen_w, screen_h)
			l1.opacity = 1.0
		}

	case .Moving_Layers:
		cols := 4
		grid_w := screen_w / f32(cols)
		grid_h := screen_h / f32(cols)
		for i in 0..<cfg.anim_count {
			id := LAYER_IDS[i]
			l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
			if l == nil do continue

			gx := f32(i % cols) * grid_w
			gy := f32(i / cols) * grid_h
			pad: f32 = 8.0

			cur_x := gx + pad
			cur_y := gy + pad
			x_off := math.floor(25.0 * math.sin(t * 3.0 + f32(i) * 0.7) + 0.5)
			y_off := math.floor(20.0 * math.cos(t * 2.5 + f32(i) * 0.5) + 0.5)
			cur_x = clamp(cur_x + x_off, 0.0, screen_w - (grid_w - pad * 2.0))
			cur_y = clamp(cur_y + y_off, 0.0, screen_h - (grid_h - pad * 2.0))

			l.dest_rect = composer.rect_make(cur_x, cur_y, grid_w - pad * 2.0, grid_h - pad * 2.0)
			l.scissor_rect = l.dest_rect
			l.opacity = 1.0
		}
	}
}

_restore_default_layers :: proc(h: ^Harness_State) {
	pipeline.composer_pipeline_resize(&h.composer_pipe, h.screen_w, h.screen_h)
	pipeline.composer_pipeline_set_load_op(&h.composer_pipe, .Clear)
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, LAYER_IDS[:])

	for id in LAYER_IDS {
		l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
		if l != nil {
			l.dest_rect = composer.rect_make(0, 0, h.screen_w, h.screen_h)
			l.scissor_rect = l.dest_rect
			l.opacity = 1.0
			l.corner_radius = 0.0
			pipeline.composer_pipeline_mark_clean(&h.composer_pipe, id)
		}
	}
}

execute_scenario_single_run :: proc(h: ^Harness_State, cfg: ^Scenario_Config, frames: int) -> Single_Run_Result {
	install_wgpu_call_counter_hooks()

	res: Single_Run_Result
	target_tex: contract.Gpu_Texture
	target_view: contract.Gpu_TextureView
	if cfg.is_offscreen {
		tex_usage := contract.Gpu_Texture_Usage.Render_Attach | contract.Gpu_Texture_Usage.Copy_Src
		target_tex = contract.create_texture(h.device, cfg.target_w, cfg.target_h, h.format, tex_usage)
		target_view = contract.create_texture_view(target_tex)
		if rawptr(target_tex) == nil || rawptr(target_view) == nil {
			res.failed += 1
			return res
		}
	}
	defer {
		if cfg.is_offscreen {
			contract.wait_for_idle(h.device)
			if rawptr(target_view) != nil do contract.destroy_texture_view(target_view)
			if rawptr(target_tex) != nil do contract.destroy_texture(target_tex)
		}
		_restore_default_layers(h)
	}

	_setup_scenario_layers(h, cfg)

	total_cpu_us: f64 = 0.0
	measured_frames := 0

	for f in 0..<frames {
		_pump_events()

		view_to_use := target_view
		surf_tex: contract.Gpu_Texture
		if !cfg.is_offscreen {
			st, sv := _acquire_surface(h)
			surf_tex = st
			view_to_use = sv
		}

		if rawptr(view_to_use) == nil {
			res.failed += 1
			continue
		}

		if cfg.anim_kind != .None {
			_update_scenario_animation(h, cfg, f, frames, 1.0 / 60.0)
		}

		pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

		g_wgpu_call_counter = 0
		t0 := helper.platform_now()

		enc := contract.create_command_encoder(h.device)
		comp_ok := pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view_to_use)
		if !comp_ok {
			res.failed += 1
		}
		cmd := contract.finish_command_buffer(enc)
		contract.release_command_encoder(enc)

		if cmd != nil {
			contract.submit(h.queue, cmd)
			contract.release_command_buffer(cmd)
		}

		t1 := helper.platform_now()

		frame_ns := helper.platform_ticks_to_ns(t1 - t0)
		total_cpu_us += f64(frame_ns) / 1000.0
		measured_frames += 1
		res.calls = g_wgpu_call_counter

		if !cfg.is_offscreen {
			if contract.present_surface(h.surface) {
				res.presented += 1
			} else {
				res.failed += 1
			}
			contract.release_surface_texture(surf_tex, view_to_use)
		} else {
			res.presented += 1
		}

		pipeline.composer_pipeline_end_frame(&h.composer_pipe)
	}

	if wgpu_backend.get_uncaptured_error_count() > 0 {
		res.failed += 1
		wgpu_backend.clear_uncaptured_errors()
	}

	if measured_frames > 0 {
		res.cpu_us = total_cpu_us / f64(measured_frames)
	}

	return res
}

Regression_Stats :: struct {
	slope:      f64,
	intercept:  f64,
	se_slope:   f64,
	r_squared:  f64,
	ci_low_95:  f64,
	ci_high_95: f64,
}

linear_regression_stats :: proc(xs: []f64, ys: []f64) -> Regression_Stats {
	res: Regression_Stats
	n := f64(len(xs))
	if n < 3.0 do return res

	sum_x := 0.0
	sum_y := 0.0
	for i in 0..<len(xs) {
		sum_x += xs[i]
		sum_y += ys[i]
	}
	mean_x := sum_x / n
	mean_y := sum_y / n

	num := 0.0
	den := 0.0
	for i in 0..<len(xs) {
		dx := xs[i] - mean_x
		dy := ys[i] - mean_y
		num += dx * dy
		den += dx * dx
	}

	if den == 0.0 do return res
	res.slope = num / den
	res.intercept = mean_y - res.slope * mean_x

	ss_res := 0.0
	ss_tot := 0.0
	for i in 0..<len(xs) {
		y_pred := res.intercept + res.slope * xs[i]
		res_diff := ys[i] - y_pred
		tot_diff := ys[i] - mean_y
		ss_res += res_diff * res_diff
		ss_tot += tot_diff * tot_diff
	}

	if ss_tot > 0.0 {
		res.r_squared = max(0.0, 1.0 - (ss_res / ss_tot))
	}

	df := n - 2.0
	se_res := math.sqrt(ss_res / max(df, 1.0))
	res.se_slope = se_res / math.sqrt(den)

	t_crit := 2.035
	if df <= 1.0 {
		t_crit = 12.706
	} else if df <= 2.0 {
		t_crit = 4.303
	} else if df <= 3.0 {
		t_crit = 3.182
	} else if df <= 4.0 {
		t_crit = 2.776
	} else if df <= 5.0 {
		t_crit = 2.571
	} else if df <= 6.0 {
		t_crit = 2.447
	} else if df <= 8.0 {
		t_crit = 2.306
	} else if df <= 12.0 {
		t_crit = 2.179
	} else if df <= 20.0 {
		t_crit = 2.086
	} else if df <= 30.0 {
		t_crit = 2.042
	} else {
		t_crit = 2.035
	}

	ci_half := t_crit * res.se_slope
	res.ci_low_95 = res.slope - ci_half
	res.ci_high_95 = res.slope + ci_half

	return res
}

// ============================================================================
// Comprehensive Matrix Runner & Health Check
// ============================================================================

Stats_Summary :: struct {
	mean:     f64,
	std_dev:  f64,
	ci_low:   f64,
	ci_high:  f64,
}

compute_stats :: proc(vals: []f64) -> Stats_Summary {
	res: Stats_Summary
	n := len(vals)
	if n == 0 do return res

	sum := 0.0
	for v in vals {
		sum += v
	}
	res.mean = sum / f64(n)

	if n > 1 {
		sum_sq_diff := 0.0
		for v in vals {
			diff := v - res.mean
			sum_sq_diff += diff * diff
		}
		res.std_dev = math.sqrt(sum_sq_diff / f64(n - 1))

		t_multiplier := 2.776
		switch n - 1 {
		case 1:  t_multiplier = 12.706
		case 2:  t_multiplier = 4.303
		case 3:  t_multiplier = 3.182
		case 4:  t_multiplier = 2.776
		case 5:  t_multiplier = 2.571
		case:    t_multiplier = 2.042
		}

		ci_half := t_multiplier * res.std_dev / math.sqrt(f64(n))
		res.ci_low = res.mean - ci_half
		res.ci_high = res.mean + ci_half
	} else {
		res.ci_low = res.mean
		res.ci_high = res.mean
	}

	return res
}

evaluate_threshold :: proc(ci_low, ci_high, threshold: f64) -> string {
	if ci_high < threshold {
		return "PASS"
	} else if ci_low > threshold {
		return "FAIL"
	}
	return "INCONCLUSIVE"
}

find_scenario_index :: proc(scenarios: []Scenario_Config, name: string) -> int {
	for s, i in scenarios {
		if s.name == name do return i
	}
	return -1
}

SCENARIOS_TOTAL :: 24

export_baseline_json :: proc(
	h: ^Harness_State,
	env: ^Bench_Environment,
	scenarios: []Scenario_Config,
	run_means: ^[SCENARIOS_TOTAL][5]f64,
	num_runs: int,
	reg_slope: Regression_Stats,
	stats_jump: Stats_Summary,
	verdict_jump: string,
	verdict_slope: string,
	stats_1pane: Stats_Summary,
	verdict_1pane: string,
	output_path: string,
) -> bool {
	_ = os.make_directory("bench")
	_ = os.make_directory("bench/baselines")

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)

	now_t := time.now()
	timestamp_str, _ := time.time_to_rfc3339(now_t)

	fmt.sbprintln(&b, "{")
	fmt.sbprintfln(&b, "  \"commit\": \"%s\",", env.git_commit)
	fmt.sbprintfln(&b, "  \"odin_version\": \"%s\",", env.odin_ver)
	fmt.sbprintfln(&b, "  \"wgpu_version\": \"%s\",", env.wgpu_ver)
	fmt.sbprintfln(&b, "  \"macos_version\": \"%s\",", env.macos_version)
	fmt.sbprintfln(&b, "  \"timestamp\": \"%s\",", timestamp_str)
	fmt.sbprintln(&b, "  \"environment\": {")
	fmt.sbprintfln(&b, "    \"cpu_model\": \"%s\",", env.cpu_brand)
	fmt.sbprintfln(&b, "    \"logical_cores\": %d,", env.logical_cpu)
	fmt.sbprintfln(&b, "    \"physical_cores\": %d,", env.physical_cpu)
	fmt.sbprintfln(&b, "    \"memory_bytes\": %d,", env.mem_bytes)
	fmt.sbprintfln(&b, "    \"power_source\": \"%s\",", env.power_source)
	fmt.sbprintfln(&b, "    \"low_power_mode\": %t,", env.low_power)
	fmt.sbprintfln(&b, "    \"thermal_state\": \"%s\",", env.thermal_state)
	fmt.sbprintln(&b, "    \"thread_qos\": \"User Interactive\",")
	fmt.sbprintfln(&b, "    \"swapchain_resolution\": \"%s\",", env.swapchain_res)
	fmt.sbprintfln(&b, "    \"surface_format\": \"%s\",", env.surface_fmt)
	fmt.sbprintfln(&b, "    \"refresh_rate_hz\": %.1f,", env.refresh_rate)
	fmt.sbprintfln(&b, "    \"prng_seed\": \"%s\"", env.prng_seed)
	fmt.sbprintln(&b, "  },")
	fmt.sbprintln(&b, "  \"locked_evaluations\": {")
	fmt.sbprintln(&b, "    \"normal_1pane_1080p\": {")
	fmt.sbprintln(&b, "      \"metric\": \"Normal 1-Pane CPU Time per Frame\",")
	fmt.sbprintln(&b, "      \"unit\": \"us\",")
	fmt.sbprintln(&b, "      \"threshold\": 80.0,")
	fmt.sbprintfln(&b, "      \"mean\": %.3f,", stats_1pane.mean)
	fmt.sbprintfln(&b, "      \"ci_low_95\": %.3f,", stats_1pane.ci_low)
	fmt.sbprintfln(&b, "      \"ci_high_95\": %.3f,", stats_1pane.ci_high)
	fmt.sbprintfln(&b, "      \"verdict\": \"%s\"", verdict_1pane)
	fmt.sbprintln(&b, "    },")
	fmt.sbprintln(&b, "    \"base_jump_0_to_1\": {")
	fmt.sbprintln(&b, "      \"metric\": \"0->1 Base Jump\",")
	fmt.sbprintln(&b, "      \"unit\": \"us\",")
	fmt.sbprintln(&b, "      \"threshold\": 60.0,")
	fmt.sbprintfln(&b, "      \"mean\": %.3f,", stats_jump.mean)
	fmt.sbprintfln(&b, "      \"ci_low_95\": %.3f,", stats_jump.ci_low)
	fmt.sbprintfln(&b, "      \"ci_high_95\": %.3f,", stats_jump.ci_high)
	fmt.sbprintfln(&b, "      \"verdict\": \"%s\"", verdict_jump)
	fmt.sbprintln(&b, "    },")
	fmt.sbprintln(&b, "    \"marginal_slope_1_to_n\": {")
	fmt.sbprintln(&b, "      \"metric\": \"1->N Marginal Slope\",")
	fmt.sbprintln(&b, "      \"unit\": \"us/layer\",")
	fmt.sbprintln(&b, "      \"threshold\": 15.0,")
	fmt.sbprintfln(&b, "      \"slope\": %.3f,", reg_slope.slope)
	fmt.sbprintfln(&b, "      \"intercept\": %.3f,", reg_slope.intercept)
	fmt.sbprintfln(&b, "      \"r_squared\": %.4f,", reg_slope.r_squared)
	fmt.sbprintfln(&b, "      \"se_slope\": %.4f,", reg_slope.se_slope)
	fmt.sbprintfln(&b, "      \"ci_low_95\": %.3f,", reg_slope.ci_low_95)
	fmt.sbprintfln(&b, "      \"ci_high_95\": %.3f,", reg_slope.ci_high_95)
	fmt.sbprintfln(&b, "      \"verdict\": \"%s\"", verdict_slope)
	fmt.sbprintln(&b, "    }")
	fmt.sbprintln(&b, "  },")
	fmt.sbprintln(&b, "  \"scenarios\": [")

	idx_1pane := find_scenario_index(scenarios, "Normal 1-Pane 1080p Target")

	for s in 0..<len(scenarios) {
		stats_s := compute_stats(run_means[s][:num_runs])
		fmt.sbprintln(&b, "    {")
		fmt.sbprintfln(&b, "      \"name\": \"%s\",", scenarios[s].name)
		fmt.sbprintln(&b, "      \"unit\": \"us\",")
		fmt.sbprint(&b, "      \"runs\": [")
		for r in 0..<num_runs {
			if r > 0 do fmt.sbprint(&b, ", ")
			fmt.sbprintf(&b, "%.3f", run_means[s][r])
		}
		fmt.sbprintln(&b, "],")
		fmt.sbprintfln(&b, "      \"mean\": %.3f,", stats_s.mean)
		fmt.sbprintfln(&b, "      \"ci_low_95\": %.3f,", stats_s.ci_low)
		fmt.sbprintfln(&b, "      \"ci_high_95\": %.3f,", stats_s.ci_high)
		v_str := "-"
		if s == idx_1pane do v_str = verdict_1pane
		fmt.sbprintfln(&b, "      \"verdict\": \"%s\"", v_str)
		if s < len(scenarios) - 1 {
			fmt.sbprintln(&b, "    },")
		} else {
			fmt.sbprintln(&b, "    }")
		}
	}
	fmt.sbprintln(&b, "  ]")
	fmt.sbprintln(&b, "}")

	json_str := strings.to_string(b)
	err := os.write_entire_file(output_path, json_str)
	if err != nil {
		fmt.eprintfln("Error writing baseline JSON to %s: %v", output_path, err)
		return false
	}
	fmt.printfln("Baseline successfully written to: %s", output_path)
	return true
}

run_full_benchmark :: proc(h: ^Harness_State, flags: Benchmark_Flags) {
	rng: helper.Xoshiro256pp
	seed: u64 = 0x853c49e6748fea9b
	helper.xoshiro256pp_init(&rng, seed)

	env := get_bench_environment(h, seed)
	log_machine_diagnostics(h, seed)

	mp := (h.screen_w * h.screen_h) / 1_000_000.0
	fmt.println("================================================================================")
	fmt.printfln("SWAPCHAIN & DISPLAY CONFIGURATION:")
	fmt.printfln("  Resolution:      %d x %d physical pixels (%.2f Megapixels per layer)", int(h.screen_w), int(h.screen_h), mp)
	fmt.printfln("  Surface Format:  %v (Linear Unorm Straight Alpha)", h.format)
	fmt.printfln("  Display Refresh: %.1f Hz", env.refresh_rate)
	fmt.println("================================================================================")
	fmt.println()

	if !run_correctness_suite(h) {
		fmt.eprintln("Error: Correctness suite failed! Benchmark aborted.")
		return
	}

	run_lifecycle_benchmark(h)
	print_vram_report()

	all_scenarios := [SCENARIOS_TOTAL]Scenario_Config{
		// 1. 8-Point Layer Count Regression (0, 1, 2, 4, 6, 8, 12, 16)
		{"Scale 0 Layers (Empty Pass)", .Layer_Count, .None, 0, 0, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 1 Layer (Fullscreen)", .Layer_Count, .None, 0, 1, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 2 Layers (Fullscreen)", .Layer_Count, .None, 0, 2, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 4 Layers (Fullscreen)", .Layer_Count, .None, 0, 4, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 6 Layers (Fullscreen)", .Layer_Count, .None, 0, 6, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 8 Layers (Fullscreen)", .Layer_Count, .None, 0, 8, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 12 Layers (Fullscreen)", .Layer_Count, .None, 0, 12, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Scale 16 Layers (Fullscreen)", .Layer_Count, .None, 0, 16, .Fullscreen, .None, .Clear, false, 0, 0},

		// 2. Normal Baselines
		{"Normal 1-Pane 1080p Target", .Offscreen_Res, .None, 0, 1, .Fullscreen, .None, .Clear, true, 1920, 1080},
		{"Normal 2x2 Grid (4 Panes)", .Overdraw, .None, 0, 4, .Grid, .None, .Clear, false, 0, 0},

		// 3. Extreme Scenarios
		{"Extreme: 16-Layer 4K Checkerboard Overdraw", .Overdraw, .None, 0, 16, .Checkerboard_4K, .None, .Clear, true, 3840, 2160},
		{"Extreme: Pathological Scissors", .Layer_Size, .None, 0, 4, .Pathological_Scissor, .None, .Clear, false, 0, 0},
		{"Extreme: 16 Moving Layers 120 FPS (CPU-Only)", .Layer_Count, .Moving_Layers, 16, 16, .Fullscreen, .None, .Clear, true, 1920, 1080},

		// 4. Other Variations
		{"Size: Popup (400x300, 4 layers)", .Layer_Size, .None, 0, 4, .Popup, .None, .Clear, false, 0, 0},
		{"Size: Cursor (24x36, 4 layers)", .Layer_Size, .None, 0, 4, .Cursor, .None, .Clear, false, 0, 0},
		{"Dirty: 0 Dirty (Idle Baseline)", .Dirty_Count, .None, 0, 4, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Dirty: 1 Dirty Layer", .Dirty_Count, .None, 0, 4, .Fullscreen, .One, .Clear, false, 0, 0},
		{"Dirty: All 4 Dirty Layers", .Dirty_Count, .None, 0, 4, .Fullscreen, .All, .Clear, false, 0, 0},
		{"Clear Mode: LoadOp = .Clear", .Clear_Mode, .None, 0, 4, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Clear Mode: LoadOp = .Load", .Clear_Mode, .None, 0, 4, .Fullscreen, .None, .Load, false, 0, 0},
		{"Anim: Slide Popup (1 moving, 1 static)", .Layer_Size, .Slide_Popup, 1, 2, .Popup, .None, .Clear, false, 0, 0},
		{"Anim: Fade In/Out (1 fading, 1 static)", .Overdraw, .Fade_In_Out, 1, 2, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Anim: Crossfade Tab (2 crossfading)", .Overdraw, .Crossfade_Tab, 2, 2, .Fullscreen, .None, .Clear, false, 0, 0},
		{"Anim: Scroll Offset (1 layer moving offset)", .Layer_Size, .Scroll_Offset, 1, 1, .Fullscreen, .None, .Clear, false, 0, 0},
	}

	when ODIN_OS == .Darwin {
		term_macos_set_user_interactive_qos()
	}

	contract.set_present_mode(h.surface, .Immediate)

	// Interleaved Warmup across all scenarios
	fmt.println("Running interleaved warmup across all scenarios (10 frames each)...")
	for s_idx in 0..<SCENARIOS_TOTAL {
		cfg := &all_scenarios[s_idx]
		_ = execute_scenario_single_run(h, cfg, 10)
	}
	fmt.println("Interleaved warmup complete.")
	fmt.println()

	NUM_RUNS := 2 if flags.quick else 5
	frames_per_run := 20 if flags.quick else 60

	run_means: [SCENARIOS_TOTAL][5]f64
	run_presented: [SCENARIOS_TOTAL][5]int
	run_failed: [SCENARIOS_TOTAL][5]int

	r := 0
	for r < NUM_RUNS {
		t_start := term_macos_get_thermal_state()
		if t_start != 0 {
			fmt.printfln("WARNING: Non-nominal thermal state (%d) at start of Run %d/%d. Cooling down 2s...", t_start, r + 1, NUM_RUNS)
			time.sleep(2 * time.Second)
			continue
		}

		scenario_indices: [SCENARIOS_TOTAL]int
		for i in 0..<SCENARIOS_TOTAL {
			scenario_indices[i] = i
		}
		helper.xoshiro256pp_shuffle(&rng, scenario_indices[:])

		fmt.printfln("--- Starting Run %d/%d (Shuffled with seed) ---", r + 1, NUM_RUNS)

		for s_idx in scenario_indices {
			cfg := &all_scenarios[s_idx]
			res := execute_scenario_single_run(h, cfg, frames_per_run)
			run_means[s_idx][r] = res.cpu_us
			run_presented[s_idx][r] = res.presented
			run_failed[s_idx][r] = res.failed
		}

		t_end := term_macos_get_thermal_state()
		if t_end != 0 {
			fmt.printfln("WARNING: Non-nominal thermal state (%d) at end of Run %d/%d. Repeating run...", t_end, r + 1, NUM_RUNS)
			time.sleep(2 * time.Second)
			continue
		}

		r += 1
	}

	idx_scale_0 := find_scenario_index(all_scenarios[:], "Scale 0 Layers (Empty Pass)")
	idx_scale_1 := find_scenario_index(all_scenarios[:], "Scale 1 Layer (Fullscreen)")
	idx_1pane   := find_scenario_index(all_scenarios[:], "Normal 1-Pane 1080p Target")
	assert(idx_scale_0 >= 0 && idx_scale_1 >= 0 && idx_1pane >= 0, "Required benchmark scenarios missing")

	// 1. Normal 1-Pane Evaluation
	stats_1pane := compute_stats(run_means[idx_1pane][:NUM_RUNS])
	verdict_1pane := evaluate_threshold(stats_1pane.ci_low, stats_1pane.ci_high, 80.0)

	// 2. 0->1 Jump Evaluation
	jump_diffs: [5]f64
	for run_idx in 0..<NUM_RUNS {
		jump_diffs[run_idx] = run_means[idx_scale_1][run_idx] - run_means[idx_scale_0][run_idx]
	}
	stats_jump := compute_stats(jump_diffs[:NUM_RUNS])
	verdict_jump := evaluate_threshold(stats_jump.ci_low, stats_jump.ci_high, 60.0)

	// 3. 1->N Slope Regression Evaluation
	K_scenarios := [7]string{
		"Scale 1 Layer (Fullscreen)",
		"Scale 2 Layers (Fullscreen)",
		"Scale 4 Layers (Fullscreen)",
		"Scale 6 Layers (Fullscreen)",
		"Scale 8 Layers (Fullscreen)",
		"Scale 12 Layers (Fullscreen)",
		"Scale 16 Layers (Fullscreen)",
	}
	K_values := [7]f64{1.0, 2.0, 4.0, 6.0, 8.0, 12.0, 16.0}
	xs_reg: [35]f64
	ys_reg: [35]f64
	pt_count := 0
	for k_i in 0..<7 {
		k_idx := find_scenario_index(all_scenarios[:], K_scenarios[k_i])
		if k_idx >= 0 {
			for run_idx in 0..<NUM_RUNS {
				xs_reg[pt_count] = K_values[k_i]
				ys_reg[pt_count] = run_means[k_idx][run_idx]
				pt_count += 1
			}
		}
	}
	reg_slope := linear_regression_stats(xs_reg[:pt_count], ys_reg[:pt_count])
	verdict_slope := evaluate_threshold(reg_slope.ci_low_95, reg_slope.ci_high_95, 15.0)

	// Print Comprehensive Report Table
	fmt.println()
	fmt.println("==================================================================================================================================================")
	fmt.println("                                               HARNESS COMPOSER BENCHMARK REPORT (V2.2)")
	fmt.println("==================================================================================================================================================")
	fmt.printfln("%-44s | %-36s | %-10s | %-18s | %-12s", "Scenario", "Run Means (µs)", "Mean (µs)", "95% CI (µs)", "Verdict")
	fmt.println("---------------------------------------------+--------------------------------------+------------+--------------------+-------------")

	for s in 0..<SCENARIOS_TOTAL {
		cfg := &all_scenarios[s]
		stats_s := compute_stats(run_means[s][:NUM_RUNS])

		runs_str: string
		if NUM_RUNS == 2 {
			runs_str = fmt.tprintf("[%.1f, %.1f]", run_means[s][0], run_means[s][1])
		} else if NUM_RUNS == 5 {
			runs_str = fmt.tprintf("[%.1f, %.1f, %.1f, %.1f, %.1f]", run_means[s][0], run_means[s][1], run_means[s][2], run_means[s][3], run_means[s][4])
		} else {
			runs_str = fmt.tprintf("[%v]", run_means[s][:NUM_RUNS])
		}

		ci_str := fmt.tprintf("[%.1f, %.1f]", stats_s.ci_low, stats_s.ci_high)
		mean_str := fmt.tprintf("%.1f", stats_s.mean)

		v_str := "-"
		if s == idx_1pane {
			v_str = verdict_1pane
		}

		is_invalid := false
		for r_i in 0..<NUM_RUNS {
			if run_failed[s][r_i] > 0 do is_invalid = true
			if !cfg.is_offscreen && run_presented[s][r_i] != frames_per_run do is_invalid = true
		}
		if is_invalid {
			v_str = "INVALID"
		}

		fmt.printfln("%-44s | %-36s | %10s | %-18s | %-12s", cfg.name, runs_str, mean_str, ci_str, v_str)
	}
	fmt.println("==================================================================================================================================================")
	fmt.println()

	// Print Locked Thresholds Evaluation
	fmt.println("================================================================================")
	fmt.println("                         LOCKED THRESHOLDS EVALUATION                           ")
	fmt.println("================================================================================")
	fmt.printfln("1. Normal 1-Pane CPU Time per Frame (1080p target):")
	fmt.printfln("   Mean:             %.2f µs (95%% CI: [%.2f, %.2f] µs)", stats_1pane.mean, stats_1pane.ci_low, stats_1pane.ci_high)
	fmt.printfln("   Locked Threshold: ≤ 80.0 µs")
	fmt.printfln("   Verdict:          [%s]", verdict_1pane)
	fmt.println()

	fmt.printfln("2. 8-Point Layer Scaling Regression:")
	fmt.printfln("   0→1 Base Jump:    %.2f µs (95%% CI: [%.2f, %.2f] µs)", stats_jump.mean, stats_jump.ci_low, stats_jump.ci_high)
	fmt.printfln("   Locked Threshold: ≤ 60.0 µs")
	fmt.printfln("   Verdict:          [%s]", verdict_jump)
	fmt.println()
	fmt.printfln("   1→N OLS Slope:    %.2f µs/layer (SE: %.3f, 95%% CI: [%.2f, %.2f] µs/layer, R²: %.4f)", reg_slope.slope, reg_slope.se_slope, reg_slope.ci_low_95, reg_slope.ci_high_95, reg_slope.r_squared)
	fmt.printfln("   Locked Threshold: ≤ 15.0 µs/layer")
	fmt.printfln("   Verdict:          [%s]", verdict_slope)
	fmt.println("================================================================================")
	fmt.println()

	// Export Baseline JSON
	_ = export_baseline_json(
		h,
		&env,
		all_scenarios[:],
		&run_means,
		NUM_RUNS,
		reg_slope,
		stats_jump,
		verdict_jump,
		verdict_slope,
		stats_1pane,
		verdict_1pane,
		"bench/baselines/mac14_2-m2.json",
	)
}

// ============================================================================
// Interactive Visualization Layout
// ============================================================================

_setup_interactive_layers :: proc(h: ^Harness_State) {
	// Lay out 16 layers in a 4x4 overlapping cascaded grid with rounded corners
	cols := 4
	rows := 4
	grid_w := h.screen_w / f32(cols)
	grid_h := h.screen_h / f32(rows)

	pipeline.composer_pipeline_resize(&h.composer_pipe, h.screen_w, h.screen_h)
	pipeline.composer_pipeline_set_layer_order(&h.composer_pipe, LAYER_IDS[:])

	for i in 0..<layer.MAX_COMPOSER_LAYERS {
		id := LAYER_IDS[i]
		l := pipeline.composer_pipeline_get_layer(&h.composer_pipe, id)
		if l == nil do continue

		gx := f32(i % cols) * grid_w
		gy := f32(i / cols) * grid_h
		pad: f32 = 12.0

		l.dest_rect = composer.rect_make(gx + pad, gy + pad, grid_w - pad * 2.0, grid_h - pad * 2.0)
		l.scissor_rect = l.dest_rect
		l.opacity = 0.95
		l.corner_radius = 12.0
		pipeline.composer_pipeline_mark_clean(&h.composer_pipe, id)
	}
}

Benchmark_Flags :: struct {
	auto_bench: bool,
	quick:      bool,
	anim_only:  bool,
	fifo_full:  bool,
}

parse_flags :: proc() -> Benchmark_Flags {
	flags: Benchmark_Flags
	for arg in os.args[1:] {
		if arg == "--bench" || arg == "-b" {
			flags.auto_bench = true
		} else if arg == "--quick" || arg == "-q" {
			flags.quick = true
		} else if arg == "--anim" || arg == "-a" {
			flags.anim_only = true
		} else if arg == "--fifo-full" {
			flags.fifo_full = true
		}
	}
	return flags
}

// ============================================================================
// Main Application Entry Point
// ============================================================================

main :: proc() {
	flags := parse_flags()

	h := new(Harness_State)
	defer free(h)

	h.running = true
	window_w: i32 = 1600
	window_h: i32 = 1000

	if !plat_win.window_init(&h.window, "Term - Standalone Native GUI Composer Harness & Benchmark", window_w, window_h) {
		fmt.eprintln("Harness Error: window_init failed")
		os.exit(1)
	}
	defer plat_win.window_destroy(&h.window)

	// Initialize WebGPU Hardware Driver
	wgpu_backend.init_wgpu_driver()
	h.instance = contract.create_instance()
	h.surface = wgpu_backend.create_surface(h.instance, h.window.handle)
	h.device, h.queue = contract.request_device(h.instance, h.surface)
	h.format = contract.get_preferred_format(h.surface, h.device)

	plat_win.window_update_pixel_size(&h.window)
	h.screen_w = f32(h.window.pixel_w)
	h.screen_h = f32(h.window.pixel_h)

	contract.configure_surface(h.surface, h.device, h.format, u32(h.screen_w), u32(h.screen_h))

	// Pump initial events so NSWindow and CAMetalLayer settle
	for _ in 0..<10 {
		_pump_events()
	}

	// Initialize Hardware Timestamp Query Resources
	_init_timestamp_query(h)
	defer _destroy_timestamp_query(h)

	// Initialize Composer Pipeline
	if !pipeline.composer_pipeline_init(
		&h.composer_pipe,
		h.device,
		h.queue,
		h.format,
		h.screen_w,
		h.screen_h,
	) {
		fmt.eprintln("Harness Error: composer_pipeline_init failed")
		os.exit(1)
	}
	defer pipeline.composer_pipeline_destroy(&h.composer_pipe)

	// Pre-fill all 16 backing layers ONCE with solid colors (No Raster Invariant)
	if !prefill_backing_layers(h, u32(h.screen_w), u32(h.screen_h)) {
		fmt.eprintln("Harness Error: prefill_backing_layers failed")
		os.exit(1)
	}

	if flags.auto_bench {
		run_full_benchmark(h, flags)
		return
	}

	// Interactive Mode
	_setup_interactive_layers(h)
	fmt.println("================================================================================")
	fmt.println("           NATIVE COMPOSER GUI HARNESS (INTERACTIVE MODE)                       ")
	fmt.println("================================================================================")
	fmt.printfln("Window initialized (%dx%d pixels). 16 pre-filled layers composited.", int(h.screen_w), int(h.screen_h))
	fmt.println("Controls:")
	fmt.println("  [B]   - Run Full Comprehensive Composer Benchmark Suite")
	fmt.println("  [ESC] - Exit Harness")
	fmt.println("================================================================================")
	fmt.println()

	event: sdl3.Event
	for h.running {
		for sdl3.PollEvent(&event) {
			if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
				h.running = false
				break
			}

			if event.type == .KEY_DOWN {
				switch event.key.key {
				case sdl3.K_ESCAPE:
					h.running = false
				case sdl3.K_B:
					fmt.println("\n>>> User requested benchmark via [B] key...")
					run_full_benchmark(h, flags)
					_setup_interactive_layers(h)
				}
			}
		}

		// Interactive steady-state composition frame
		tex, view, _ := contract.get_surface_texture(h.surface)
		if rawptr(view) != nil {
			pipeline.composer_pipeline_begin_frame(&h.composer_pipe)

			enc := contract.create_command_encoder(h.device)
			if rawptr(enc) != nil {
				_ = pipeline.composer_pipeline_composite(&h.composer_pipe, enc, view)
				cmd := contract.finish_command_buffer(enc)
				contract.release_command_encoder(enc)
				if cmd != nil {
					contract.submit(h.queue, cmd)
					contract.release_command_buffer(cmd)
				}
			}

			_ = contract.present_surface(h.surface)
			contract.release_surface_texture(tex, view)
			pipeline.composer_pipeline_end_frame(&h.composer_pipe)
		}
	}
}

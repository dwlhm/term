package gpu_bench

// Phase 17 SDL3-GPU spike: WgslSource -> MslArtifact -> Sdl3Spike.
//
// sdl3_spike_present drives CreateGPUDevice -> ClaimWindow -> Acquire ->
// Submit against the caller's window and reports the ACTUAL driver name.
// The GPUDevice is destroyed before return on every path, including failure.
// The spike is graphics-only (no pipelines/shaders): the inline MSL quad
// reference lives in src/render/shaders/msl_spike/bg.msl.
//
// A non-Metal driver is logged and reported invalid (ok=false): the result
// is deferred to a Metal run, never silently accepted.

import "base:runtime"
import "core:fmt"
import sdl3 "vendor:sdl3"

// SDL3_SPIKE_WANT_METAL is the only driver accepted as a valid spike run.
SDL3_SPIKE_WANT_METAL :: "metal"

// sdl3_spike_present runs one acquire+submit round-trip on window and returns
// the outcome plus a driver note naming the actual driver. The GPUDevice is
// always destroyed before return. The caller owns window and the returned
// note string (delete it when done).
sdl3_spike_present :: proc(window: ^sdl3.Window, allocator: runtime.Allocator = context.allocator) -> (ok: bool, driver_note: string) {
	if window == nil {
		return false, fmt.aprintf("spike invalid: nil window", allocator = allocator)
	}
	device := sdl3.CreateGPUDevice(sdl3.GPUShaderFormat{.MSL}, false, nil)
	if device == nil {
		return false, fmt.aprintf("spike invalid: CreateGPUDevice failed", allocator = allocator)
	}
	defer sdl3.DestroyGPUDevice(device)

	driver_cstr := sdl3.GetGPUDeviceDriver(device)
	driver := string(driver_cstr)
	if driver != SDL3_SPIKE_WANT_METAL {
		return false, fmt.aprintf(
			"spike invalid: non-Metal driver '%s' (want '%s'); deferred to Metal run",
			driver, SDL3_SPIKE_WANT_METAL, allocator = allocator,
		)
	}
	if !sdl3.ClaimWindowForGPUDevice(device, window) {
		return false, fmt.aprintf(
			"spike invalid: ClaimWindowForGPUDevice failed (driver '%s')",
			driver, allocator = allocator,
		)
	}
	defer sdl3.ReleaseWindowFromGPUDevice(device, window)

	cmd := sdl3.AcquireGPUCommandBuffer(device)
	if cmd == nil {
		return false, fmt.aprintf(
			"spike invalid: AcquireGPUCommandBuffer failed (driver '%s')",
			driver, allocator = allocator,
		)
	}
	tex: ^sdl3.GPUTexture
	w, h: u32
	if !sdl3.AcquireGPUSwapchainTexture(cmd, window, &tex, &w, &h) {
		_ = sdl3.CancelGPUCommandBuffer(cmd)
		return false, fmt.aprintf(
			"spike rerun: swapchain acquire failed (driver '%s'); only clean runs gate",
			driver, allocator = allocator,
		)
	}
	if !sdl3.SubmitGPUCommandBuffer(cmd) {
		return false, fmt.aprintf(
			"spike invalid: SubmitGPUCommandBuffer failed (driver '%s')",
			driver, allocator = allocator,
		)
	}
	return true, fmt.aprintf(
		"spike clean: quad submit presented (driver '%s', %ux%u)",
		driver, w, h, allocator = allocator,
	)
}

// sdl3_spike_shader_format reports the shader formats a device actually
// wants (MSL vs METALLIB). A nil device yields the empty (invalid) set.
sdl3_spike_shader_format :: proc(device: ^sdl3.GPUDevice) -> sdl3.GPUShaderFormat {
	if device == nil {
		return sdl3.GPU_SHADERFORMAT_INVALID
	}
	return sdl3.GetGPUShaderFormats(device)
}

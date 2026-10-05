#+build darwin
package wgpu_backend

import "vendor:sdl3"
import gpu "../"

// Wgpu_Surface wraps the native WGPU surface handle and state (Darwin stub).
Wgpu_Surface :: struct {
	dummy: rawptr,
}

_wgpu_stub_vtable: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	shader_language = .WGSL,
}

create_wgpu_backend :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_wgpu_stub_vtable
}

wgpu_backend_vtable :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_wgpu_stub_vtable
}

create_surface :: proc(instance: rawptr, window: ^sdl3.Window) -> ^Wgpu_Surface {
	return nil
}

destroy_surface :: proc(surf: ^Wgpu_Surface) {}

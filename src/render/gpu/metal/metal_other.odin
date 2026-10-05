#+build !darwin
package metal_backend

import gpu "../"

Metal_Surface :: struct {
	dummy: rawptr,
}

_metal_stub_vtable: gpu.Gpu_Backend_VTable = gpu.Gpu_Backend_VTable{
	shader_language = .MSL,
}

create_metal_backend :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_metal_stub_vtable
}

metal_backend_vtable :: proc() -> ^gpu.Gpu_Backend_VTable {
	return &_metal_stub_vtable
}

create_surface :: proc(layer: rawptr) -> ^Metal_Surface {
	return nil
}

destroy_surface :: proc(surf: ^Metal_Surface) {}

configure_surface_vibrancy :: proc(surf: ^Metal_Surface, opacity: f32, blur: f32) {}

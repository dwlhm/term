#+build !darwin
package metal

import contract "../../../render/contract"

Metal_Surface :: struct {
	dummy: rawptr,
}

_metal_stub_vtable: contract.Gpu_Backend_VTable = contract.Gpu_Backend_VTable{
	shader_language = .MSL,
}

create_metal_backend :: proc() -> ^contract.Gpu_Backend_VTable {
	return &_metal_stub_vtable
}

metal_backend_vtable :: proc() -> ^contract.Gpu_Backend_VTable {
	return &_metal_stub_vtable
}

create_surface :: proc(layer: rawptr) -> ^Metal_Surface {
	return nil
}

destroy_surface :: proc(surf: ^Metal_Surface) {}

configure_surface_vibrancy :: proc(surf: ^Metal_Surface, opacity: f32, blur: f32) {}

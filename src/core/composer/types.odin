package composer

// Package composer defines the core layer data types and geometry primitives
// for the OS-Style Layer Compositor Architecture.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime and contract "../render/contract".
//    No imports of terminal, chrome, ui, platform, or app.
// 2. Zero dynamic heap allocation during steady-state.
// 3. Strict adherence to Odin -strict-style.

import "base:runtime"
import contract "../render/contract"

Composer_Rect :: struct {
	x, y, w, h: f32,
}

Layer_Id :: distinct u32

CHROME_LAYER_ID: Layer_Id : 0xFFFF_FFFE
MODAL_LAYER_ID:  Layer_Id : 0xFFFF_FFFF

Layer_Kind :: enum int {
	Terminal,
	Chrome,
	Three_D,
	Overlay,
}

Composer_Layer :: struct {
	id:            Layer_Id,
	slot_index:    int,
	kind:          Layer_Kind,
	texture:       contract.Gpu_Texture,
	view:          contract.Gpu_TextureView,
	depth_texture: contract.Gpu_Texture,
	depth_view:    contract.Gpu_TextureView,
	has_depth:     bool,
	width:         u32,
	height:        u32,
	dest_rect:     Composer_Rect,
	scissor_rect:  Composer_Rect,
	is_dirty:      bool,
	opacity:       f32,
	corner_radius: f32,
	last_frame:    u64,
	version:       u32,
	in_use:        bool,
}

rect_make :: proc(x, y, w, h: f32) -> Composer_Rect {
	return Composer_Rect{x = x, y = y, w = w, h = h}
}

rect_contains :: proc(r: Composer_Rect, px, py: f32) -> bool {
	return px >= r.x && px < (r.x + r.w) &&
	       py >= r.y && py < (r.y + r.h)
}

package atlas

// 1024x2048 R8 Texture Font Atlas for core_render.
//
// Geometry Specification:
//   - Total Atlas Dimensions: 1024 x 2048 pixels (R8 format = 2,097,152 bytes)
//   - Grid Layout: 16 Columns x 32 Rows = 512 Glyph Slots
//   - Cell Dimension: 64 x 64 pixels per glyph slot (Retina @2x crisp monospace bounds)
//
// Pinned Slots (0..270):
//   - 0..94: ASCII Printable (0x20..0x7E)
//   - 95..222: Box Drawing (0x2500..0x257F)
//   - 223..254: Block Elements (0x2580..0x259F)
//   - 255..258: Powerline Symbols (0xE0B0..0xE0B3)
//   - 259..270: Pinned UI Chrome Symbols (Command, Option, Shift, Control, Return, etc.)
// Dynamic Slots (271..511):
//   - 241 dynamic FIFO fallback slots for unicode symbols / shaped runs.

import "base:runtime"
import "core:mem"
import contract "../contract"

// ============================================================================
// Atlas Geometry Constants
// ============================================================================

ATLAS_COLS :: 16
ATLAS_ROWS :: 32
ATLAS_GLYPH_SIZE :: 64
ATLAS_SLOT_COUNT :: ATLAS_COLS * ATLAS_ROWS // 512

ATLAS_WIDTH :: ATLAS_COLS * ATLAS_GLYPH_SIZE   // 1024 px
ATLAS_HEIGHT :: ATLAS_ROWS * ATLAS_GLYPH_SIZE // 2048 px
ATLAS_PIXELS_TOTAL :: ATLAS_WIDTH * ATLAS_HEIGHT // 2,097,152 bytes

PINNED_ASCII_BASE :: 0
PINNED_ASCII_COUNT :: 95

PINNED_BOX_BASE :: 95
PINNED_BOX_COUNT :: 128

PINNED_BLOCK_BASE :: 223
PINNED_BLOCK_COUNT :: 32

PINNED_POWERLINE_BASE :: 255
PINNED_POWERLINE_COUNT :: 4

PINNED_UI_BASE :: 259
PINNED_UI_COUNT :: 12

PINNED_TOTAL :: PINNED_UI_BASE + PINNED_UI_COUNT // 271
FALLBACK_BASE :: PINNED_TOTAL
FALLBACK_COUNT :: ATLAS_SLOT_COUNT - FALLBACK_BASE // 241

// Atlas_Slot: Sub-slot UV mapping and metrics for a rasterized glyph.
Atlas_Slot :: struct {
	u0:      f32,  // Left normalized texcoord (origin)
	v0:      f32,  // Top normalized texcoord (origin)
	u1:      f32,  // Right normalized texcoord (origin + ink width)
	v1:      f32,  // Bottom normalized texcoord (origin + cell height)
	advance: f32,  // Monospace advance in pixels
	valid:   bool, // True if slot is populated
}

// Atlas: Pure core_render font atlas resource state.
Atlas :: struct {
	slots:       [ATLAS_SLOT_COUNT]Atlas_Slot,
	pixels:      []u8,
	gpu_texture: contract.Gpu_Texture,
	gpu_view:    contract.Gpu_TextureView,
	gpu_dirty:   bool,
	allocator:   runtime.Allocator,
}

// ============================================================================
// Sub-Slot 1:1 Pixel Sampling UV Calculations
// ============================================================================

// atlas_slot_origin calculates the top-left pixel coordinates of a slot.
atlas_slot_origin :: #force_inline proc "contextless" (slot: u32) -> (px, py: u32) {
	s := slot % ATLAS_SLOT_COUNT
	px = (s % ATLAS_COLS) * ATLAS_GLYPH_SIZE
	py = (s / ATLAS_COLS) * ATLAS_GLYPH_SIZE
	return px, py
}

// atlas_slot_uv returns exact 1:1 pixel sampling UV bounds for a given slot.
// Eliminates distortion by sampling exact glyph ink bounds (gw by gh) within
// the 64x64 pixel slot cell.
atlas_slot_uv :: #force_inline proc "contextless" (slot: u32, gw, gh: f32) -> (u0, v0, u1, v1: f32) {
	px, py := atlas_slot_origin(slot)
	aw := f32(ATLAS_WIDTH)
	ah := f32(ATLAS_HEIGHT)

	u0 = f32(px) / aw
	v0 = f32(py) / ah
	u1 = u0 + gw / aw
	v1 = v0 + gh / ah
	return u0, v0, u1, v1
}

// ============================================================================
// Atlas Lifecycle & Management
// ============================================================================

atlas_init :: proc(a: ^Atlas, allocator: runtime.Allocator = context.allocator) -> bool {
	if a == nil do return false
	a.allocator = allocator
	a.pixels = make([]u8, ATLAS_PIXELS_TOTAL, allocator)
	if a.pixels == nil do return false
	mem.zero_slice(a.pixels)

	// Pre-populate canonical UV origins for all slots
	for i in 0..<ATLAS_SLOT_COUNT {
		u0, v0, u1, v1 := atlas_slot_uv(u32(i), f32(ATLAS_GLYPH_SIZE), f32(ATLAS_GLYPH_SIZE))
		a.slots[i] = Atlas_Slot{
			u0      = u0,
			v0      = v0,
			u1      = u1,
			v1      = v1,
			advance = f32(ATLAS_GLYPH_SIZE),
			valid   = false,
		}
	}
	a.gpu_dirty = true
	return true
}

atlas_destroy :: proc(a: ^Atlas, vtable: ^contract.Gpu_Backend_VTable = nil) {
	if a == nil do return
	if len(a.pixels) > 0 {
		delete(a.pixels, a.allocator)
		a.pixels = nil
	}
	if vtable != nil {
		if rawptr(a.gpu_view) != nil && vtable.destroy_texture_view != nil {
			vtable.destroy_texture_view(a.gpu_view)
			a.gpu_view = contract.Gpu_TextureView(nil)
		}
		if rawptr(a.gpu_texture) != nil && vtable.destroy_texture != nil {
			vtable.destroy_texture(a.gpu_texture)
			a.gpu_texture = contract.Gpu_Texture(nil)
		}
	}
}

// atlas_upload_gpu synchronizes CPU pixel buffer to GPU texture via VTable.
atlas_upload_gpu :: proc(
	a: ^Atlas,
	vtable: ^contract.Gpu_Backend_VTable,
	device: contract.Gpu_Device,
	queue: contract.Gpu_Queue,
) -> bool {
	if a == nil || vtable == nil do return false
	if !a.gpu_dirty && rawptr(a.gpu_texture) != nil do return true

	if rawptr(a.gpu_texture) == nil {
		usage := contract.Gpu_Texture_Usage.Copy_Dst | contract.Gpu_Texture_Usage.Texture_Binding
		a.gpu_texture = vtable.create_texture(device, ATLAS_WIDTH, ATLAS_HEIGHT, .R8_Unorm, usage)
		if rawptr(a.gpu_texture) == nil do return false
		a.gpu_view = vtable.create_texture_view(a.gpu_texture)
		if rawptr(a.gpu_view) == nil do return false
	}

	if vtable.write_texture != nil && len(a.pixels) > 0 {
		vtable.write_texture(queue, a.gpu_texture, a.pixels, ATLAS_WIDTH, ATLAS_HEIGHT)
		a.gpu_dirty = false
		return true
	}
	return false
}

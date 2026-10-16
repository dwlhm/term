package term

// GPU Atlas Memory, Dynamic Prewarm & UV Mapping Manager
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:mem"
import core_atlas "../../core/render/atlas"
import contract "../../core/render/contract"

PINNED_UI_CODEPOINTS := [12]rune{
	0x2318, // ⌘ command
	0x2325, // ⌥ option
	0x21E7, // ⇧ shift
	0x2303, // ⌃ control
	0x21E5, // ⇥ tab
	0x21B5, // ↵ return
	0x2715, // ✕ close
	0x00B7, // · middle dot
	0x2026, // … horizontal ellipsis
	0x2191, // ↑ up arrow
	0x2193, // ↓ down arrow
	0x25CB, // ○ white circle
}

Glyph_Atlas_Manager :: struct {
	atlas:           core_atlas.Atlas,
	fc:              ^Font_Context,
	dynamic_slots:   [core_atlas.FALLBACK_COUNT]rune,
	dynamic_clusters: [core_atlas.FALLBACK_COUNT]u64,
	dynamic_cursor:  int,
	lookup_cache:    map[rune]u32,
	cluster_cache:   map[u64]u32,
}

glyph_atlas_init :: proc(gam: ^Glyph_Atlas_Manager, fc: ^Font_Context) -> bool {
	if gam == nil do return false
	if !core_atlas.atlas_init(&gam.atlas) do return false
	gam.fc = fc
	gam.lookup_cache = make(map[rune]u32, 512)
	gam.cluster_cache = make(map[u64]u32, 64)
	gam.dynamic_cursor = 0

	// 1. Prewarm ASCII (0x20 .. 0x7E)
	for cp in u32(0x20)..=0x7E {
		slot := u32(core_atlas.PINNED_ASCII_BASE + (cp - 0x20))
		px, py := core_atlas.atlas_slot_origin(slot)

		if fc != nil && font_has_codepoint(fc, cp) {
			font_rasterize_codepoint(
				fc, cp, gam.atlas.pixels,
				core_atlas.ATLAS_WIDTH, int(px), int(py),
				core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			)
		} else if cp > 0x20 {
			_draw_fallback_box(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), cp)
		}
		gam.atlas.slots[slot].valid = true
	}

	// 2. Prewarm Box Drawing (0x2500 .. 0x257F)
	for cp in u32(0x2500)..=0x257F {
		slot := u32(core_atlas.PINNED_BOX_BASE + (cp - 0x2500))
		px, py := core_atlas.atlas_slot_origin(slot)

		if fc != nil && font_has_codepoint(fc, cp) {
			font_rasterize_codepoint(
				fc, cp, gam.atlas.pixels,
				core_atlas.ATLAS_WIDTH, int(px), int(py),
				core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			)
		} else {
			_draw_procedural_box_drawing(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), cp)
		}
		gam.atlas.slots[slot].valid = true
	}

	// 3. Prewarm Block Elements (0x2580 .. 0x259F)
	for cp in u32(0x2580)..=0x259F {
		slot := u32(core_atlas.PINNED_BLOCK_BASE + (cp - 0x2580))
		px, py := core_atlas.atlas_slot_origin(slot)

		if fc != nil && font_has_codepoint(fc, cp) {
			font_rasterize_codepoint(
				fc, cp, gam.atlas.pixels,
				core_atlas.ATLAS_WIDTH, int(px), int(py),
				core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			)
		} else {
			_draw_procedural_block_element(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), cp)
		}
		gam.atlas.slots[slot].valid = true
	}

	// 4. Prewarm Powerline Symbols (0xE0B0 .. 0xE0B3)
	for cp in u32(0xE0B0)..=0xE0B3 {
		slot := u32(core_atlas.PINNED_POWERLINE_BASE + (cp - 0xE0B0))
		px, py := core_atlas.atlas_slot_origin(slot)

		if fc != nil && font_has_codepoint(fc, cp) {
			font_rasterize_codepoint(
				fc, cp, gam.atlas.pixels,
				core_atlas.ATLAS_WIDTH, int(px), int(py),
				core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			)
		}
		gam.atlas.slots[slot].valid = true
	}

	// 5. Prewarm UI Symbols (Command, Option, Arrows, etc.)
	for cp, idx in PINNED_UI_CODEPOINTS {
		slot := u32(core_atlas.PINNED_UI_BASE + idx)
		px, py := core_atlas.atlas_slot_origin(slot)

		if fc != nil && font_has_codepoint(fc, u32(cp)) {
			font_rasterize_codepoint(
				fc, u32(cp), gam.atlas.pixels,
				core_atlas.ATLAS_WIDTH, int(px), int(py),
				core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			)
		}
		gam.atlas.slots[slot].valid = true
	}

	return true
}

glyph_atlas_upload :: proc(gam: ^Glyph_Atlas_Manager, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if gam == nil do return false
	return core_atlas.atlas_upload_gpu(&gam.atlas, device, queue)
}

glyph_atlas_destroy :: proc(gam: ^Glyph_Atlas_Manager) {
	if gam == nil do return
	delete(gam.lookup_cache)
	delete(gam.cluster_cache)
	core_atlas.atlas_destroy(&gam.atlas)
}

// glyph_atlas_lookup_slot performs O(1) static range check for pinned glyphs.
glyph_atlas_lookup_slot :: proc(cp: rune) -> (slot: u32, ok: bool) {
	u := u32(cp)
	if u >= 0x20 && u <= 0x7E {
		return u32(core_atlas.PINNED_ASCII_BASE + (u - 0x20)), true
	}
	if u >= 0x2500 && u <= 0x257F {
		return u32(core_atlas.PINNED_BOX_BASE + (u - 0x2500)), true
	}
	if u >= 0x2580 && u <= 0x259F {
		return u32(core_atlas.PINNED_BLOCK_BASE + (u - 0x2580)), true
	}
	if u >= 0xE0B0 && u <= 0xE0B3 {
		return u32(core_atlas.PINNED_POWERLINE_BASE + (u - 0xE0B0)), true
	}
	for p_cp, idx in PINNED_UI_CODEPOINTS {
		if cp == p_cp {
			return u32(core_atlas.PINNED_UI_BASE + idx), true
		}
	}
	return 0, false
}

// glyph_atlas_get_or_rasterize looks up any codepoint (ASCII, box, block, nerd font, braille, emoji, unicode)
// and dynamically allocates, rasterizes, and caches it in the atlas fallback region if not yet present.
glyph_atlas_get_or_rasterize :: proc(gam: ^Glyph_Atlas_Manager, cp: rune, is_wide: bool = false) -> (slot: u32, ok: bool) {
	if gam == nil do return 0, false

	// 1. Pinned slots
	if p_slot, p_ok := glyph_atlas_lookup_slot(cp); p_ok {
		return p_slot, true
	}

	// 2. Dynamic cache hit
	if cached_slot, found := gam.lookup_cache[cp]; found {
		return cached_slot, true
	}

	// 3. Dynamic cache miss: allocate FIFO fallback slot
	slot_idx := u32(core_atlas.FALLBACK_BASE + (gam.dynamic_cursor % core_atlas.FALLBACK_COUNT))
	gam.dynamic_cursor = (gam.dynamic_cursor + 1) % core_atlas.FALLBACK_COUNT

	old_rune := gam.dynamic_slots[slot_idx - core_atlas.FALLBACK_BASE]
	if old_rune != 0 {
		delete_key(&gam.lookup_cache, old_rune)
	}
	old_cluster := gam.dynamic_clusters[slot_idx - core_atlas.FALLBACK_BASE]
	if old_cluster != 0 {
		delete_key(&gam.cluster_cache, old_cluster)
	}

	// Clear slot pixels (64x64)
	px, py := core_atlas.atlas_slot_origin(slot_idx)
	for y in 0..<core_atlas.ATLAS_GLYPH_SIZE {
		start := int(py + u32(y)) * core_atlas.ATLAS_WIDTH + int(px)
		mem.zero_slice(gam.atlas.pixels[start : start + core_atlas.ATLAS_GLYPH_SIZE])
	}

	u := u32(cp)
	rendered := false
	if gam.fc != nil && font_has_codepoint(gam.fc, u) {
		font_rasterize_codepoint(
			gam.fc, u, gam.atlas.pixels,
			core_atlas.ATLAS_WIDTH, int(px), int(py),
			core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			is_wide,
		)
		rendered = true
	} else if u >= 0x2800 && u <= 0x28FF {
		// Procedural Braille fallback if font does not cover Braille patterns
		_draw_procedural_braille(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), u)
		rendered = true
	} else if cp > 0x20 {
		// Visible fallback box outline
		_draw_fallback_box(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), u, is_wide)
		rendered = true
	}

	gam.atlas.slots[slot_idx].valid = rendered
	gam.atlas.gpu_dirty = true
	gam.dynamic_slots[slot_idx - core_atlas.FALLBACK_BASE] = cp
	gam.dynamic_clusters[slot_idx - core_atlas.FALLBACK_BASE] = 0
	gam.lookup_cache[cp] = slot_idx

	return slot_idx, true
}

// glyph_atlas_get_or_rasterize_cluster rasterizes a grapheme cluster (base +
// combining marks) into a FIFO fallback slot, cached by cluster hash.
glyph_atlas_get_or_rasterize_cluster :: proc(gam: ^Glyph_Atlas_Manager, runes: []rune, is_wide: bool = false) -> (slot: u32, ok: bool) {
	if gam == nil || len(runes) == 0 do return 0, false

	key := _cluster_hash(runes)
	if cached, found := gam.cluster_cache[key]; found do return cached, true

	slot_idx := u32(core_atlas.FALLBACK_BASE + (gam.dynamic_cursor % core_atlas.FALLBACK_COUNT))
	gam.dynamic_cursor = (gam.dynamic_cursor + 1) % core_atlas.FALLBACK_COUNT

	pos := slot_idx - core_atlas.FALLBACK_BASE
	old_rune := gam.dynamic_slots[pos]
	if old_rune != 0 {
		delete_key(&gam.lookup_cache, old_rune)
	}
	old_cluster := gam.dynamic_clusters[pos]
	if old_cluster != 0 {
		delete_key(&gam.cluster_cache, old_cluster)
	}

	px, py := core_atlas.atlas_slot_origin(slot_idx)
	for y in 0..<core_atlas.ATLAS_GLYPH_SIZE {
		start := int(py + u32(y)) * core_atlas.ATLAS_WIDTH + int(px)
		mem.zero_slice(gam.atlas.pixels[start : start + core_atlas.ATLAS_GLYPH_SIZE])
	}

	rendered := false
	if gam.fc != nil {
		font_rasterize_cluster_into(
			gam.fc, runes, gam.atlas.pixels,
			core_atlas.ATLAS_WIDTH, int(px), int(py),
			core_atlas.ATLAS_GLYPH_SIZE, core_atlas.ATLAS_GLYPH_SIZE,
			is_wide,
		)
		rendered = true
	} else {
		_draw_fallback_box(gam.atlas.pixels, core_atlas.ATLAS_WIDTH, int(px), int(py), u32(runes[0]), is_wide)
		rendered = true
	}

	gam.atlas.slots[slot_idx].valid = rendered
	gam.atlas.gpu_dirty = true
	gam.dynamic_slots[pos] = 0
	gam.dynamic_clusters[pos] = key
	gam.cluster_cache[key] = slot_idx

	return slot_idx, true
}

// Procedural fallbacks for Box Drawing & Blocks
_draw_fallback_box :: proc(pixels: []u8, pitch, px, py: int, cp: u32, is_wide: bool = false) {
	bw := 50 if is_wide else 24
	bh := 36
	bx := px + (core_atlas.ATLAS_GLYPH_SIZE - bw) / 2
	by := py + (core_atlas.ATLAS_GLYPH_SIZE - bh) / 2
	for y in 0..<bh {
		for x in 0..<bw {
			if x == 0 || x == bw - 1 || y == 0 || y == bh - 1 || ((x * 3 + y * 7 + int(cp)) % 5 == 0) {
				pixels[(by + y) * pitch + (bx + x)] = 255
			}
		}
	}
}

_draw_procedural_braille :: proc(pixels: []u8, pitch, px, py: int, cp: u32) {
	// Unicode Braille Pattern: 0x2800 + 8-bit mask
	// Dot 1: 0x01 (top left)       Dot 4: 0x08 (top right)
	// Dot 2: 0x02 (mid-top left)   Dot 5: 0x10 (mid-top right)
	// Dot 3: 0x04 (mid-low left)   Dot 6: 0x20 (mid-low right)
	// Dot 7: 0x40 (bottom left)    Dot 8: 0x80 (bottom right)
	mask := cp - 0x2800

	dot_coords := [8][2]int{
		{20, 14}, // Dot 1
		{20, 24}, // Dot 2
		{20, 34}, // Dot 3
		{36, 14}, // Dot 4
		{36, 24}, // Dot 5
		{36, 34}, // Dot 6
		{20, 44}, // Dot 7
		{36, 44}, // Dot 8
	}

	for i in 0..<8 {
		if (mask & (1 << uint(i))) != 0 {
			cx := px + dot_coords[i][0]
			cy := py + dot_coords[i][1]
			for dy in -1..=1 {
				for dx in -1..=1 {
					pixels[(cy + dy) * pitch + (cx + dx)] = 255
				}
			}
		}
	}
}

_draw_procedural_box_drawing :: proc(pixels: []u8, pitch, px, py: int, cp: u32) {
	mid_x := px + core_atlas.ATLAS_GLYPH_SIZE / 2
	mid_y := py + core_atlas.ATLAS_GLYPH_SIZE / 2

	// Draw standard cross or border lines
	for y in 0..<core_atlas.ATLAS_GLYPH_SIZE {
		pixels[(py + y) * pitch + mid_x] = 220
		pixels[(py + y) * pitch + (mid_x + 1)] = 220
	}
	for x in 0..<core_atlas.ATLAS_GLYPH_SIZE {
		pixels[mid_y * pitch + (px + x)] = 220
		pixels[(mid_y + 1) * pitch + (px + x)] = 220
	}
}

_draw_procedural_block_element :: proc(pixels: []u8, pitch, px, py: int, cp: u32) {
	// Full block (0x2588) or upper/lower half
	half_h := core_atlas.ATLAS_GLYPH_SIZE / 2
	y_start := 0
	y_end := core_atlas.ATLAS_GLYPH_SIZE

	if cp == 0x2580 { // Upper half
		y_end = half_h
	} else if cp == 0x2584 { // Lower half
		y_start = half_h
	}

	for y in y_start..<y_end {
		for x in 4..<(core_atlas.ATLAS_GLYPH_SIZE - 4) {
			pixels[(py + y) * pitch + (px + x)] = 255
		}
	}
}

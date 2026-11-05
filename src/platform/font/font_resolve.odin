package platform_font

// Per-Codepoint Face Resolution & Lazy OS Fallback Discovery
// Platform Font Subsystem (src/platform/font/*).
//
// Invariant: the startup cascade cannot cover all of Unicode, so a codepoint
// missing from every loaded face asks the OS which font covers it and appends
// that face once. Misses the OS cannot satisfy are remembered in a fixed-size
// direct-mapped cache so blank cells never re-query the OS per frame.
// Callers must hold `fc.font_mutex` (the async rasterizer shares the chain).

import "core:strings"

FONT_MISS_CACHE_SIZE :: 256
// Slots left free after startup for codepoints discovered on demand.
FALLBACK_INIT_LIMIT :: MAX_FALLBACKS - 12

_font_face_for_codepoint :: proc(fc: ^Font_Context, cp: u32) -> ^Font_Rasterizer {
	if fc == nil do return nil
	if fc.has_font && font_rasterizer_find_glyph_index(&fc.rasterizer, cp) != 0 do return &fc.rasterizer
	for i in 0..<fc.fallback_count {
		if font_rasterizer_find_glyph_index(&fc.fallbacks[i], cp) != 0 do return &fc.fallbacks[i]
	}
	return _discover_face_for_codepoint(fc, cp)
}

@(private = "file")
_discover_face_for_codepoint :: proc(fc: ^Font_Context, cp: u32) -> ^Font_Rasterizer {
	if !fc.has_font || cp < 0x20 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) do return nil
	slot := &fc.miss_cache[cp % FONT_MISS_CACHE_SIZE]
	if slot^ == cp + 1 do return nil

	path, ok := platform_query_font_for_codepoint(cp, context.allocator, fc.style_class)
	defer delete(path)
	if ok && _try_append_fallback(fc, path, fc.pixel_size) {
		face := &fc.fallbacks[fc.fallback_count - 1]
		if font_rasterizer_find_glyph_index(face, cp) != 0 do return face
	}
	slot^ = cp + 1
	return nil
}

// _try_append_fallback loads `path` into the next free fallback slot unless it
// is already in the chain or is a color-bitmap face (sbix/CBDT glyphs rasterize
// blank in the grayscale atlas; color emoji go through Emoji_Atlas_Manager).
// A new face can cover earlier misses, so it resets the miss cache.
_try_append_fallback :: proc(fc: ^Font_Context, path: string, pixel_size: f32) -> bool {
	if fc.fallback_count >= MAX_FALLBACKS || len(path) == 0 do return false
	if path == fc.active_path do return false
	for i in 0..<fc.fallback_count {
		if fc.fallback_paths[i] == path do return false
	}
	err: Font_Error
	face := &fc.fallbacks[fc.fallback_count]
	if !font_rasterizer_init(face, path, pixel_size, &err) do return false
	if face.face.face_flags & FT_FACE_FLAG_COLOR != 0 {
		font_rasterizer_destroy(face)
		return false
	}
	fc.fallback_paths[fc.fallback_count] = strings.clone(path)
	fc.fallback_count += 1
	fc.miss_cache = {}
	return true
}

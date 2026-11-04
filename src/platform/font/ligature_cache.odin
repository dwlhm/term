package platform_font

// Font Ligatures Cache (Tier 2 Feature Primitive)
// Platform Font Subsystem (src/platform/font/*).
//
// Invariant: Zero heap allocations on hot render paths.
// A ligature depends on its whole symbol run (OpenType `calt` looks at the
// neighbours), so the cache key is the complete run, never a slice of it:
// "===" is a ligature while "====" is four plain equals signs.

import "core:c"

LIGATURE_CACHE_CAP    :: 256
LIGATURE_RUN_MAX      :: 512
LIGATURE_POOL_CAP     :: 16384
CONTENT_LIGATURE_BASE :: u32(0x120000)

// Entries are reset together once the table passes this load or the pool fills.
@(private = "file")
LIGATURE_CACHE_LOAD_MAX :: LIGATURE_CACHE_CAP * 3 / 4

Ligature_Entry :: struct {
	hash:         u64,
	offset:       u32, // run bytes and glyphs live at the same offset in the pools
	length:       u16,
	has_ligature: bool, // false = sentinel (the font draws this run unchanged)
	valid:        bool,
}

Ligature_Cache :: struct {
	entries:   [LIGATURE_CACHE_CAP]Ligature_Entry,
	bytes:     [LIGATURE_POOL_CAP]u8,
	glyphs:    [LIGATURE_POOL_CAP]u32,
	pool_used: int,
	count:     int,
}

ligature_cache_init :: proc(cache: ^Ligature_Cache) {
	if cache == nil do return
	cache^ = Ligature_Cache{}
}

is_ligature_candidate :: proc "contextless" (b: u8) -> bool {
	switch b {
	case '=', '>', '<', '-', '+', '!', '*', '&', '|', '/', ':', '~', '^', '.', '?':
		return true
	}
	return false
}

// ligature_cache_lookup shapes a complete symbol run and returns one glyph per
// cell. A glyph of 0 means the cell keeps its plain character. Runs the font
// does not map one glyph per character are reported as non-ligatures, since
// their glyphs cannot be placed on the cell grid.
ligature_cache_lookup :: proc(
	cache: ^Ligature_Cache,
	r: ^Font_Rasterizer,
	text: []u8,
) -> (glyphs: []u32, is_ligature: bool) {
	if cache == nil || len(text) < 2 || len(text) > LIGATURE_RUN_MAX {
		return nil, false
	}

	h := _run_hash(text)
	idx := int(h % LIGATURE_CACHE_CAP)
	for cache.entries[idx].valid {
		entry := &cache.entries[idx]
		if entry.hash == h && int(entry.length) == len(text) &&
		   string(cache.bytes[entry.offset:][:len(text)]) == string(text) {
			if !entry.has_ligature do return nil, false
			return cache.glyphs[entry.offset:][:len(text)], true
		}
		idx = (idx + 1) % LIGATURE_CACHE_CAP
	}

	if r == nil || r.face == nil || r.hb_font == nil {
		return nil, false
	}

	if cache.count >= LIGATURE_CACHE_LOAD_MAX || cache.pool_used + len(text) > LIGATURE_POOL_CAP {
		ligature_cache_init(cache)
		idx = int(h % LIGATURE_CACHE_CAP)
	}

	offset := cache.pool_used
	out := cache.glyphs[offset:][:len(text)]
	formed := _shape_run(r, text, out)
	copy(cache.bytes[offset:][:len(text)], text)
	cache.pool_used += len(text)
	cache.count += 1
	cache.entries[idx] = Ligature_Entry{
		hash         = h,
		offset       = u32(offset),
		length       = u16(len(text)),
		has_ligature = formed,
		valid        = true,
	}
	if !formed do return nil, false
	return out, true
}

@(private = "file")
_run_hash :: proc "contextless" (text: []u8) -> u64 {
	h: u64 = 14695981039346656037
	for b in text {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

// _shape_run fills `out` with the shaped glyph of every changed cell (0 for
// unchanged cells) and reports whether any cell changed.
@(private = "file")
_shape_run :: proc(r: ^Font_Rasterizer, text: []u8, out: []u32) -> bool {
	cps: [LIGATURE_RUN_MAX]u32
	for b, i in text do cps[i] = u32(b)

	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)
	hb_buffer_add_codepoints(buf, raw_data(cps[:]), c.int(len(text)), 0, c.int(len(text)))
	hb_buffer_guess_segment_properties(buf)
	hb_shape(r.hb_font, buf, nil, 0)

	glyph_count: c.uint
	infos := hb_buffer_get_glyph_infos(buf, &glyph_count)
	if int(glyph_count) != len(text) do return false
	for i in 0..<len(text) {
		if infos[i].cluster != u32(i) do return false
	}

	formed := false
	for i in 0..<len(text) {
		g := infos[i].codepoint
		if g == font_rasterizer_find_glyph_index(r, cps[i]) {
			out[i] = 0
		} else {
			out[i] = g
			formed = true
		}
	}
	return formed
}

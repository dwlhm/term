package platform_font

// Font Ligatures Cache (Tier 2 Feature Primitive)
// Platform Font Subsystem (src/platform/font/*).
//
// Invariant: Zero heap allocations on hot render paths.
// Pre-allocated 128-slot hash cache for 2..4 byte programming symbols.

LIGATURE_CACHE_CAP    :: 128
LIGATURE_MAX_LEN      :: 4
CONTENT_LIGATURE_BASE :: u32(0x120000)

Ligature_Entry :: struct {
	key:         [LIGATURE_MAX_LEN]u8,
	key_len:     u8,
	glyph_ids:   [LIGATURE_MAX_LEN]u32,
	glyph_count: u8, // 0 = sentinel (not a ligature in this font)
	valid:       bool,
}

Ligature_Cache :: struct {
	entries: [LIGATURE_CACHE_CAP]Ligature_Entry,
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

ligature_cache_lookup :: proc(
	cache: ^Ligature_Cache,
	r: ^Font_Rasterizer,
	text: []u8,
) -> (glyphs: []u32, is_ligature: bool) {
	if cache == nil || len(text) < 2 || len(text) > LIGATURE_MAX_LEN {
		return nil, false
	}

	// FNV-1a hash of text
	h: u32 = 2166136261
	for b in text {
		h = (h ~ u32(b)) * 16777619
	}
	hash_idx := int(h % LIGATURE_CACHE_CAP)
	slot_to_use := hash_idx
	found_empty := false

	// Linear probe up to 4 slots
	for p in 0..<4 {
		idx := (hash_idx + p) % LIGATURE_CACHE_CAP
		entry := &cache.entries[idx]
		if !entry.valid {
			if !found_empty {
				slot_to_use = idx
				found_empty = true
			}
			continue
		}
		if entry.key_len == u8(len(text)) {
			match := true
			for i in 0..<len(text) {
				if entry.key[i] != text[i] {
					match = false
					break
				}
			}
			if match {
				if entry.glyph_count == 0 do return nil, false
				return entry.glyph_ids[:entry.glyph_count], true
			}
		}
	}

	if r == nil || r.face == nil || r.hb_font == nil {
		return nil, false
	}

	runes: [LIGATURE_MAX_LEN]rune
	for b, i in text {
		runes[i] = rune(b)
	}

	cluster, ok := font_shape_cluster(r, runes[:len(text)])
	if !ok || cluster.glyph_count == 0 {
		return nil, false
	}

	// A ligature is formed if glyph count differs from character count,
	// or if any shaped glyph ID differs from the unshaped FT_Get_Char_Index!
	lig_formed := int(cluster.glyph_count) != len(text)
	if !lig_formed {
		for k in 0..<len(text) {
			unshaped := font_rasterizer_find_glyph_index(r, u32(text[k]))
			if cluster.glyphs[k].glyph_id != unshaped {
				lig_formed = true
				break
			}
		}
	}

	target := &cache.entries[slot_to_use]
	target.valid = true
	target.key_len = u8(len(text))
	for k in 0..<len(text) {
		target.key[k] = text[k]
	}

	if lig_formed && cluster.glyph_count > 0 {
		count := min(int(cluster.glyph_count), LIGATURE_MAX_LEN)
		target.glyph_count = u8(count)
		for k in 0..<count {
			target.glyph_ids[k] = cluster.glyphs[k].glyph_id
		}
		return target.glyph_ids[:target.glyph_count], true
	} else {
		target.glyph_count = 0 // sentinel
		return nil, false
	}
}

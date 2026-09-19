package render

import "core:c"

LIGATURE_CACHE_CAP :: 128
LIGATURE_MAX_LEN   :: 4
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

ligature_cache_lookup :: proc(
	cache: ^Ligature_Cache,
	font: ^Font_Rasterizer,
	text: []u8,
) -> (glyphs: []u32, is_ligature: bool) {
	if cache == nil || len(text) < 2 || len(text) > LIGATURE_MAX_LEN {
		return nil, false
	}

	// Calculate hash of text (2..4 bytes) modulo LIGATURE_CACHE_CAP
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
				if entry.glyph_count == 0 {
					return nil, false
				}
				return entry.glyph_ids[:entry.glyph_count], true
			}
		}
	}

	if font == nil || font.face == nil || font.hb_font == nil {
		return nil, false
	}

	// Call HarfBuzz hb_shape on text
	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)
	hb_buffer_add_utf8(buf, raw_data(text), c.int(len(text)), 0, c.int(len(text)))
	hb_buffer_guess_segment_properties(buf)
	hb_shape(font.hb_font, buf, nil, 0)
	glyph_count: c.uint
	infos := hb_buffer_get_glyph_infos(buf, &glyph_count)
	if infos == nil {
		return nil, false
	}

	// Determine if ligature formed:
	// Compare output glyph IDs with unshaped fallback glyph IDs (from FT_Get_Char_Index(font.face, ...))
	lig_formed: bool = int(glyph_count) != len(text)
	if !lig_formed {
		for k in 0..<len(text) {
			unshaped := FT_Get_Char_Index(font.face, FT_ULong(text[k]))
			if infos[k].codepoint != u32(unshaped) {
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

	if lig_formed && glyph_count > 0 {
		count := min(int(glyph_count), LIGATURE_MAX_LEN)
		target.glyph_count = u8(count)
		for k in 0..<count {
			target.glyph_ids[k] = infos[k].codepoint
		}
		return target.glyph_ids[:target.glyph_count], true
	} else {
		target.glyph_count = 0 // sentinel
		return nil, false
	}
}

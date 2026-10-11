package render

// Shape cache: Two-Tier Cache mapping a cluster's value identity
// (base + combining marks) to its resolved glyph(s). Fixed arrays, zero allocation.
// Tier 1: Single-glyph direct cache (Shaped_Glyph)
// Tier 2: Cluster-Level HarfBuzz shaped multi-glyph storage (Shaped_Cluster)

import termgrid "../terminal"

// SHAPE_CACHE_CAP bounds the cache.
SHAPE_CACHE_CAP :: 1024

// MAX_CLUSTER_GLYPHS caps the maximum glyphs in a single shaped cluster.
MAX_CLUSTER_GLYPHS :: 8

// Cluster_Glyph represents a single glyph output from HarfBuzz cluster shaping.
Cluster_Glyph :: struct {
	glyph_id:  u32,  // HarfBuzz / FreeType glyph ID
	x_advance: f32,  // horizontal advance in pixels
	x_offset:  f32,  // horizontal offset from pen position
	y_offset:  f32,  // vertical offset from baseline
}

// Shaped_Cluster holds the complete multi-glyph shaped result for complex text clusters.
Shaped_Cluster :: struct {
	font_index:  u8,
	glyph_count: u8,
	atlas_slot:  u16,
	wide:        bool,
	glyphs:      [MAX_CLUSTER_GLYPHS]Cluster_Glyph,
}

// Cluster_Key is the value identity of one grapheme cluster.
Cluster_Key :: struct {
	runes:      [termgrid.GRAPHEME_INLINE_CAP]rune,
	rune_count: u8,
}

// cluster_key_make constructs a Cluster_Key from a single base rune.
cluster_key_make :: proc(base: rune) -> Cluster_Key {
	k: Cluster_Key
	k.runes[0] = base
	k.rune_count = 1
	return k
}

// Shaped_Glyph is one resolved glyph entry (Tier 1). atlas_slot 0x1FF is UNRESOLVED.
Shaped_Glyph :: struct {
	font_index:       u8,
	glyph_id:         u32, // HarfBuzz / FreeType glyph ID
	shaped_codepoint: u32,
	atlas_slot:       u16,
	advance:          f32,
	wide:             bool,
}

// Shape_Cache is a Two-Tier open-addressed linear-probe cache with fixed storage.
Shape_Cache :: struct {
	// Tier 1: Single-glyph / direct shape cache
	keys:              [SHAPE_CACHE_CAP]Cluster_Key,
	values:            [SHAPE_CACHE_CAP]Shaped_Glyph,
	occupied:          [SHAPE_CACHE_CAP]bool,
	live:              int,
	evictions:         u64,

	// Tier 2: Cluster-Level storage for HarfBuzz multi-glyph sequences
	cluster_keys:      [SHAPE_CACHE_CAP]Cluster_Key,
	cluster_values:    [SHAPE_CACHE_CAP]Shaped_Cluster,
	cluster_occupied:  [SHAPE_CACHE_CAP]bool,
	cluster_live:      int,
	cluster_evictions: u64,
}

// cluster_key_from_handle copies a handle's cluster identity by value.
cluster_key_from_handle :: proc(
	h: termgrid.Content_Handle,
	store: ^termgrid.Grapheme_Store,
) -> Cluster_Key {
	if !termgrid.content_is_grapheme(h) {
		return cluster_key_make(rune(h))
	}
	if store == nil {
		return cluster_key_make(0xFFFD)
	}
	idx := int(h - termgrid.CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= termgrid.GRAPHEME_STORE_CAP {
		return cluster_key_make(0xFFFD)
	}
	e := &store.entries[idx]
	k: Cluster_Key
	count := min(int(e.rune_count), termgrid.GRAPHEME_INLINE_CAP)
	for i in 0..<count {
		k.runes[i] = e.runes[i]
	}
	k.rune_count = u8(count)
	return k
}

// cluster_key_hash is FNV-1a over the key's runes with the rune count mixed in.
cluster_key_hash :: proc(k: Cluster_Key) -> u32 {
	h := u32(2166136261)
	mix_byte :: proc(h: u32, b: u8) -> u32 {
		return (h ~ u32(b)) * 16777619
	}
	shifts := [4]u32{0, 8, 16, 24}
	count := min(int(k.rune_count), termgrid.GRAPHEME_INLINE_CAP)
	for i in 0..<count {
		r := u32(k.runes[i])
		for shift in shifts {
			h = mix_byte(h, u8((r >> shift) & 0xFF))
		}
	}
	h = mix_byte(h, k.rune_count)
	return h
}

// shape_cache_lookup probes Tier 1 linearly. Pure read: never mutates.
shape_cache_lookup :: proc(c: ^Shape_Cache, k: Cluster_Key) -> (g: Shaped_Glyph, hit: bool) {
	if c == nil {
		return {}, false
	}
	h := cluster_key_hash(k)
	for i in 0..<SHAPE_CACHE_CAP {
		idx := int((h + u32(i)) & (SHAPE_CACHE_CAP - 1))
		if !c.occupied[idx] {
			return {}, false
		}
		if c.keys[idx] == k {
			return c.values[idx], true
		}
	}
	return {}, false
}

// shape_cache_insert stores or updates a Tier 1 entry.
shape_cache_insert :: proc(c: ^Shape_Cache, k: Cluster_Key, g: Shaped_Glyph) {
	if c == nil {
		return
	}
	h := cluster_key_hash(k)
	first := int(h & (SHAPE_CACHE_CAP - 1))
	for i in 0..<SHAPE_CACHE_CAP {
		idx := (first + i) & (SHAPE_CACHE_CAP - 1)
		if c.occupied[idx] {
			if c.keys[idx] == k {
				c.values[idx] = g
				return
			}
			continue
		}
		c.occupied[idx] = true
		c.keys[idx] = k
		c.values[idx] = g
		c.live += 1
		return
	}
	c.keys[first] = k
	c.values[first] = g
	c.evictions += 1
}

// shape_cache_lookup_cluster probes Tier 2 (Cluster-Level) cache.
shape_cache_lookup_cluster :: proc(c: ^Shape_Cache, k: Cluster_Key) -> (cluster: Shaped_Cluster, hit: bool) {
	if c == nil {
		return {}, false
	}
	h := cluster_key_hash(k)
	for i in 0..<SHAPE_CACHE_CAP {
		idx := int((h + u32(i)) & (SHAPE_CACHE_CAP - 1))
		if !c.cluster_occupied[idx] {
			return {}, false
		}
		if c.cluster_keys[idx] == k {
			return c.cluster_values[idx], true
		}
	}
	return {}, false
}

// shape_cache_insert_cluster stores or updates a Tier 2 (Cluster-Level) entry.
shape_cache_insert_cluster :: proc(c: ^Shape_Cache, k: Cluster_Key, cluster: Shaped_Cluster) {
	if c == nil {
		return
	}
	h := cluster_key_hash(k)
	first := int(h & (SHAPE_CACHE_CAP - 1))
	for i in 0..<SHAPE_CACHE_CAP {
		idx := (first + i) & (SHAPE_CACHE_CAP - 1)
		if c.cluster_occupied[idx] {
			if c.cluster_keys[idx] == k {
				c.cluster_values[idx] = cluster
				return
			}
			continue
		}
		c.cluster_occupied[idx] = true
		c.cluster_keys[idx] = k
		c.cluster_values[idx] = cluster
		c.cluster_live += 1
		return
	}
	c.cluster_keys[first] = k
	c.cluster_values[first] = cluster
	c.cluster_evictions += 1
}

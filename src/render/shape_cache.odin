package render

// Shape cache: maps a cluster's value identity (base + first marks +
// join form) to its resolved glyph. Fixed arrays, no allocation.
// Identity is by value copy, never by pool handle: two cells holding equal
// clusters share one entry regardless of pool indices.

import termgrid "../terminal"

// SHAPE_CACHE_CAP bounds the cache. Full means overwrite the probe start
// (evictions tracks foreign overwrites); correctness heals via re-resolve.
SHAPE_CACHE_CAP :: 1024

// Cluster_Key is the value identity of one cluster. Marks beyond the first
// two are folded into mark1 at construction so distinct clusters stay
// distinct in the hash.
Cluster_Key :: struct {
	base:       rune,
	mark0:      rune,
	mark1:      rune,
	mark_count: u8,
	join_form:  Join_Form,
}

// Shaped_Glyph is one resolved cluster. atlas_slot 0x1FF is UNRESOLVED.
Shaped_Glyph :: struct {
	font_index:       u8,
	shaped_codepoint: u32,
	atlas_slot:       u16,
	wide:             bool,
}

// Shape_Cache is an open-addressed linear-probe map with fixed storage.
Shape_Cache :: struct {
	keys:      [SHAPE_CACHE_CAP]Cluster_Key,
	values:    [SHAPE_CACHE_CAP]Shaped_Glyph,
	occupied:  [SHAPE_CACHE_CAP]bool,
	live:      int,
	evictions: u64,
}

// cluster_key_from_handle copies a handle's cluster identity by value.
// Literals copy directly; pool handles copy base + first two marks (extras
// folded into mark1); out-of-range handles resolve to U+FFFD.
cluster_key_from_handle :: proc(
	h: termgrid.Content_Handle,
	store: ^termgrid.Grapheme_Store,
	join_form: Join_Form,
) -> Cluster_Key {
	if !termgrid.content_is_grapheme(h) {
		return Cluster_Key{base = rune(h), join_form = join_form}
	}
	if store == nil {
		return Cluster_Key{base = 0xFFFD, join_form = join_form}
	}
	idx := int(h - termgrid.CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= termgrid.GRAPHEME_STORE_CAP {
		return Cluster_Key{base = 0xFFFD, join_form = join_form}
	}
	e := &store.entries[idx]
	k := Cluster_Key{base = e.base, mark_count = e.mark_count, join_form = join_form}
	if e.mark_count > 0 {
		k.mark0 = e.marks[0]
	}
	if e.mark_count > 1 {
		k.mark1 = e.marks[1]
	}
	if e.mark_count > 2 {
		for i in 2..<int(e.mark_count) {
			k.mark1 = rune(i32(k.mark1) ~ i32(e.marks[i]))
		}
	}
	return k
}

// cluster_key_hash is FNV-1a over the key's three runes (12 bytes) with the
// mark count and join form mixed in. Pure.
cluster_key_hash :: proc(k: Cluster_Key) -> u32 {
	h := u32(2166136261)
	mix_byte :: proc(h: u32, b: u8) -> u32 {
		return (h ~ u32(b)) * 16777619
	}
	shifts := [4]u32{0, 8, 16, 24}
	for shift in shifts {
		h = mix_byte(h, u8((u32(k.base) >> shift) & 0xFF))
	}
	for shift in shifts {
		h = mix_byte(h, u8((u32(k.mark0) >> shift) & 0xFF))
	}
	for shift in shifts {
		h = mix_byte(h, u8((u32(k.mark1) >> shift) & 0xFF))
	}
	h = mix_byte(h, k.mark_count)
	h = mix_byte(h, u8(k.join_form))
	return h
}

// shape_cache_lookup probes hash&(CAP-1) linearly. Pure read: never mutates.
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

// shape_cache_insert stores or updates an entry. Updating an existing key
// never counts as an eviction; overwriting a foreign key on a full table
// does (bounded: evictions tracks it, stale slots re-resolve lazily).
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

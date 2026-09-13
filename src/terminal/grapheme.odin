package termgrid

import "core:unicode/utf8"

// Bounded combining-mark grapheme pool. Zero allocation: fixed arrays only.
// A Content_Handle >= CONTENT_GRAPHEME_BASE is a pool index;
// <= 0x10FFFF is a literal codepoint; 0 is empty.

// GRAPHEME_INLINE_CAP caps marks per cluster.
GRAPHEME_INLINE_CAP :: 16
GRAPHEME_MAX_MARKS :: GRAPHEME_INLINE_CAP

// GRAPHEME_STORE_CAP caps live clusters in the pool.
GRAPHEME_STORE_CAP :: 256

// CONTENT_GRAPHEME_BASE partitions Content_Handle: >= base is a pool index.
CONTENT_GRAPHEME_BASE :: u32(0x110000)

// Grapheme_Cluster is a sequence of up to GRAPHEME_INLINE_CAP runes.
Grapheme_Cluster :: struct {
	runes:      [GRAPHEME_INLINE_CAP]rune,
	rune_count: u8,
	width:      u8,
}

// grapheme_cluster_make initializes a new cluster with 1 initial rune.
grapheme_cluster_make :: proc(initial_rune: rune, width: u8 = 1) -> Grapheme_Cluster {
	c: Grapheme_Cluster
	c.runes[0] = initial_rune
	c.rune_count = 1
	c.width = width
	return c
}

// grapheme_cluster_append adds a rune to a cluster (clamps safely at GRAPHEME_INLINE_CAP).
grapheme_cluster_append :: proc(cluster: ^Grapheme_Cluster, r: rune) -> bool {
	if cluster == nil || cluster.rune_count >= GRAPHEME_INLINE_CAP {
		return false
	}
	cluster.runes[cluster.rune_count] = r
	cluster.rune_count += 1
	return true
}

// Grapheme_Store is a bump allocator with a free stack for released indices.
// Invariant: an empty free stack means live entries occupy 0..<live_count
// contiguously, so a fresh index is always live_count (never collides).
// free_count never exceeds 255: when the last live entry is released the
// stack resets to empty instead of pushing the 256th index.
Grapheme_Store :: struct {
	entries:    [GRAPHEME_STORE_CAP]Grapheme_Cluster,
	free:       [GRAPHEME_STORE_CAP]u8,
	free_count: u8,
	live_count: int,
}

// grapheme_store_init resets a store to empty.
grapheme_store_init :: proc(s: ^Grapheme_Store) {
	s.entries = {}
	s.free = {}
	s.free_count = 0
	s.live_count = 0
}

// grapheme_store_append allocates a cluster and returns its handle.
// StoreFull returns Content_Handle(base): base-only, mark dropped.
grapheme_store_append :: proc(s: ^Grapheme_Store, base: rune, mark: rune) -> Content_Handle {
	idx: int = -1
	if s.free_count > 0 {
		s.free_count -= 1
		idx = int(s.free[s.free_count])
	} else if s.live_count < GRAPHEME_STORE_CAP {
		idx = s.live_count
	} else {
		return Content_Handle(base)
	}
	s.entries[idx] = {}
	s.entries[idx].runes[0] = base
	s.entries[idx].runes[1] = mark
	s.entries[idx].rune_count = 2
	s.entries[idx].width = 1
	s.live_count += 1
	return CONTENT_GRAPHEME_BASE + Content_Handle(idx)
}

// grapheme_store_add_rune appends a rune to a cluster.
// Literal handle: allocates a new cluster. Pool handle: appends in place
// when rune_count < GRAPHEME_INLINE_CAP, else drops the rune (handle unchanged).
grapheme_store_add_rune :: proc(s: ^Grapheme_Store, h: Content_Handle, r: rune) -> Content_Handle {
	if !content_is_grapheme(h) {
		return grapheme_store_append(s, rune(h), r)
	}
	idx := int(h - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		return grapheme_store_append(s, grapheme_resolve_base(h, s), r)
	}
	e := &s.entries[idx]
	grapheme_cluster_append(e, r)
	return h
}

// grapheme_store_add_mark forwards to grapheme_store_add_rune for backward compatibility.
grapheme_store_add_mark :: proc(s: ^Grapheme_Store, h: Content_Handle, mark: rune) -> Content_Handle {
	return grapheme_store_add_rune(s, h, mark)
}

// grapheme_store_release frees a pool handle back to the free stack.
// Literal handles are a no-op. Releasing the last live entry resets the
// stack to empty (keeps the bump invariant; avoids u8 overflow at 256).
grapheme_store_release :: proc(s: ^Grapheme_Store, h: Content_Handle) {
	if !content_is_grapheme(h) {
		return
	}
	idx := int(h - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		return
	}
	s.entries[idx] = {}
	s.live_count -= 1
	if s.live_count <= 0 {
		s.live_count = 0
		s.free_count = 0
		return
	}
	s.free[s.free_count] = u8(idx)
	s.free_count += 1
}

// content_is_grapheme reports whether h is a pool handle (not a literal).
content_is_grapheme :: proc(h: Content_Handle) -> bool {
	return h >= CONTENT_GRAPHEME_BASE
}

// grapheme_resolve_base returns the base rune of a handle for rendering.
// Out-of-range handles resolve to U+FFFD; literals resolve to themselves.
grapheme_resolve_base :: proc(h: Content_Handle, s: ^Grapheme_Store) -> rune {
	if !content_is_grapheme(h) {
		return rune(h)
	}
	idx := int(h - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		return 0xFFFD
	}
	e := &s.entries[idx]
	if e.rune_count == 0 {
		return 0xFFFD
	}
	return e.runes[0]
}

// grapheme_to_utf8 writes the full UTF-8 representation (runes 0..<rune_count)
// into out_buf and returns the resulting string slice.
grapheme_to_utf8 :: proc(h: Content_Handle, s: ^Grapheme_Store, out_buf: []u8) -> string {
	if !content_is_grapheme(h) {
		b, n := utf8.encode_rune(rune(h))
		if n <= 0 || n > len(out_buf) do return ""
		copy(out_buf[:n], b[:n])
		return string(out_buf[:n])
	}
	if s == nil {
		b, n := utf8.encode_rune(0xFFFD)
		if n <= 0 || n > len(out_buf) do return ""
		copy(out_buf[:n], b[:n])
		return string(out_buf[:n])
	}
	idx := int(h - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		b, n := utf8.encode_rune(0xFFFD)
		if n <= 0 || n > len(out_buf) do return ""
		copy(out_buf[:n], b[:n])
		return string(out_buf[:n])
	}
	e := &s.entries[idx]
	offset := 0
	count := min(int(e.rune_count), GRAPHEME_INLINE_CAP)
	for i in 0..<count {
		b, n := utf8.encode_rune(e.runes[i])
		if offset + n > len(out_buf) do break
		copy(out_buf[offset:offset+n], b[:n])
		offset += n
	}
	return string(out_buf[:offset])
}


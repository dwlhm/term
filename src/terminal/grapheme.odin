package termgrid

// Bounded combining-mark grapheme pool. Zero allocation: fixed arrays only.
// A Content_Handle >= CONTENT_GRAPHEME_BASE is a pool index;
// <= 0x10FFFF is a literal codepoint; 0 is empty.

// GRAPHEME_MAX_MARKS caps marks per cluster.
GRAPHEME_MAX_MARKS :: 4

// GRAPHEME_STORE_CAP caps live clusters in the pool.
GRAPHEME_STORE_CAP :: 256

// CONTENT_GRAPHEME_BASE partitions Content_Handle: >= base is a pool index.
CONTENT_GRAPHEME_BASE :: u32(0x110000)

// Grapheme_Cluster is one base rune plus up to 4 combining marks.
Grapheme_Cluster :: struct {
	base:       rune,
	marks:      [GRAPHEME_MAX_MARKS]rune,
	mark_count: u8,
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
	s.entries[idx] = Grapheme_Cluster{base = base, mark_count = 1}
	s.entries[idx].marks[0] = mark
	s.live_count += 1
	return CONTENT_GRAPHEME_BASE + Content_Handle(idx)
}

// grapheme_store_add_mark appends a mark to a cluster.
// Literal handle: allocates a new cluster. Pool handle: appends in place
// when mark_count < GRAPHEME_MAX_MARKS, else drops the mark (handle unchanged).
grapheme_store_add_mark :: proc(s: ^Grapheme_Store, h: Content_Handle, mark: rune) -> Content_Handle {
	if !content_is_grapheme(h) {
		return grapheme_store_append(s, rune(h), mark)
	}
	idx := int(h - CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= GRAPHEME_STORE_CAP {
		return grapheme_store_append(s, grapheme_resolve_base(h, s), mark)
	}
	e := &s.entries[idx]
	if int(e.mark_count) < GRAPHEME_MAX_MARKS {
		e.marks[e.mark_count] = mark
		e.mark_count += 1
	}
	return h
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
	return s.entries[idx].base
}

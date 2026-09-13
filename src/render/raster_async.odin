package render

// Phase 12 async raster queue: one worker thread rasterizes fallback glyphs
// off the render thread. The render thread enqueues by-value requests with
// try_lock (never blocks) and drains completions at frame top; the worker
// touches only queue state under q.mutex and never the atlas, the shape
// cache, or the GPU.
//
// Data flow:
//   Compile_V2 -> raster_request_async -> Raster_Queue -> raster_worker_main
//     -> Completion_Queue -> raster_drain_completions
//     -> atlas_apply_completion -> Shape_Insert + Gpu_Dirty_Set

import "base:runtime"
import "core:math"
import "core:sync"
import "core:thread"
import "vendor:stb/truetype"
import termgrid "../terminal"

// RASTER_QUEUE_CAP bounds pending requests. Overflow drops the incoming
// request (raster_overflow += 1, key NOT marked in-flight) so the next
// frame retries; the render thread never blocks.
RASTER_QUEUE_CAP :: 256

// RASTER_COMPLETION_CAP bounds finished bitmaps awaiting drain.
RASTER_COMPLETION_CAP :: 256
RASTER_TARGETS_PER_GROUP :: 32

Raster_Request_Result :: enum { Retry, Enqueued, Coalesced }
Raster_Group_State :: enum { Queued, Running, Completion_Ready, Retry }

Raster_Target_Group :: struct {
	key:          Cluster_Key,
	font_index:   int,
	shaped:       u32,
	marks:        [4]rune,
	mark_n:       int,
	wide:         bool,
	targets:      [RASTER_TARGETS_PER_GROUP]termgrid.Damage_Target,
	target_count: int,
	state:        Raster_Group_State,
}

// Raster_Request is one off-thread raster job. By value only: key, shaped
// codepoint, and covering marks are copied at enqueue, so grapheme-pool
// recycling or atlas FIFO eviction before completion cannot corrupt it.
Raster_Request :: struct {
	group_index: int,
}

// Raster_Completion is one rasterized bitmap. pixels is a heap
// (runtime.heap_allocator) ATLAS_GLYPH_SIZE x ATLAS_GLYPH_SIZE rect, owned by
// the queue: the worker allocates, the render thread frees after apply.
// nil pixels when ok == false (zero bitmap or uncovered glyph).
Raster_Completion :: struct {
	key:        Cluster_Key,
	font_index: int,
	shaped:     u32,
	width:      int,
	height:     int,
	pixels:     []u8,
	advance:    f32,
	ok:         bool,
	group_index: int,
}

// Raster_Counters tracks async queue activity. Separate from
// Fallback_Counters (no merge). All fields are written under q.mutex
// except contended, which is render-thread-single-writer (Mutex+Cond only,
// no atomics) and bumped on the try_lock failure path where the mutex is
// by definition unavailable.
Raster_Counters :: struct {
	enqueued:  u64, // requests accepted into the ring
	coalesced: u64, // duplicate in-flight misses served by one raster
	overflow:  u64, // drops on a full request ring (retry next frame)
	contended: u64, // try_lock failures (bounded-time skip, retry next frame)
	completed: u64, // bitmaps pushed by the worker
	apply_fail: u64, // completions dropped on a full completion ring
}

// Raster_Queue is the request/completion ring pair plus the in-flight set.
// Atlas slots, pixels, tags, cursor, and gpu_dirty stay render-thread-only;
// the shape cache stays render-only; chain fonts are concurrent read-read.
Raster_Queue :: struct {
	mutex:          sync.Mutex,
	cond:           sync.Cond,
	reqs:           [RASTER_QUEUE_CAP]Raster_Request,
	req_head:       int,
	req_tail:       int,
	req_count:      int,
	comps:          [RASTER_COMPLETION_CAP]Raster_Completion,
	comp_head:      int,
	comp_tail:      int,
	comp_count:     int,
	groups:         [RASTER_QUEUE_CAP]Raster_Target_Group,
	group_next:     [RASTER_QUEUE_CAP]int,
	lookup_next:    [RASTER_QUEUE_CAP]int,
	group_lookup:   [RASTER_QUEUE_CAP]int,
	group_free:     [RASTER_QUEUE_CAP]int,
	group_free_n:   int,
	shutdown:       bool,
	worker:         ^thread.Thread,
	counters:       ^Raster_Counters,
}

// Raster_Worker_Ctx is the heap context handed to the worker thread: the
// queue plus the read-only fallback chain.
Raster_Worker_Ctx :: struct {
	q:     ^Raster_Queue,
	chain: ^Fallback_Chain,
}

// raster_queue_init zeroes the rings and stores the counters pointer.
// The zero Mutex/Cond values are ready to use; NO thread is started here.
raster_queue_init :: proc(q: ^Raster_Queue, counters: ^Raster_Counters) {
	if q == nil {
		return
	}
	q^ = Raster_Queue{}
	q.counters = counters
	q.group_free_n = RASTER_QUEUE_CAP
	for i in 0..<RASTER_QUEUE_CAP {
		q.group_free[i] = RASTER_QUEUE_CAP - 1 - i
		q.group_next[i] = -1
		q.lookup_next[i] = -1
		q.group_lookup[i] = -1
	}
}

// raster_queue_destroy frees orphan completion pixels. The worker must be
// joined first (raster_worker_shutdown); a live worker is shut down here
// defensively. Completion pixels use the shared heap allocator on both
// threads so worker-allocated bitmaps free correctly under any caller.
raster_queue_destroy :: proc(q: ^Raster_Queue, allocator: runtime.Allocator = context.allocator) {
	if q == nil {
		return
	}
	_ = allocator
	if q.worker != nil {
		raster_worker_shutdown(q)
	}
	heap := runtime.heap_allocator()
	for i in 0..<q.comp_count {
		idx := (q.comp_head + i) % RASTER_COMPLETION_CAP
		if q.comps[idx].pixels != nil {
			delete(q.comps[idx].pixels, heap)
			q.comps[idx].pixels = nil
		}
	}
	q.comp_head = 0
	q.comp_tail = 0
	q.comp_count = 0
	q.req_head = 0
	q.req_tail = 0
	q.req_count = 0
	q.group_free_n = RASTER_QUEUE_CAP
	for i in 0..<RASTER_QUEUE_CAP {
		q.group_free[i] = RASTER_QUEUE_CAP - 1 - i
		q.group_next[i] = -1
		q.lookup_next[i] = -1
		q.group_lookup[i] = -1
	}
	q.shutdown = false
}

// raster_worker_start spawns the single worker thread. The chain is
// read-only context (concurrent read-read with the render thread); a nil
// chain degrades to ok=false completions (drain takes the tofu path).
raster_worker_start :: proc(q: ^Raster_Queue, chain: ^Fallback_Chain) {
	if q == nil || q.worker != nil {
		return
	}
	heap := runtime.heap_allocator()
	ctx := new(Raster_Worker_Ctx, heap)
	ctx.q = q
	ctx.chain = chain
	q.worker = thread.create(raster_worker_main)
	q.worker.data = ctx
	thread.start(q.worker)
}

// raster_worker_shutdown flags shutdown, wakes the worker, joins it, and
// destroys the thread handle. The worker drains pending requests into
// completions before exiting, so no job is lost; the caller drains
// completions after join.
raster_worker_shutdown :: proc(q: ^Raster_Queue) {
	if q == nil || q.worker == nil {
		return
	}
	sync.mutex_lock(&q.mutex)
	q.shutdown = true
	sync.cond_broadcast(&q.cond)
	sync.mutex_unlock(&q.mutex)
	thread.join(q.worker)
	ctx := (^Raster_Worker_Ctx)(q.worker.data)
	thread.destroy(q.worker)
	q.worker = nil
	if ctx != nil {
		free(ctx, runtime.heap_allocator())
	}
}

_raster_key_hash :: proc(key: Cluster_Key) -> int {
	h := u64(u32(key.runes[0])) * 0x9E3779B1
	h = h ~ (u64(u8(key.join_form)) * 0x85EBCA6B)
	return int(h % u64(RASTER_QUEUE_CAP))
}

_raster_lookup_slot_locked :: proc(q: ^Raster_Queue, key: Cluster_Key) -> (slot: int, found: bool) {
	slot = _raster_key_hash(key)
	gi := q.group_lookup[slot]
	for gi >= 0 {
		if q.groups[gi].key == key { return slot, true }
		gi = q.lookup_next[gi]
	}
	return slot, false
}

_raster_group_for_key_locked :: proc(q: ^Raster_Queue, key: Cluster_Key) -> (group_index: int, slot: int) {
	lookup_slot, found := _raster_lookup_slot_locked(q, key)
	if !found || lookup_slot < 0 { return -1, lookup_slot }
	return q.group_lookup[lookup_slot], lookup_slot
}

raster_request_async :: proc(
	q: ^Raster_Queue,
	key: Cluster_Key,
	font_index: int,
	shaped: u32,
	marks: []rune,
	wide: bool,
	target: termgrid.Damage_Target,
) -> Raster_Request_Result {
	if q == nil { return .Retry }
	if !sync.mutex_try_lock(&q.mutex) {
		if q.counters != nil { q.counters.contended += 1 }
		return .Retry
	}
	defer sync.mutex_unlock(&q.mutex)
	if q.shutdown { return .Retry }
	group_index, lookup_slot := _raster_group_for_key_locked(q, key)
	if group_index >= 0 {
		last := group_index
		for last >= 0 {
			g := &q.groups[last]
			if g.state != .Retry && g.target_count < RASTER_TARGETS_PER_GROUP {
				g.targets[g.target_count] = target
				g.target_count += 1
				if q.counters != nil { q.counters.coalesced += 1 }
				return .Coalesced
			}
			if q.group_next[last] < 0 { break }
			last = q.group_next[last]
		}
	}
	if group_index < 0 && lookup_slot < 0 {
		if q.counters != nil { q.counters.overflow += 1 }
		return .Retry
	}
	if q.req_count >= RASTER_QUEUE_CAP || q.group_free_n <= 0 {
		if q.counters != nil { q.counters.overflow += 1 }
		return .Retry
	}
	gi := q.group_free[q.group_free_n - 1]
	q.group_free_n -= 1
	g := &q.groups[gi]
	g.key = key
	g.font_index = font_index
	g.shaped = shaped
	g.mark_n = 0
	g.wide = wide
	g.target_count = 0
	g.state = .Queued
	q.group_next[gi] = -1
	if group_index >= 0 {
		last := group_index
		for q.group_next[last] >= 0 { last = q.group_next[last] }
		q.group_next[last] = gi
	} else {
		if lookup_slot < 0 { return .Retry }
		q.lookup_next[gi] = q.group_lookup[lookup_slot]
		q.group_lookup[lookup_slot] = gi
	}
	n := len(marks)
	if n > len(g.marks) { n = len(g.marks) }
	for i in 0..<n { g.marks[i] = marks[i] }
	g.mark_n = n
	g.targets[0] = target
	g.target_count = 1
	q.reqs[q.req_tail] = Raster_Request{group_index = gi}
	q.req_tail = (q.req_tail + 1) % RASTER_QUEUE_CAP
	q.req_count += 1
	if q.counters != nil { q.counters.enqueued += 1 }
	sync.cond_signal(&q.cond)
	return .Enqueued
}

_raster_group_release :: proc(q: ^Raster_Queue, group_index: int) {
	if q == nil || group_index < 0 || group_index >= RASTER_QUEUE_CAP { return }
	key := q.groups[group_index].key

	lookup_slot := _raster_key_hash(key)
	prev_lookup := -1
	lookup := q.group_lookup[lookup_slot]
	for lookup >= 0 && lookup != group_index {
		prev_lookup = lookup
		lookup = q.lookup_next[lookup]
	}
	if lookup == group_index {
		if prev_lookup < 0 { q.group_lookup[lookup_slot] = q.lookup_next[group_index] }
		else { q.lookup_next[prev_lookup] = q.lookup_next[group_index] }
	}
	q.lookup_next[group_index] = -1
	q.group_next[group_index] = -1
	q.groups[group_index] = Raster_Target_Group{}
	if q.group_free_n < RASTER_QUEUE_CAP {
		q.group_free[q.group_free_n] = group_index
		q.group_free_n += 1
	}
}

_raster_mark_group_retry :: proc(q: ^Raster_Queue, group_index: int) {
	if q == nil || group_index < 0 || group_index >= RASTER_QUEUE_CAP { return }
	q.groups[group_index].state = .Retry
}

_raster_retry_groups_locked :: proc(q: ^Raster_Queue) {
	if q == nil { return }
	for i in 0..<RASTER_QUEUE_CAP {
		g := &q.groups[i]
		if g.state != .Retry || g.target_count <= 0 { continue }
		if q.req_count >= RASTER_QUEUE_CAP { return }
		q.reqs[q.req_tail] = Raster_Request{group_index = i}
		q.req_tail = (q.req_tail + 1) % RASTER_QUEUE_CAP
		q.req_count += 1
		g.state = .Queued
	}
}

// raster_worker_main pops requests under Mutex, waits on Cond when idle,
// and rasterizes WITHOUT the lock via font_rasterize_glyph. Each request
// becomes exactly one completion push (ok=false for zero bitmaps or
// uncovered glyphs). Exits when shutdown && req_count == 0, so a pending
// shutdown still converts every queued request before the join returns.
raster_worker_main :: proc(t: ^thread.Thread) {
	if t == nil || t.data == nil {
		return
	}
	ctx := (^Raster_Worker_Ctx)(t.data)
	q := ctx.q
	chain := ctx.chain
	if q == nil {
		return
	}
	heap := runtime.heap_allocator()
	for {
		sync.mutex_lock(&q.mutex)
		for q.req_count == 0 && !q.shutdown {
			sync.cond_wait(&q.cond, &q.mutex)
		}
		if q.req_count == 0 {
			sync.mutex_unlock(&q.mutex)
			return
		}
		req := q.reqs[q.req_head]
		group := q.groups[req.group_index]
		q.groups[req.group_index].state = .Running
		q.req_head = (q.req_head + 1) % RASTER_QUEUE_CAP
		q.req_count -= 1
		sync.mutex_unlock(&q.mutex)

		comp := _raster_rasterize(chain, &group, heap)
		comp.group_index = req.group_index

		sync.mutex_lock(&q.mutex)
		if q.comp_count >= RASTER_COMPLETION_CAP {
			if q.counters != nil { q.counters.apply_fail += 1 }
			_raster_mark_group_retry(q, req.group_index)
			sync.mutex_unlock(&q.mutex)
			if comp.pixels != nil { delete(comp.pixels, heap) }
			continue
		}
		q.groups[req.group_index].state = .Completion_Ready
		q.comps[q.comp_tail] = comp
		q.comp_tail = (q.comp_tail + 1) % RASTER_COMPLETION_CAP
		q.comp_count += 1
		if q.counters != nil {
			q.counters.completed += 1
		}
		sync.mutex_unlock(&q.mutex)
	}
}

// _raster_rasterize builds the final slot rect off-thread: base assign +
// marks max-blend, both centered exactly like _atlas_blit_bitmap, so the
// result is pixel-identical to the sync claim path. No atlas, cache, or
// GPU access. ok=false carries no pixels (drain takes the tofu path).
_raster_rasterize :: proc(
	chain: ^Fallback_Chain,
	group: ^Raster_Target_Group,
	heap: runtime.Allocator,
) -> Raster_Completion {
	comp := Raster_Completion{key = group.key, font_index = group.font_index, shaped = group.shaped}
	if chain == nil || group == nil {
		return comp
	}
	if group.font_index < 0 || group.font_index >= chain.count {
		return comp
	}
	f := &chain.fonts[group.font_index]
	if f.font_data == nil {
		return comp
	}
	if truetype.FindGlyphIndex(&f.info, rune(group.shaped)) == 0 {
		return comp
	}

	rect: [ATLAS_GLYPH_SIZE * ATLAS_GLYPH_SIZE]u8
	primary := &chain.fonts[0]
	wide := termgrid.wcwidth(rune(group.shaped)) == 2
	primary_cw := int(primary.metrics.cell_width)
	primary_ch := int(primary.metrics.cell_height)
	max_w := primary_cw * 2 if wide else primary_cw
	max_h := primary_ch
	base := font_rasterize_glyph_fitted(f, group.shaped, max_w, max_h, heap)
	if base.pixels != nil {
		_raster_blit_rect(rect[:], ATLAS_GLYPH_SIZE, &base, false, int(math.round(f.metrics.ascent)))
		delete(base.pixels, heap)
	}
	for i in 0..<group.mark_n {
		m := group.marks[i]
		if m == 0 {
			continue
		}
		mf, covered := _fallback_font_for_mark(chain, m)
		if !covered {
			continue
		}
		mb := font_rasterize_glyph(mf, u32(m), heap)
		if mb.pixels != nil {
			_raster_blit_rect(rect[:], ATLAS_GLYPH_SIZE, &mb, true, int(math.round(mf.metrics.ascent)))
			delete(mb.pixels, heap)
		}
	}

	empty := true
	for b in rect {
		if b != 0 {
			empty = false
			break
		}
	}
	if empty && group.shaped != 0x20 {
		return comp
	}
	pixels := make([]u8, len(rect), heap)
	copy(pixels, rect[:])
	comp.pixels = pixels
	comp.width = ATLAS_GLYPH_SIZE
	comp.height = ATLAS_GLYPH_SIZE
	comp.advance = f32(primary_cw * 2 if wide else primary_cw)
	comp.ok = true
	return comp
}

// _raster_blit_rect copies a tight glyph bitmap into a slot-size
// rect using baseline anchoring. blend_max overstrikes marks.
_raster_blit_rect :: proc(dst: []u8, stride: int, bmp: ^Glyph_Bitmap, blend_max: bool, ascent_px: int) {
	if bmp.width <= 0 || bmp.height <= 0 || bmp.pixels == nil {
		return
	}
	gs := ATLAS_GLYPH_SIZE
	ox := int(bmp.bearing_x)
	oy := ascent_px + int(bmp.bearing_y)
	for gy in 0..<bmp.height {
		for gx in 0..<bmp.width {
			dx := ox + gx
			dy := oy + gy
			if dx < 0 || dx >= stride || dy < 0 || dy >= gs {
				continue
			}
			di := dy * stride + dx
			si := gy * bmp.width + gx
			if di < len(dst) && si < len(bmp.pixels) {
				if blend_max {
					if bmp.pixels[si] > dst[di] {
						dst[di] = bmp.pixels[si]
					}
				} else {
					dst[di] = bmp.pixels[si]
				}
			}
		}
	}
}

raster_drain_completions :: proc(
	q: ^Raster_Queue,
	atlas: ^Atlas,
	cache: ^Shape_Cache,
	terminal: ^termgrid.Terminal,
	chain: ^Fallback_Chain = nil,
	counters: ^Fallback_Counters = nil,
) -> (applied: int) {
	if q == nil { return 0 }
	if !sync.mutex_try_lock(&q.mutex) { return 0 }
	batch: [RASTER_COMPLETION_CAP]Raster_Completion
	n := q.comp_count
	if n > RASTER_COMPLETION_CAP { n = RASTER_COMPLETION_CAP }
	for i in 0..<n {
		idx := (q.comp_head + i) % RASTER_COMPLETION_CAP
		batch[i] = q.comps[idx]
	}
	q.comp_head = 0
	q.comp_tail = 0
	q.comp_count = 0
	_raster_retry_groups_locked(q)
	sync.mutex_unlock(&q.mutex)

	heap := runtime.heap_allocator()
	for i in 0..<n {
		comp := &batch[i]
		atlas_apply_completion(atlas, cache, comp, chain, counters)
		if comp.group_index >= 0 && comp.group_index < RASTER_QUEUE_CAP {
			g := &q.groups[comp.group_index]
			for j in 0..<g.target_count {
				if terminal != nil { termgrid.terminal_apply_damage_target(terminal, g.targets[j]) }
			}
			sync.mutex_lock(&q.mutex)
			_raster_group_release(q, comp.group_index)
			sync.mutex_unlock(&q.mutex)
		}
		if comp.pixels != nil { delete(comp.pixels, heap); comp.pixels = nil }
		applied += 1
	}
	return applied
}

// raster_pending_count returns queued requests and awaited completions.
// Lock-read-unlock snapshot for tests and polling.
raster_pending_count :: proc(q: ^Raster_Queue) -> (reqs: int, comps: int) {
	if q == nil {
		return 0, 0
	}
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	return q.req_count, q.comp_count
}

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
import "core:sync"
import "core:thread"
import "vendor:stb/truetype"

// RASTER_QUEUE_CAP bounds pending requests. Overflow drops the incoming
// request (raster_overflow += 1, key NOT marked in-flight) so the next
// frame retries; the render thread never blocks.
RASTER_QUEUE_CAP :: 256

// RASTER_COMPLETION_CAP bounds finished bitmaps awaiting drain.
RASTER_COMPLETION_CAP :: 256

// Raster_Request is one off-thread raster job. By value only: key, shaped
// codepoint, and covering marks are copied at enqueue, so grapheme-pool
// recycling or atlas FIFO eviction before completion cannot corrupt it.
Raster_Request :: struct {
	key:        Cluster_Key,
	font_index: int,
	shaped:     u32,
	marks:      [4]rune,
	mark_n:     int,
	wide:       bool,
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
	inflight:       [RASTER_QUEUE_CAP]Cluster_Key,
	inflight_count: int,
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
	q.inflight_count = 0
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

// raster_request_async enqueues one raster job from the render thread.
// try_lock: never blocks. Returns false (no enqueue, blank placeholder,
// retry next frame) on contention, duplicate in-flight, full ring, or
// shutdown. Marks are truncated to 4 (GRAPHEME_MAX_MARKS).
raster_request_async :: proc(
	q: ^Raster_Queue,
	key: Cluster_Key,
	font_index: int,
	shaped: u32,
	marks: []rune,
	wide: bool,
) -> (enqueued: bool) {
	if q == nil {
		return false
	}
	if !sync.mutex_try_lock(&q.mutex) {
		if q.counters != nil {
			q.counters.contended += 1
		}
		return false
	}
	defer sync.mutex_unlock(&q.mutex)
	if q.shutdown {
		return false
	}
	if raster_inflight_contains(q, key) {
		if q.counters != nil {
			q.counters.coalesced += 1
		}
		return false
	}
	if q.req_count >= RASTER_QUEUE_CAP {
		if q.counters != nil {
			q.counters.overflow += 1
		}
		return false
	}
	if q.inflight_count >= RASTER_QUEUE_CAP {
		// In-flight set full: entries clear only at drain, so heavy
		// pre-drain re-enqueue can fill the set while the request ring
		// still has room (popped requests stay in-flight until drain).
		// Same drop-and-retry as ring overflow; the key is NOT marked.
		if q.counters != nil {
			q.counters.overflow += 1
		}
		return false
	}
	req := Raster_Request{key = key, font_index = font_index, shaped = shaped, wide = wide}
	n := len(marks)
	if n > len(req.marks) {
		n = len(req.marks)
	}
	for i in 0..<n {
		req.marks[i] = marks[i]
	}
	req.mark_n = n
	q.reqs[q.req_tail] = req
	q.req_tail = (q.req_tail + 1) % RASTER_QUEUE_CAP
	q.req_count += 1
	q.inflight[q.inflight_count] = key
	q.inflight_count += 1
	if q.counters != nil {
		q.counters.enqueued += 1
	}
	sync.cond_signal(&q.cond)
	return true
}

// raster_inflight_contains reports whether key is already queued or
// rasterizing. The caller must hold q.mutex. Linear scan, bounded by 256.
raster_inflight_contains :: proc(q: ^Raster_Queue, key: Cluster_Key) -> bool {
	if q == nil {
		return false
	}
	for i in 0..<q.inflight_count {
		if q.inflight[i] == key {
			return true
		}
	}
	return false
}

// _raster_inflight_remove drops one key from the in-flight set
// (swap-remove, orderless). The caller must hold q.mutex.
_raster_inflight_remove :: proc(q: ^Raster_Queue, key: Cluster_Key) {
	for i in 0..<q.inflight_count {
		if q.inflight[i] == key {
			q.inflight_count -= 1
			q.inflight[i] = q.inflight[q.inflight_count]
			return
		}
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
		q.req_head = (q.req_head + 1) % RASTER_QUEUE_CAP
		q.req_count -= 1
		sync.mutex_unlock(&q.mutex)

		comp := _raster_rasterize(chain, &req, heap)

		sync.mutex_lock(&q.mutex)
		if q.comp_count >= RASTER_COMPLETION_CAP {
			// Completion ring full (drain lags): drop the bitmap but clear
			// the in-flight key so a later frame retries. Never blocks.
			if q.counters != nil {
				q.counters.apply_fail += 1
			}
			_raster_inflight_remove(q, req.key)
			sync.mutex_unlock(&q.mutex)
			if comp.pixels != nil {
				delete(comp.pixels, heap)
			}
			continue
		}
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
	req: ^Raster_Request,
	heap: runtime.Allocator,
) -> Raster_Completion {
	comp := Raster_Completion{key = req.key, font_index = req.font_index, shaped = req.shaped}
	if chain == nil || req == nil {
		return comp
	}
	if req.font_index < 0 || req.font_index >= chain.count {
		return comp
	}
	f := &chain.fonts[req.font_index]
	if f.font_data == nil {
		return comp
	}
	if truetype.FindGlyphIndex(&f.info, rune(req.shaped)) == 0 {
		return comp
	}

	rect: [ATLAS_GLYPH_SIZE * ATLAS_GLYPH_SIZE]u8
	base := font_rasterize_glyph(f, req.shaped, heap)
	if base.pixels != nil {
		_raster_blit_rect(rect[:], ATLAS_GLYPH_SIZE, &base, false)
		delete(base.pixels, heap)
	}
	for i in 0..<req.mark_n {
		m := req.marks[i]
		if m == 0 {
			continue
		}
		mf, covered := _fallback_font_for_mark(chain, m)
		if !covered {
			continue
		}
		mb := font_rasterize_glyph(mf, u32(m), heap)
		if mb.pixels != nil {
			_raster_blit_rect(rect[:], ATLAS_GLYPH_SIZE, &mb, true)
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
	if empty && req.shaped != 0x20 {
		return comp
	}
	pixels := make([]u8, len(rect), heap)
	copy(pixels, rect[:])
	comp.pixels = pixels
	comp.width = ATLAS_GLYPH_SIZE
	comp.height = ATLAS_GLYPH_SIZE
	comp.advance = f.metrics.cell_width
	comp.ok = true
	return comp
}

// _raster_blit_rect copies a tight glyph bitmap centered into a slot-size
// rect. Same centering math as _atlas_blit_bitmap (origin 0,0), so worker
// output matches sync-claimed pixels exactly. blend_max overstrikes marks.
_raster_blit_rect :: proc(dst: []u8, stride: int, bmp: ^Glyph_Bitmap, blend_max: bool) {
	if bmp.width <= 0 || bmp.height <= 0 || bmp.pixels == nil {
		return
	}
	gs := ATLAS_GLYPH_SIZE
	ox := (gs - bmp.width) / 2
	oy := (gs - bmp.height) / 2
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

// raster_drain_completions pops all completions, applies each to the atlas
// (FIFO claim at drain, clear + copy + tag + shape_cache_insert +
// gpu_dirty), frees worker pixels, and clears in-flight keys. Render
// thread only. try_lock: a worker mid-push defers the drain one frame;
// after join the lock is always free. Returns drained count.
raster_drain_completions :: proc(
	q: ^Raster_Queue,
	atlas: ^Atlas,
	cache: ^Shape_Cache,
	chain: ^Fallback_Chain = nil,
	counters: ^Fallback_Counters = nil,
) -> (applied: int) {
	if q == nil {
		return 0
	}
	if !sync.mutex_try_lock(&q.mutex) {
		return 0
	}
	batch: [RASTER_COMPLETION_CAP]Raster_Completion
	n := q.comp_count
	if n > RASTER_COMPLETION_CAP {
		n = RASTER_COMPLETION_CAP
	}
	for i in 0..<n {
		idx := (q.comp_head + i) % RASTER_COMPLETION_CAP
		batch[i] = q.comps[idx]
		_raster_inflight_remove(q, batch[i].key)
	}
	q.comp_head = 0
	q.comp_tail = 0
	q.comp_count = 0
	sync.mutex_unlock(&q.mutex)

	heap := runtime.heap_allocator()
	for i in 0..<n {
		atlas_apply_completion(atlas, cache, &batch[i], chain, counters)
		if batch[i].pixels != nil {
			delete(batch[i].pixels, heap)
			batch[i].pixels = nil
		}
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

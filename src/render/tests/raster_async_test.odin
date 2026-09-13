package render_tests

// Phase 12 async raster tests: miss immediacy, pop-in correctness,
// duplicate coalescing, queue-full retry, shutdown drain, pool-recycle
// immunity, eviction impossibility, the ASCII regression gate, and worker
// race stress.
//
// Queue/atlas/cache fixtures are per-test locals; fonts reuse the Phase 11
// package fixtures (Menlo primary, GeezaPro Arabic, Hiragino CJK).

import "core:testing"
import "core:time"
import "core:fmt"
import thread "core:thread"
import render "../"
import instance "../instance"
import termgrid "../../terminal"

// RA_STORM_ROWS x RA_STORM_COLS is the cold-miss storm grid (2000 cells).
RA_STORM_ROWS :: 25
RA_STORM_COLS :: 80

// _ra_q builds a workerless queue with fresh counters.
_ra_q :: proc(q: ^render.Raster_Queue, counters: ^render.Raster_Counters) {
	counters^ = render.Raster_Counters{}
	render.raster_queue_init(q, counters)
}

// _ra_word writes one literal CJK cell.
_ra_word :: proc(term: ^termgrid.Terminal, row, col: int, cp: rune) {
	termgrid.grid_set_cell(&term.grid, row, col, termgrid.Semantic_Cell{
		content = termgrid.Content_Handle(cp), style = 0, width = 1,
	})
}

// _ra_storm_term fills a 25x80 grid with 2000 distinct CJK literals.
_ra_storm_term :: proc(term: ^termgrid.Terminal) {
	termgrid.terminal_init(term, RA_STORM_ROWS, RA_STORM_COLS)
	i := 0
	for r in 0..<RA_STORM_ROWS {
		for c in 0..<RA_STORM_COLS {
			_ra_word(term, r, c, rune(0x4E00 + i))
			i += 1
		}
	}
}

// _ra_wait_reqs_zero polls until the worker popped every request.
_ra_wait_reqs_zero :: proc(t: ^testing.T, q: ^render.Raster_Queue, timeout := 15 * time.Second) {
	start := time.tick_now()
	for {
		reqs, _ := render.raster_pending_count(q)
		if reqs == 0 {
			return
		}
		testing.expect(t, time.tick_since(start) < timeout, "worker must drain requests before timeout")
		if time.tick_since(start) >= timeout {
			return
		}
		thread.yield()
	}
}

// _ra_drain_all drains until no requests or completions remain (worker
// mid-push defers one drain a frame, so retry to a deadline).
_ra_drain_all :: proc(
	t: ^testing.T,
	q: ^render.Raster_Queue,
	atlas: ^render.Atlas,
	cache: ^render.Shape_Cache,
	chain: ^render.Fallback_Chain,
	counters: ^render.Fallback_Counters,
	want: int,
	timeout := 15 * time.Second,
) -> int {
	total := 0
	start := time.tick_now()
	for total < want {
		total += render.raster_drain_completions(q, atlas, cache, nil, chain, counters)
		reqs, comps := render.raster_pending_count(q)
		if reqs == 0 && comps == 0 {
			break
		}
		if time.tick_since(start) >= timeout {
			break
		}
		thread.yield()
	}
	testing.expect_value(t, total, want)
	return total
}

// _ra_key_font pairs a covered codepoint with its resolving chain slot.
_ra_key_font :: struct {
	cp: rune,
	fi: int,
}

@(test)
test_raster_miss_returns_immediately :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	render.atlas_prewarm_chain(&atlas, &chain)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)

	term: termgrid.Terminal
	_ra_storm_term(&term)
	defer termgrid.terminal_destroy(&term)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, RA_STORM_ROWS, RA_STORM_COLS)
	defer render.render_compiler_destroy_v2(&frame)

	// Cold: 2000 distinct misses, no worker. Every miss must return
	// immediately (enqueue or overflow-drop), never sync-rasterize.
	start := time.tick_now()
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	dt := time.tick_since(start)
	if dt >= 10 * time.Millisecond {
		testing.expect(t, false, fmt.tprintf("2000 cold misses must compile in <10ms, took %v", dt))
	}

	// Zero sync detours: every cell packs the blank UNRESOLVED
	// placeholder (sync tofu would pack a real slot), and every miss is
	// accounted as enqueued or overflow.
	for i in 0..<len(frame.cells) {
		_, _, _, _, slot := render.render_cell_unpack_v2(frame.cells[i])
		if slot != render.RENDER_CELL_V2_SLOT_UNRESOLVED {
			testing.expect(t, false, "cold miss must pack UNRESOLVED, never sync-rasterize")
			break
		}
	}
	testing.expect_value(t, rcounters.enqueued + rcounters.overflow, u64(RA_STORM_ROWS * RA_STORM_COLS))
	testing.expect_value(t, fcounters.tofu_missing, u64(0))
}

@(test)
test_raster_pop_in :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &chain)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	_ra_word(&term, 0, 0, 0x4E2D)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)

	// Frame N: miss packs blank-then-pop-in (content 0, UNRESOLVED).
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	content, _, _, _, slot := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect_value(t, content, u32(0))
	testing.expect_value(t, slot, render.RENDER_CELL_V2_SLOT_UNRESOLVED)
	testing.expect_value(t, rcounters.enqueued, u64(1))

	// Worker rasterizes; shutdown joins; drain claims the slot and inserts.
	render.raster_worker_shutdown(&q)
	applied := render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, applied, 1)
	testing.expect_value(t, rcounters.completed, u64(1))

	// Frame N+1: the same cell pops in with a real, valid slot.
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	_, _, _, _, slot1 := render.render_cell_unpack_v2(frame.cells[0])
	testing.expect(t, slot1 != render.RENDER_CELL_V2_SLOT_UNRESOLVED, "pop-in frame must pack a real slot")
	testing.expect(t, atlas.slots[slot1].valid, "pop-in slot must be valid")
	key := render.cluster_key_from_handle(termgrid.grid_get_cell(&term.grid, 0, 0).content, &term.grapheme_store, .Isolated)
	g, hit := render.shape_cache_lookup(&cache, key)
	testing.expect(t, hit, "drained glyph must be cached")
	testing.expect_value(t, g.shaped_codepoint, u32(0x4E2D))
	testing.expect_value(t, g.atlas_slot, slot1)

	lut := _fb_lut(&term)
	bg, glyph: instance.Instance_Data
	emit_bg, emit_glyph, _ := render.render_cell_expand_instance(frame.cells[0], &lut, &atlas, 0, 0, 8, 16, &bg, &glyph)
	testing.expect(t, emit_bg && emit_glyph, "pop-in cell must emit bg+glyph")
}

@(test)
test_raster_duplicate_coalesced :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	_ra_word(&term, 0, 0, 0x4E2D)
	_ra_word(&term, 0, 1, 0x4E2D)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)

	// Two identical cells share one request and retain both targets.
	for _ in 0..<1 {
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	_, _, _, _, slot := render.render_cell_unpack_v2(frame.cells[0])
		testing.expect(t, slot == render.RENDER_CELL_V2_SLOT_UNRESOLVED, "in-flight cell stays blank")
	}
	testing.expect_value(t, rcounters.enqueued, u64(1))
	testing.expect(t, rcounters.coalesced >= 1, "same key cells must coalesce")
	key := render.cluster_key_make(0x4E2D, .Isolated)
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, termgrid.terminal_damage_target(&term, 0, 1)) == .Coalesced, "explicit second target must coalesce")
	reqs, comps := render.raster_pending_count(&q)
	testing.expect_value(t, reqs, 1)
	testing.expect_value(t, comps, 0)
	render.raster_worker_start(&q, &chain)
	render.raster_worker_shutdown(&q)
	render.raster_drain_completions(&q, &atlas, &cache, &term, &chain, &fcounters)

	testing.expect(t, term.damage.dirty_rows[0].span_count >= 2, "all coalesced targets must be damaged")
}

@(test)
test_raster_queue_full_retries :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)

	// Fill the ring with distinct keys; the 257th drops, key NOT in-flight.
	for i in 0..<render.RASTER_QUEUE_CAP {
		k := render.cluster_key_make(rune(0x4E00 + i), .Isolated)
		testing.expect(t, render.raster_request_async(&q, k, 2, u32(0x4E00 + i), nil, true, termgrid.Damage_Target{}) == .Enqueued, "ring must accept 256")
	}
	full_key := render.cluster_key_make(0x5600, .Isolated)
	testing.expect(t, render.raster_request_async(&q, full_key, 2, 0x5600, nil, true, termgrid.Damage_Target{}) == .Retry, "257th request must drop")
	testing.expect_value(t, rcounters.overflow, u64(1))

	reqs, _ := render.raster_pending_count(&q)
	testing.expect_value(t, reqs, render.RASTER_QUEUE_CAP)

	// Worker converts all 256 to completions while running. Drain (which
	// also clears the in-flight set), then the dropped key re-enqueues
	// cleanly (retry next frame). Drain in two phases so the 257th
	// completion never overflows the completion ring.
	render.raster_worker_start(&q, &chain)
	_ra_wait_reqs_zero(t, &q)
	applied := _ra_drain_all(t, &q, &atlas, &cache, &chain, &fcounters, render.RASTER_QUEUE_CAP)
	testing.expect(t, render.raster_request_async(&q, full_key, 2, 0x5600, nil, true, termgrid.Damage_Target{}) == .Enqueued, "retry after drain must enqueue")
	testing.expect_value(t, rcounters.enqueued, u64(render.RASTER_QUEUE_CAP + 1))
	render.raster_worker_shutdown(&q)
	applied += render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, applied, render.RASTER_QUEUE_CAP + 1)
	testing.expect_value(t, rcounters.completed, u64(render.RASTER_QUEUE_CAP + 1))
}

@(test)
test_raster_group_split_preserves_targets :: proc(t: ^testing.T) {
	q: render.Raster_Queue
	counters: render.Raster_Counters
	render.raster_queue_init(&q, &counters)
	defer render.raster_queue_destroy(&q)
	key := render.cluster_key_make(0x4E2D, .Isolated)
	for i in 0..=render.RASTER_TARGETS_PER_GROUP {
		result := render.raster_request_async(&q, key, 0, 0x4E2D, nil, false, termgrid.Damage_Target{row = i, col = 0, epoch = 1})
		if i == 0 || i == render.RASTER_TARGETS_PER_GROUP {
			testing.expect(t, result == .Enqueued, "group boundary must enqueue")
		} else {
			testing.expect(t, result == .Coalesced, "group target must coalesce")
		}
	}
	reqs, _ := render.raster_pending_count(&q)
	testing.expect_value(t, reqs, 2)
	testing.expect_value(t, q.groups[q.reqs[0].group_index].target_count, render.RASTER_TARGETS_PER_GROUP)
	testing.expect_value(t, q.groups[q.reqs[1].group_index].target_count, 1)
}

@(test)
test_raster_completion_overflow_retries_targets :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 1)
	defer termgrid.terminal_destroy(&term)
	target := termgrid.terminal_damage_target(&term, 0, 0)
	key := render.cluster_key_make(0x4E2D, .Isolated)
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, target) == .Enqueued, "overflow test request must enqueue")
	q.comp_count = render.RASTER_COMPLETION_CAP
	render.raster_worker_start(&q, &chain)
	render.raster_worker_shutdown(&q)
	q.comp_count = 0
	render.raster_drain_completions(&q, &atlas, &cache, &term, &chain, &fcounters)
	q.shutdown = false
	render.raster_worker_start(&q, &chain)
	render.raster_worker_shutdown(&q)
	render.raster_drain_completions(&q, &atlas, &cache, &term, &chain, &fcounters)
	testing.expect(t, term.damage.dirty_rows[0].span_count > 0 || term.damage.dirty_rows[0].full, "overflow retry must retain target")
}

@(test)
test_raster_stale_target_fanout :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)
	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)
	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	term: termgrid.Terminal
	termgrid.terminal_init(&term, 2, 2)
	defer termgrid.terminal_destroy(&term)
	key := render.cluster_key_make(0x4E2D, .Isolated)
	stale := termgrid.terminal_damage_target(&term, 0, 0)
	termgrid.terminal_resize(&term, 3, 2)
	termgrid.damage_clear(&term.damage)
	valid := termgrid.terminal_damage_target(&term, 0, 1)
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, stale) == .Enqueued, "stale fanout request must enqueue")
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, valid) == .Coalesced, "valid fanout target must coalesce")
	render.raster_worker_start(&q, &chain)
	render.raster_worker_shutdown(&q)
	render.raster_drain_completions(&q, &atlas, &cache, &term, &chain, &fcounters)
	testing.expect(t, term.damage.dirty_rows[0].span_count > 0, "valid resize fanout target must damage")
	q.shutdown = false
	testing.expect(t, term.damage.dirty_rows[0].spans[0].col_start == 1, "stale resize target must be discarded")
	termgrid.damage_clear(&term.damage)
	stale = termgrid.terminal_damage_target(&term, 0, 0)
	termgrid.terminal_scroll_up(&term, 1)
	termgrid.damage_clear(&term.damage)
	valid = termgrid.terminal_damage_target(&term, 0, 1)
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, stale) == .Enqueued, "stale scroll request must enqueue")
	testing.expect(t, render.raster_request_async(&q, key, 2, 0x4E2D, nil, false, valid) == .Coalesced, "valid scroll target must coalesce")
	render.raster_worker_start(&q, &chain)
	render.raster_worker_shutdown(&q)
	render.raster_drain_completions(&q, &atlas, &cache, &term, &chain, &fcounters)
	testing.expect(t, term.damage.dirty_rows[0].span_count > 0, "valid scroll fanout target must damage")
}

@(test)
test_raster_shutdown_drains :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &chain)

	// 50 jobs, then immediate shutdown: pending work still converts.
	for i in 0..<50 {
		k := render.cluster_key_make(rune(0x4E00 + i), .Isolated)
		retries := 0
		for render.raster_request_async(&q, k, 2, u32(0x4E00 + i), nil, true, termgrid.Damage_Target{}) != .Enqueued {
			thread.yield()
			retries += 1
			testing.expect(t, retries < 1000000, "enqueue retry must terminate")
		}
	}

	render.raster_worker_shutdown(&q)
	testing.expect(t, q.worker == nil, "shutdown must join and destroy the thread")

	applied := render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, applied, 50)
	testing.expect_value(t, rcounters.completed, u64(50))
	reqs, comps := render.raster_pending_count(&q)
	testing.expect_value(t, reqs, 0)
	testing.expect_value(t, comps, 0)
	testing.expect_value(t, cache.live, 50)
}

@(test)
test_raster_pool_recycle_immune :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &chain)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 1, 2)
	defer termgrid.terminal_destroy(&term)
	frame: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&frame, 1, 2)
	defer render.render_compiler_destroy_v2(&frame)

	// Enqueue cluster A, then recycle the cell for cluster B. Requests
	// carry by-value key + shaped + marks, never a pool handle.
	_ra_word(&term, 0, 0, 0x4E2D)
	key_a := render.cluster_key_from_handle(termgrid.grid_get_cell(&term.grid, 0, 0).content, &term.grapheme_store, .Isolated)
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	_ra_word(&term, 0, 0, 0x4E2E)
	key_b := render.cluster_key_from_handle(termgrid.grid_get_cell(&term.grid, 0, 0).content, &term.grapheme_store, .Isolated)
	render.render_compile_full_v2(&frame, &term, &chain, &cache, &atlas, &fcounters, &q)
	testing.expect_value(t, rcounters.enqueued, u64(2))

	render.raster_worker_shutdown(&q)
	applied := render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, applied, 2)

	ga, hita := render.shape_cache_lookup(&cache, key_a)
	testing.expect(t, hita, "recycled cluster A must survive under its copied key")
	testing.expect_value(t, ga.shaped_codepoint, u32(0x4E2D))
	testing.expect(t, atlas.slots[ga.atlas_slot].valid, "cluster A slot must be valid")
	gb, hitb := render.shape_cache_lookup(&cache, key_b)
	testing.expect(t, hitb, "cluster B must cache under its own key")
	testing.expect_value(t, gb.shaped_codepoint, u32(0x4E2E))
	testing.expect(t, atlas.slots[gb.atlas_slot].valid, "cluster B slot must be valid")
}

@(test)
test_raster_eviction_impossible :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &chain)

	// Enqueue K (no slot is assigned at enqueue — the worker returns
	// pixels only), then churn the FIFO cursor with sync claims.
	fi, covered := render.fallback_resolve(&chain, 0x4E2D, nil)
	testing.expect(t, covered, "test glyph must be covered")
	key := render.cluster_key_make(0x4E2D, .Isolated)
	testing.expect(t, render.raster_request_async(&q, key, fi, 0x4E2D, nil, true, termgrid.Damage_Target{}) == .Enqueued, "enqueue must succeed")
	for i in 0..<3 {
		cp := u32(0x4E30 + i)
		cfi, ccov := render.fallback_resolve(&chain, cp, nil)
		testing.expect(t, ccov, "churn glyph must be covered")
		_, ok := render.atlas_dynamic_claim(&atlas, &chain, cfi, cp, nil)
		testing.expect(t, ok, "churn claim must succeed")
	}

	// Drain assigns the slot at today's cursor: tag and pixels line up.
	render.raster_worker_shutdown(&q)
	applied := render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, applied, 1)
	g, hit := render.shape_cache_lookup(&cache, key)
	testing.expect(t, hit, "evicted-past glyph must cache at drain")
	testing.expect_value(t, int(g.atlas_slot), render.FALLBACK_SLOT_BASE + 3)
	testing.expect(t, atlas.slots[g.atlas_slot].valid, "drain slot must be valid")
	want := (u64(fi) << 32) | u64(0x4E2D)
	testing.expect_value(t, atlas.fallback_tag[3], want)
}

@(test)
test_raster_ascii_gate :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	term: termgrid.Terminal
	termgrid.terminal_init(&term, 2, 8)
	defer termgrid.terminal_destroy(&term)
	termgrid.terminal_put_string(&term, "Hello, World! 123")

	legacy: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&legacy, 2, 8)
	defer render.render_compiler_destroy_v2(&legacy)
	shaped: render.Compiled_Frame_V2
	render.render_compiler_init_v2(&shaped, 2, 8)
	defer render.render_compiler_destroy_v2(&shaped)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)

	// Functional: async-context ASCII compiles bit-identical to legacy,
	// touching neither the queue nor any counter.
	render.render_compile_full_v2(&legacy, &term)
	render.render_compile_full_v2(&shaped, &term, &chain, &cache, &atlas, &fcounters, &q)
	testing.expect(t, len(legacy.cells) == len(shaped.cells), "frame sizes must match")
	for i in 0..<len(legacy.cells) {
		if legacy.cells[i] != shaped.cells[i] {
			testing.expect(t, false, "ASCII frames must be bit-identical")
			break
		}
	}
	testing.expect_value(t, cache.live, 0)
	reqs, comps := render.raster_pending_count(&q)
	testing.expect_value(t, reqs, 0)
	testing.expect_value(t, comps, 0)
	testing.expect_value(t, rcounters.enqueued, u64(0))
	testing.expect_value(t, rcounters.coalesced, u64(0))
	testing.expect_value(t, rcounters.overflow, u64(0))
	testing.expect_value(t, rcounters.contended, u64(0))
	testing.expect_value(t, rcounters.completed, u64(0))
	testing.expect_value(t, rcounters.apply_fail, u64(0))

	// Timing: async context within ±10% of the Phase 11 legacy baseline.
	legacy_best := time.Duration(1 << 62)
	async_best := time.Duration(1 << 62)
	for _ in 0..<30 {
		start := time.tick_now()
		render.render_compile_full_v2(&legacy, &term)
		if dt := time.tick_since(start); dt < legacy_best {
			legacy_best = dt
		}
		start = time.tick_now()
		render.render_compile_full_v2(&shaped, &term, &chain, &cache, &atlas, &fcounters, &q)
		if dt := time.tick_since(start); dt < async_best {
			async_best = dt
		}
	}
	testing.expect(t, f64(async_best) <= f64(legacy_best) * 1.10, "ASCII with queue must stay within ±10% of legacy")
}

@(test)
test_raster_race_stress :: proc(t: ^testing.T) {
	prim: render.Font_Rasterizer
	_fb_prim(t, &prim)
	defer render.font_rasterizer_destroy(&prim)
	chain: render.Fallback_Chain
	_fb_chain(t, &chain, &prim)
	defer render.fallback_chain_destroy(&chain)

	// Collect 1024 covered codepoints with their resolving slots so every
	// request completes ok (tag uniqueness needs real inserts).
	keys: [1024]_ra_key_font
	found := 0
	for cp := rune(0x4E00); cp < 0xA000 && found < len(keys); cp += 1 {
		if fi, covered := render.fallback_resolve(&chain, u32(cp), nil); covered {
			keys[found] = _ra_key_font{cp = cp, fi = fi}
			found += 1
		}
	}
	testing.expect_value(t, found, len(keys))

	atlas: render.Atlas
	render.atlas_init(&atlas, &prim)
	defer render.atlas_destroy(&atlas)

	cache: render.Shape_Cache
	fcounters: render.Fallback_Counters
	q: render.Raster_Queue
	rcounters: render.Raster_Counters
	_ra_q(&q, &rcounters)
	defer render.raster_queue_destroy(&q)
	render.raster_worker_start(&q, &chain)

	// 4 rounds x 256 distinct keys with the worker racing: overflow or
	// contention retries until accepted exactly once.
	for round in 0..<4 {
		for i in 0..<256 {
			kf := keys[round * 256 + i]
			k := render.cluster_key_make(kf.cp, .Isolated)
			retries := 0
			for render.raster_request_async(&q, k, kf.fi, u32(kf.cp), nil, true, termgrid.Damage_Target{}) != .Enqueued {
				thread.yield()
				retries += 1
				testing.expect(t, retries < 1000000, "retry must terminate")
				if retries >= 1000000 {
					break
				}
			}
		}
		_ra_wait_reqs_zero(t, &q)
		_ra_drain_all(t, &q, &atlas, &cache, &chain, &fcounters, 256)
	}

	render.raster_worker_shutdown(&q)
	testing.expect(t, q.worker == nil, "shutdown must join and destroy the thread")
	rest := render.raster_drain_completions(&q, &atlas, &cache, nil, &chain, &fcounters)
	testing.expect_value(t, rest, 0)

	// 1024 completions, cache live bounded by its cap with zero evictions,
	// every surviving dynamic tag unique.
	testing.expect_value(t, rcounters.completed, u64(1024))
	testing.expect_value(t, cache.live, render.SHAPE_CACHE_CAP)
	testing.expect_value(t, cache.evictions, u64(0))
	seen: [render.FALLBACK_SLOT_COUNT]u64
	nseen := 0
	for i in 0..<render.FALLBACK_SLOT_COUNT {
		tag := atlas.fallback_tag[i]
		if tag == 0 {
			continue
		}
		for j in 0..<nseen {
			testing.expect(t, seen[j] != tag, "dynamic tags must stay unique")
		}
		seen[nseen] = tag
		nseen += 1
	}
	testing.expect(t, nseen > 0, "dynamic region must hold tags")
}

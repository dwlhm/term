package terminal_tests

// Regression tests for the Extended Grapheme Cluster pool free-list.
//
// The pool previously tracked a "high water" index instead of a real free
// stack, which let it hand out a slot that was still referenced by a live cell
// and then free that slot underneath the new owner.

import "core:testing"
import egc "../egc"

_egc_slot_buf: [1]rune

_egc_slot :: proc(r: rune) -> []rune {
	_egc_slot_buf[0] = r
	return _egc_slot_buf[:]
}

_egc_expect_invariant :: proc(t: ^testing.T, pool: ^egc.Egc_Pool) {
	testing.expect_value(t, pool.free_count + pool.active_cnt, egc.MAX_EGC_ENTRIES)
	seen: [egc.MAX_EGC_ENTRIES]bool
	for i in 0..<pool.free_count {
		slot := int(pool.free_stack[i])
		testing.expect(t, !seen[slot], "a free slot must appear at most once in the free stack")
		seen[slot] = true
		testing.expect_value(t, pool.entries[slot].ref_count, 0)
	}
}

@test
test_egc_pool_release_order_never_reissues_live_slot :: proc(t: ^testing.T) {
	pool: egc.Egc_Pool
	egc.egc_pool_init(&pool)

	a, ok_a := egc.egc_pool_alloc(&pool, _egc_slot('a'))
	b, ok_b := egc.egc_pool_alloc(&pool, _egc_slot('b'))
	c, ok_c := egc.egc_pool_alloc(&pool, _egc_slot('c'))
	testing.expect(t, ok_a && ok_b && ok_c, "three allocations must succeed")

	// Out-of-order releases used to rewind a "high water" counter over the live
	// slot of 'a', so the next allocation handed out 'a's slot a second time.
	egc.egc_pool_release(&pool, c)
	egc.egc_pool_release(&pool, b)
	_egc_expect_invariant(t, &pool)

	d, ok_d := egc.egc_pool_alloc(&pool, _egc_slot('d'))
	testing.expect(t, ok_d, "allocation after release must succeed")
	testing.expect(t, d != a, "must never reissue the live slot of 'a'")

	runes_a := egc.egc_pool_get(&pool, a)
	testing.expect_value(t, len(runes_a), 1)
	testing.expect_value(t, runes_a[0], 'a')

	runes_d := egc.egc_pool_get(&pool, d)
	testing.expect_value(t, len(runes_d), 1)
	testing.expect_value(t, runes_d[0], 'd')
	_egc_expect_invariant(t, &pool)
}

@test
test_egc_pool_exhaustion_and_recovery :: proc(t: ^testing.T) {
	pool: egc.Egc_Pool
	egc.egc_pool_init(&pool)

	indices: [egc.MAX_EGC_ENTRIES]int
	for i in 0..<egc.MAX_EGC_ENTRIES {
		// Two-rune keys keep every cluster unique so dedup cannot mask exhaustion.
		idx, ok := egc.egc_pool_alloc(&pool, []rune{'A', rune(i)})
		if !ok {
			testing.expect(t, false, "pool must accept MAX_EGC_ENTRIES clusters")
			return
		}
		indices[i] = idx
	}
	_egc_expect_invariant(t, &pool)

	_, overflow_ok := egc.egc_pool_alloc(&pool, []rune{'Z', rune(9999)})
	testing.expect(t, !overflow_ok, "pool must refuse to exceed its slot count")

	for i in 0..<egc.MAX_EGC_ENTRIES / 2 {
		egc.egc_pool_release(&pool, indices[i])
	}
	_egc_expect_invariant(t, &pool)

	for i in 0..<egc.MAX_EGC_ENTRIES / 2 {
		_, ok := egc.egc_pool_alloc(&pool, []rune{'B', rune(i)})
		testing.expect(t, ok, "released slots must be reusable")
	}
	_egc_expect_invariant(t, &pool)
}

@test
test_egc_pool_dedup_reference_counting :: proc(t: ^testing.T) {
	pool: egc.Egc_Pool
	egc.egc_pool_init(&pool)

	cluster := []rune{'e', 0x0301} // e + combining acute
	first, ok_first := egc.egc_pool_alloc(&pool, cluster)
	second, ok_second := egc.egc_pool_alloc(&pool, cluster)
	testing.expect(t, ok_first && ok_second, "dedup allocations must succeed")
	testing.expect_value(t, first, second)
	testing.expect_value(t, len(egc.egc_pool_get(&pool, first)), 2)

	egc.egc_pool_release(&pool, first)
	testing.expect_value(t, len(egc.egc_pool_get(&pool, first)), 2)
	egc.egc_pool_release(&pool, second)
	testing.expect_value(t, len(egc.egc_pool_get(&pool, first)), 0)
	_egc_expect_invariant(t, &pool)
}

@test
test_egc_pool_survives_heavy_churn :: proc(t: ^testing.T) {
	pool: egc.Egc_Pool
	egc.egc_pool_init(&pool)

	live: [egc.MAX_EGC_ENTRIES]int
	live_runes: [egc.MAX_EGC_ENTRIES]rune
	live_count := 0

	for step in 0..<4096 {
		// Allocate a cluster keyed by a 3-rune sequence so it stays unique.
		key := rune(0x1000 + step % 512)
		slot, ok := egc.egc_pool_alloc(&pool, []rune{'x', key, rune(step % 7)})
		testing.expect(t, ok, "allocation must succeed under churn")
		if !ok do return
		live[live_count] = slot
		live_runes[live_count] = key
		live_count += 1

		// Release a pseudo-random earlier entry.
		if live_count > 4 {
			victim := (step * 7) % live_count
			egc.egc_pool_release(&pool, live[victim])
			live[victim] = live[live_count - 1]
			live_runes[victim] = live_runes[live_count - 1]
			live_count -= 1
		}
		_egc_expect_invariant(t, &pool)
	}

	// Every surviving entry must still expose its own runes.
	for i in 0..<live_count {
		runes := egc.egc_pool_get(&pool, live[i])
		testing.expect_value(t, len(runes), 3)
		testing.expect_value(t, runes[1], live_runes[i])
	}
}

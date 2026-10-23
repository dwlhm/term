package terminal_egc

MAX_EGC_ENTRIES :: 256
MAX_EGC_RUNES   :: 8

// EGC_INDEX_BASE offsets a pool index when stored in a cell's `char` field, so
// index 0 never collides with the empty-cell sentinel (char == 0 / ' '). A cell
// with Has_Egc set stores (EGC_INDEX_BASE + index) in `char`.
EGC_INDEX_BASE :: rune(0x110000)

Egc_Entry :: struct {
	runes:     [MAX_EGC_RUNES]rune,
	len:       u8,
	ref_count: u16,
}

// Egc_Pool is a fixed-slot pool plus an explicit free stack. Invariant:
// free_count + active_cnt == MAX_EGC_ENTRIES, and free_stack[0..<free_count]
// holds exactly the slots whose ref_count is zero.
Egc_Pool :: struct {
	entries:    [MAX_EGC_ENTRIES]Egc_Entry,
	free_stack: [MAX_EGC_ENTRIES]u16,
	free_count: int,
	active_cnt: int,
}

egc_pool_init :: proc(pool: ^Egc_Pool) {
	if pool == nil do return
	pool.active_cnt = 0
	pool.free_count = MAX_EGC_ENTRIES
	for i in 0..<MAX_EGC_ENTRIES {
		pool.entries[i] = Egc_Entry{}
		pool.free_stack[i] = u16(i)
	}
}

egc_pool_alloc :: proc(pool: ^Egc_Pool, runes: []rune) -> (index: int, ok: bool) {
	if pool == nil || len(runes) == 0 do return -1, false

	// Dedup: search if existing entry has identical runes
	rune_count := min(len(runes), MAX_EGC_RUNES)
	for i in 0..<MAX_EGC_ENTRIES {
		if pool.entries[i].ref_count > 0 && int(pool.entries[i].len) == rune_count {
			match := true
			for k in 0..<rune_count {
				if pool.entries[i].runes[k] != runes[k] {
					match = false
					break
				}
			}
			if match {
				pool.entries[i].ref_count += 1
				return i, true
			}
		}
	}

	// Pop a free slot from the LIFO stack
	if pool.free_count <= 0 do return -1, false
	pool.free_count -= 1
	slot := int(pool.free_stack[pool.free_count])
	pool.active_cnt += 1

	entry := &pool.entries[slot]
	entry.len = u8(rune_count)
	entry.ref_count = 1
	for k in 0..<rune_count {
		entry.runes[k] = runes[k]
	}

	return slot, true
}

egc_pool_retain :: proc(pool: ^Egc_Pool, index: int) {
	if pool == nil || index < 0 || index >= MAX_EGC_ENTRIES do return
	if pool.entries[index].ref_count > 0 {
		pool.entries[index].ref_count += 1
	}
}

egc_pool_release :: proc(pool: ^Egc_Pool, index: int) {
	if pool == nil || index < 0 || index >= MAX_EGC_ENTRIES do return
	entry := &pool.entries[index]
	if entry.ref_count > 0 {
		entry.ref_count -= 1
		if entry.ref_count == 0 {
			entry.len = 0
			// Push back only if this slot is not already free, keeping the
			// stack a perfect partition of the slot set.
			if pool.free_count < MAX_EGC_ENTRIES {
				pool.free_stack[pool.free_count] = u16(index)
				pool.free_count += 1
			}
			pool.active_cnt = max(0, pool.active_cnt - 1)
		}
	}
}

egc_pool_get :: proc(pool: ^Egc_Pool, index: int) -> []rune {
	if pool == nil || index < 0 || index >= MAX_EGC_ENTRIES do return nil
	entry := &pool.entries[index]
	if entry.ref_count == 0 do return nil
	return entry.runes[:entry.len]
}

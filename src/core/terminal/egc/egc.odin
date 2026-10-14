package terminal_egc

MAX_EGC_ENTRIES :: 256
MAX_EGC_RUNES   :: 8

Egc_Entry :: struct {
	runes:     [MAX_EGC_RUNES]rune,
	len:       u8,
	ref_count: u16,
}

Egc_Pool :: struct {
	entries:    [MAX_EGC_ENTRIES]Egc_Entry,
	free_head:  int,
	free_list:  [MAX_EGC_ENTRIES]u16,
	active_cnt: int,
}

egc_pool_init :: proc(pool: ^Egc_Pool) {
	if pool == nil do return
	pool.active_cnt = 0
	pool.free_head = 0
	for i in 0..<MAX_EGC_ENTRIES {
		pool.entries[i] = Egc_Entry{}
		pool.free_list[i] = u16(i)
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

	// Allocate free slot
	if pool.free_head >= MAX_EGC_ENTRIES do return -1, false
	slot := int(pool.free_list[pool.free_head])
	pool.free_head += 1
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
			pool.free_head -= 1
			if pool.free_head >= 0 {
				pool.free_list[pool.free_head] = u16(index)
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

package diag

import "core:sync"
import "core:time"

Diag_Snapshot :: struct {
	strategy:  string,
	tab_count: int,
	grid_rows: int,
	grid_cols: int,
}

@(private)
_counters_mutex: sync.Mutex

@(private)
_current_snapshot: Diag_Snapshot

diag_set_snapshot :: proc(s: Diag_Snapshot) {
	sync.mutex_lock(&_counters_mutex)
	defer sync.mutex_unlock(&_counters_mutex)
	_current_snapshot = s
}

diag_get_snapshot :: proc() -> Diag_Snapshot {
	sync.mutex_lock(&_counters_mutex)
	defer sync.mutex_unlock(&_counters_mutex)
	return _current_snapshot
}

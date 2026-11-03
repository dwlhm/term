package platform_poller

import "core:c"
import "core:sys/posix"

// Linux: poll(2) keeps no per-call kernel state worth caching.
Poller :: struct {
	capacity: int,
}

poller_init :: proc(p: ^Poller, capacity: int, allocator := context.allocator) -> bool {
	p^ = {capacity = capacity}
	return true
}

poller_destroy :: proc(p: ^Poller) {
	p^ = {}
}

// poller_poll is posix.poll(raw_data(fds), len(fds), timeout_ms).
poller_poll :: proc(p: ^Poller, fds: []posix.pollfd, timeout_ms: int) -> int {
	if len(fds) > p.capacity do return -1
	return int(posix.poll(raw_data(fds), posix.nfds_t(len(fds)), c.int(timeout_ms)))
}

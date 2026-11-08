package platform_ipc

import "core:c"
import "core:sys/posix"

// Poll_Set backend on Linux: poll(2) keeps no per-call kernel state worth
// caching (formerly platform/poller).
@(private)
_Backend :: struct {
	capacity: int,
}

@(private)
_backend_init :: proc(p: ^_Backend, capacity: int, allocator := context.allocator) -> bool {
	p^ = {capacity = capacity}
	return true
}

@(private)
_backend_destroy :: proc(p: ^_Backend) {
	p^ = {}
}

// _backend_poll is posix.poll(raw_data(fds), len(fds), timeout_ms).
@(private)
_backend_poll :: proc(p: ^_Backend, fds: []posix.pollfd, timeout_ms: int) -> int {
	if len(fds) > p.capacity do return -1
	return int(posix.poll(raw_data(fds), posix.nfds_t(len(fds)), c.int(timeout_ms)))
}

package platform_poller

// Readiness waiting for one event loop. poller_poll is called like
// posix.poll: each round passes its full pollfd set (what every fd wants
// now, derived from state) and gets the same level-triggered revents back
// (IN, OUT, HUP; NVAL for an fd that is not open). Fds with fd < 0 are
// skipped. One Poller per loop thread; it is not shared.
//
// macOS (poller_darwin.odin): poll(2) builds and tears down its kernel
// state on every call, which caps a loop that wakes per ~1 KiB of PTY
// output (macOS PTYs buffer only that much). The Poller keeps one kqueue
// across rounds instead: every round re-adds its interests (an fd closed
// and reopened under the same number is registered again) and deletes
// those that went away. Linux (poller_linux.odin): poll(2).
//
// Lifecycle: poller_init (allocates everything; capacity = the most fds one
// round passes) → poller_poll per round → poller_destroy.

POLLER_MAX_FD :: 1 << 16 // table bound when RLIMIT_NOFILE is unlimited

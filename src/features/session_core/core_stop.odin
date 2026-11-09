package feature_session_core

// Stopping the core: SIGTERM/SIGINT or core_request_stop are a planned
// restart (core_handover: holders keep every program, the next core restores
// the saved screens). The request pokes the core's Poll_Set, so a stop that
// lands just before the wait still wakes the loop.

import "core:sync"
import "core:sys/posix"
import ipc "../../platform/ipc"

@(private = "file")
_stop_requested: bool

@(private = "file")
_shutdown_requested: bool

// _stop_set: the running core's Poll_Set, nil when none runs.
@(private = "file")
_stop_set: ^ipc.Poll_Set

// core_request_stop asks the running core to stop (as SIGTERM does).
core_request_stop :: proc "contextless" () {
	sync.atomic_store(&_stop_requested, true)
	if set := sync.atomic_load(&_stop_set); set != nil do ipc.poll_set_poke(set)
}

// core_request_shutdown asks the running core to shut down completely (no handover).
core_request_shutdown :: proc "contextless" () {
	sync.atomic_store(&_shutdown_requested, true)
	if set := sync.atomic_load(&_stop_set); set != nil do ipc.poll_set_poke(set)
}

@(private)
_stop_is_requested :: proc() -> bool { return sync.atomic_load(&_stop_requested) }

@(private)
_shutdown_is_requested :: proc() -> bool { return sync.atomic_load(&_shutdown_requested) }

@(private)
_stop_open :: proc(c: ^Core) {
	sync.atomic_store(&_stop_requested, false)
	sync.atomic_store(&_shutdown_requested, false)
	sync.atomic_store(&_stop_set, &c.set)
}

@(private)
_stop_close :: proc(c: ^Core) {
	sync.atomic_compare_exchange_strong(&_stop_set, &c.set, nil)
}

@(private = "file")
_stop_handler :: proc "c" (sig: posix.Signal) {
	saved := posix.errno()
	core_request_stop()
	posix.errno(saved)
}

@(private)
_install_stop_signals :: proc() {
	posix.signal(.SIGTERM, _stop_handler)
	posix.signal(.SIGINT, _stop_handler)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

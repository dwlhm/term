package platform_ipc_contract

// Owner runs a Server on its own Poll_Set in a thread of its own, the way an
// application loop would, so a test thread can block in client_call. Every
// event goes to handle on the owner thread; nothing else touches the Server
// until owner_close.

import "core:sync"
import "core:testing"
import "core:thread"
import ipc "../"

Owner :: struct {
	set:      ipc.Poll_Set,
	srv:      ipc.Server,
	handle:   proc(o: ^Owner, ev: ipc.Server_Event), // nil = echo
	round:    proc(o: ^Owner),                      // optional, before each wait
	due_ns:   i64,                                  // for poll_set_wait; -1 = none
	data:     rawptr,
	stopping: bool, // atomic
	thread:   ^thread.Thread,
}

// owner_open opens the set and the Server on the test thread (so an open
// error fails fast), then starts the loop.
owner_open :: proc(t: ^testing.T, o: ^Owner, at: ipc.Endpoint, proto: Maybe(ipc.Protocol) = nil, opts := ipc.Server_Opts{}, loc := #caller_location) -> bool {
	if o.handle == nil do o.handle = echo
	o.due_ns = -1
	if !expect_ok(t, ipc.poll_set_init(&o.set, 64), "poll_set_init", loc) do return false
	if !expect_ok(t, ipc.server_open(&o.srv, at, proto.? or_else test_protocol(), &o.set, opts), "server_open", loc) {
		ipc.poll_set_destroy(&o.set)
		return false
	}
	o.thread = thread.create_and_start_with_poly_data(o, _owner_loop, context)
	return true
}

owner_close :: proc(o: ^Owner) {
	if o.thread != nil {
		sync.atomic_store(&o.stopping, true)
		ipc.poll_set_poke(&o.set)
		thread.join(o.thread)
		thread.destroy(o.thread)
		o.thread = nil
	}
	ipc.server_close(&o.srv)
	ipc.poll_set_destroy(&o.set)
}

@(private = "file")
_owner_loop :: proc(o: ^Owner) {
	for !sync.atomic_load(&o.stopping) {
		if o.round != nil do o.round(o)
		ipc.poll_set_wait(&o.set, o.due_ns)
		_ = ipc.poll_set_woken(&o.set)
		for ev in ipc.server_next(&o.srv) do o.handle(o, ev)
	}
}

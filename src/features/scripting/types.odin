package feature_scripting

// Effect-inspired Fiber Runtime types for term scripting.
// Fibers represent green threads (Lua coroutines) with structured
// concurrency and LIFO resource scopes.

import "core:time"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

Fiber_Id :: distinct u64

Fiber_State :: enum u8 {
	Ready,
	Running,
	Suspended,
	Done,
	Failed,
	Interrupted,
}

Wait_Kind :: enum u8 {
	None,
	Sleep,
	Ipc_Ticket,
	Join_Fiber,
	Race_Group,
	All_Group,
}

Finalizer_Proc :: #type proc(data: rawptr)

Finalizer :: struct {
	fn:   Finalizer_Proc,
	data: rawptr,
}

Scope :: struct {
	finalizers: [dynamic]Finalizer,
	closed:     bool,
}

Fiber :: struct {
	id:          Fiber_Id,
	parent_id:   Fiber_Id,
	co:          ^lua.State,
	state:       Fiber_State,
	scope:       Scope,

	// Suspension details
	wait_kind:   Wait_Kind,
	deadline:    time.Time,
	ticket:      ipc.Ticket,
	join_target: Fiber_Id,

	// Structured Concurrency
	children:    [dynamic]Fiber_Id,
	group:       [dynamic]Fiber_Id,

	// Outcome
	error_msg:   string,
	interrupted: bool,
}

Scheduler :: struct {
	main_L:      ^lua.State,
	fibers:      map[Fiber_Id]^Fiber,
	next_id:     u64,
	current:     ^Fiber,
	root_id:     Fiber_Id,
	stopping:    bool,
	ipc_client:  ^ipc.Client,
}

package feature_scripting

// Fiber lifecycle and coroutine state management.

import "core:c"
import "core:strings"
import lua "../../platform/lua"

fiber_create :: proc(sched: ^Scheduler, parent_id: Fiber_Id, co: ^lua.State) -> ^Fiber {
	sched.next_id += 1
	f := new(Fiber)
	f.id = Fiber_Id(sched.next_id)
	f.parent_id = parent_id
	f.co = co
	f.state = .Ready
	f.children = make([dynamic]Fiber_Id)
	f.group = make([dynamic]Fiber_Id)
	scope_init(&f.scope)

	sched.fibers[f.id] = f

	// Register with parent if exists
	if parent_id != 0 {
		if parent, ok := sched.fibers[parent_id]; ok {
			append(&parent.children, f.id)
		}
	}
	return f
}

fiber_destroy :: proc(f: ^Fiber) {
	scope_destroy(&f.scope)
	delete(f.children)
	delete(f.group)
	if len(f.error_msg) > 0 {
		delete(f.error_msg)
	}
	free(f)
}

// fiber_interrupt marks a fiber as interrupted, closes its scope, and
// recursively interrupts all child fibers (cascading cancellation).
fiber_interrupt :: proc(sched: ^Scheduler, f: ^Fiber) {
	if f.state == .Done || f.state == .Failed || f.state == .Interrupted {
		return
	}
	f.state = .Interrupted
	f.interrupted = true
	scope_close(&f.scope)

	// Cascading cancellation: recursively interrupt child fibers
	for child_id in f.children {
		if child, ok := sched.fibers[child_id]; ok {
			fiber_interrupt(sched, child)
		}
	}
}

// fiber_resume resumes execution of the fiber's coroutine thread.
fiber_resume :: proc(sched: ^Scheduler, f: ^Fiber, nargs: int) -> int {
	if f.state == .Interrupted || f.state == .Done || f.state == .Failed {
		return lua.OK
	}
	f.state = .Running
	sched.current = f

	nres: c.int
	status := lua.resume(f.co, nil, c.int(nargs), &nres)
	sched.current = nil

	switch status {
	case lua.OK:
		f.state = .Done
		scope_close(&f.scope)
	case lua.YIELD:
		f.state = .Suspended
	case: // lua.ERRRUN, lua.ERRMEM, etc.
		f.state = .Failed
		msg := lua.tostring(f.co, -1)
		f.error_msg = strings.clone(msg)
		scope_close(&f.scope)
	}
	return int(status)
}

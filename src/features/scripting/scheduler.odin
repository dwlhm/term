package feature_scripting

// Event loop and Fiber scheduler.
// Drives cooperative multitasking across fibers, timers, and IPC tickets.

import "core:c"
import "core:time"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

scheduler_init :: proc(sched: ^Scheduler, main_L: ^lua.State, ipc_client: ^ipc.Client = nil) {
	sched.main_L = main_L
	sched.fibers = make(map[Fiber_Id]^Fiber)
	sched.next_id = 0
	sched.current = nil
	sched.root_id = 0
	sched.stopping = false
	sched.ipc_client = ipc_client
}

scheduler_destroy :: proc(sched: ^Scheduler) {
	for id, f in sched.fibers {
		fiber_destroy(f)
	}
	delete(sched.fibers)
}

scheduler_spawn_co :: proc(sched: ^Scheduler, parent_id: Fiber_Id, co: ^lua.State) -> ^Fiber {
	f := fiber_create(sched, parent_id, co)
	if sched.root_id == 0 {
		sched.root_id = f.id
	}
	return f
}

// scheduler_step runs one pass over active fibers.
// Returns true while there are active or suspended fibers still waiting.
scheduler_step :: proc(sched: ^Scheduler) -> bool {
	now := time.now()
	has_pending := false

	// Collect IDs to avoid mutating map during iteration
	ids := make([dynamic]Fiber_Id, context.temp_allocator)
	for id in sched.fibers {
		append(&ids, id)
	}

	for id in ids {
		f := sched.fibers[id] or_continue

		#partial switch f.state {
		case .Ready:
			has_pending = true
			fiber_resume(sched, f, 0)

		case .Suspended:
			has_pending = true
			_check_suspended_fiber(sched, f, now)

		case .Running:
			has_pending = true

		case .Done, .Failed, .Interrupted:
			// Completed fiber
		}
	}

	// Check if root fiber is done
	if root, ok := sched.fibers[sched.root_id]; ok {
		if root.state == .Done || root.state == .Failed || root.state == .Interrupted {
			return false
		}
	}
	return has_pending
}

@(private = "file")
_check_suspended_fiber :: proc(sched: ^Scheduler, f: ^Fiber, now: time.Time) {
	switch f.wait_kind {
	case .None:
		f.state = .Ready
		fiber_resume(sched, f, 0)

	case .Sleep:
		if time.diff(f.deadline, now) >= 0 {
			f.wait_kind = .None
			f.state = .Ready
			fiber_resume(sched, f, 0)
		}

	case .Join_Fiber:
		if target, ok := sched.fibers[f.join_target]; ok {
			if target.state == .Done || target.state == .Failed || target.state == .Interrupted {
				f.wait_kind = .None
				f.state = .Ready
				fiber_resume(sched, f, 0)
			}
		} else {
			f.wait_kind = .None
			f.state = .Ready
			fiber_resume(sched, f, 0)
		}

	case .Race_Group:
		if task_check_race(sched, f) {
			fiber_resume(sched, f, 0)
		}

	case .All_Group:
		if done, _ := task_check_all(sched, f); done {
			fiber_resume(sched, f, 0)
		}

	case .Ipc_Ticket:
		// Handled by IPC poll events
	}
}

// scheduler_run drives the scheduler loop until the root fiber finishes.
scheduler_run :: proc(sched: ^Scheduler) -> (ok: bool, err_msg: string) {
	for scheduler_step(sched) {
		time.sleep(500 * time.Microsecond)
	}

	root := sched.fibers[sched.root_id]
	if root == nil do return false, "no root fiber"

	if root.state == .Failed {
		return false, root.error_msg
	}
	if root.state == .Interrupted {
		return false, "interrupted"
	}
	return root.state == .Done, ""
}

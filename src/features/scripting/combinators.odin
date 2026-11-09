package feature_scripting

// Structured Concurrency combinators (Effect.all, Effect.race, fork, sleep).

import "core:time"
import lua "../../platform/lua"

// task_sleep suspends the fiber until duration elapses.
task_sleep :: proc(f: ^Fiber, d: time.Duration) {
	f.wait_kind = .Sleep
	f.deadline = time.time_add(time.now(), d)
	f.state = .Suspended
}

// task_fork spawns a supervised child fiber.
task_fork :: proc(sched: ^Scheduler, parent: ^Fiber, child_co: ^lua.State) -> ^Fiber {
	return scheduler_spawn_co(sched, parent.id, child_co)
}

// task_setup_race registers a group of fibers in an Effect.race.
// The first fiber to complete wins; all remaining fibers are interrupted.
task_setup_race :: proc(parent: ^Fiber, members: []^Fiber) {
	parent.wait_kind = .Race_Group
	parent.state = .Suspended
	clear(&parent.group)

	for m in members {
		append(&parent.group, m.id)
		clear(&m.group)
		for other in members {
			append(&m.group, other.id)
		}
	}
}

// task_check_race checks if any fiber in the race group has finished.
task_check_race :: proc(sched: ^Scheduler, parent: ^Fiber) -> bool {
	if parent.wait_kind != .Race_Group do return false

	for id in parent.group {
		m := sched.fibers[id] or_continue
		if m.state == .Done || m.state == .Failed {
			// Winner found! Interrupt all others in the group
			for other_id in parent.group {
				if other_id != id {
					if other, ok := sched.fibers[other_id]; ok {
						fiber_interrupt(sched, other)
					}
				}
			}
			parent.wait_kind = .None
			parent.state = .Ready
			return true
		}
	}
	return false
}

// task_setup_all registers a group of fibers in an Effect.all.
// All must succeed; if any fails, all remaining are interrupted.
task_setup_all :: proc(parent: ^Fiber, members: []^Fiber) {
	parent.wait_kind = .All_Group
	parent.state = .Suspended
	clear(&parent.group)

	for m in members {
		append(&parent.group, m.id)
	}
}

// task_check_all checks if all fibers have finished, or if any failed.
task_check_all :: proc(sched: ^Scheduler, parent: ^Fiber) -> (done: bool, ok: bool) {
	if parent.wait_kind != .All_Group do return false, false

	all_done := true
	for id in parent.group {
		m := sched.fibers[id] or_continue
		if m.state == .Failed || m.state == .Interrupted {
			// One failed/interrupted: cancel the rest
			for other_id in parent.group {
				if other_id != id {
					if other, ok_other := sched.fibers[other_id]; ok_other {
						fiber_interrupt(sched, other)
					}
				}
			}
			parent.wait_kind = .None
			parent.state = .Ready
			return true, false
		}
		if m.state != .Done {
			all_done = false
		}
	}

	if all_done {
		parent.wait_kind = .None
		parent.state = .Ready
		return true, true
	}
	return false, false
}

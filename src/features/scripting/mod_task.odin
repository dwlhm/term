package feature_scripting

// `term.task` Lua module: structured concurrency and timers.

import "base:runtime"
import "core:c"
import "core:time"
import lua "../../platform/lua"

open_mod_task :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	methods := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"sleep", _task_sleep},
		{"fork", _task_fork},
		{"race", _task_race},
		{"all", _task_all},
	}

	for m in methods {
		lua.pushcfunction(L, m.fn)
		lua.setfield(L, -2, m.name)
	}
	return 1
}

@(private = "file")
_task_sleep :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.current == nil {
		lua.pushstring(L, "task.sleep called outside of a running fiber")
		return lua.error(L)
	}
	context.allocator = vm.sched.allocator

	sec := lua.tonumberx(L, 1, nil)
	if sec < 0 do sec = 0
	d := time.Duration(sec * f64(time.Second))

	task_sleep(vm.sched.current, d)
	return lua.yield(L, 0)
}

@(private = "file")
_task_fork :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.current == nil {
		lua.pushstring(L, "task.fork called outside of a running fiber")
		return lua.error(L)
	}
	context.allocator = vm.sched.allocator

	if lua.type(L, 1) != .Function {
		lua.pushstring(L, "task.fork expects a function")
		return lua.error(L)
	}

	// Create child coroutine
	child_co := lua.newthread(vm.sched.main_L)
	// Push function to top of L and move to child_co
	lua.pushvalue(L, 1)
	lua.xmove(L, child_co, 1)
	lua.pop(L, 1) // pop child_co from L

	child_f := task_fork(&vm.sched, vm.sched.current, child_co)
	lua.pushinteger(L, lua.Integer(child_f.id))
	return 1
}

@(private = "file")
_task_race :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.current == nil {
		lua.pushstring(L, "task.race called outside of a running fiber")
		return lua.error(L)
	}
	context.allocator = vm.sched.allocator

	if lua.type(L, 1) != .Table {
		lua.pushstring(L, "task.race expects a table of functions")
		return lua.error(L)
	}

	members: [dynamic]^Fiber
	defer delete(members)

	n := int(lua.rawlen(L, 1))
	for i in 1 ..= n {
		lua.rawgeti(L, 1, lua.Integer(i))
		if lua.type(L, -1) == .Function {
			child_co := lua.newthread(vm.sched.main_L)
			lua.insert(L, -2) // put child_co below function
			lua.xmove(L, child_co, 1)
			lua.pop(L, 1) // pop child_co

			child_f := task_fork(&vm.sched, vm.sched.current, child_co)
			append(&members, child_f)
		} else {
			lua.pop(L, 1)
		}
	}

	if len(members) == 0 {
		return 0
	}

	task_setup_race(vm.sched.current, members[:])
	return lua.yield(L, 0)
}

@(private = "file")
_task_all :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.current == nil {
		lua.pushstring(L, "task.all called outside of a running fiber")
		return lua.error(L)
	}
	context.allocator = vm.sched.allocator

	if lua.type(L, 1) != .Table {
		lua.pushstring(L, "task.all expects a table of functions")
		return lua.error(L)
	}

	members: [dynamic]^Fiber
	defer delete(members)

	n := int(lua.rawlen(L, 1))
	for i in 1 ..= n {
		lua.rawgeti(L, 1, lua.Integer(i))
		if lua.type(L, -1) == .Function {
			child_co := lua.newthread(vm.sched.main_L)
			lua.insert(L, -2)
			lua.xmove(L, child_co, 1)
			lua.pop(L, 1)

			child_f := task_fork(&vm.sched, vm.sched.current, child_co)
			append(&members, child_f)
		} else {
			lua.pop(L, 1)
		}
	}

	if len(members) == 0 {
		return 0
	}

	task_setup_all(vm.sched.current, members[:])
	return lua.yield(L, 0)
}

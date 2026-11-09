package feature_scripting_tests

// Unit tests for Effect-style Fiber Runtime (Scope LIFO, Cascading Interruption, Race, All).

import "core:testing"
import "core:time"
import lua "../../../platform/lua"
import scripting ".."

@(test)
test_scope_lifo :: proc(t: ^testing.T) {
	s: scripting.Scope
	scripting.scope_init(&s)

	order: [dynamic]int
	defer delete(order)

	ctx1 := struct { order: ^[dynamic]int, val: int }{&order, 1}
	ctx2 := struct { order: ^[dynamic]int, val: int }{&order, 2}
	ctx3 := struct { order: ^[dynamic]int, val: int }{&order, 3}

	f_proc :: proc(data: rawptr) {
		p := (^struct { order: ^[dynamic]int, val: int })(data)
		append(p.order, p.val)
	}

	scripting.scope_add_finalizer(&s, f_proc, &ctx1)
	scripting.scope_add_finalizer(&s, f_proc, &ctx2)
	scripting.scope_add_finalizer(&s, f_proc, &ctx3)

	scripting.scope_close(&s)

	// LIFO expectation: 3, 2, 1
	testing.expect_value(t, len(order), 3)
	testing.expect_value(t, order[0], 3)
	testing.expect_value(t, order[1], 2)
	testing.expect_value(t, order[2], 1)

	scripting.scope_destroy(&s)
}

@(test)
test_cascading_interruption :: proc(t: ^testing.T) {
	sched: scripting.Scheduler
	scripting.scheduler_init(&sched, nil)
	defer scripting.scheduler_destroy(&sched)

	parent := scripting.fiber_create(&sched, 0, nil)
	child1 := scripting.fiber_create(&sched, parent.id, nil)
	child2 := scripting.fiber_create(&sched, parent.id, nil)
	grandchild := scripting.fiber_create(&sched, child1.id, nil)

	cleaned := 0
	clean_proc :: proc(data: rawptr) {
		c := (^int)(data)
		c^ += 1
	}

	scripting.scope_add_finalizer(&parent.scope, clean_proc, &cleaned)
	scripting.scope_add_finalizer(&child1.scope, clean_proc, &cleaned)
	scripting.scope_add_finalizer(&child2.scope, clean_proc, &cleaned)
	scripting.scope_add_finalizer(&grandchild.scope, clean_proc, &cleaned)

	// Interrupting parent should cancel all 4 and run their finalizers
	scripting.fiber_interrupt(&sched, parent)

	testing.expect(t, parent.interrupted)
	testing.expect(t, child1.interrupted)
	testing.expect(t, child2.interrupted)
	testing.expect(t, grandchild.interrupted)
	testing.expect_value(t, cleaned, 4)
}

@(test)
test_race_winner_cancels_loser :: proc(t: ^testing.T) {
	sched: scripting.Scheduler
	scripting.scheduler_init(&sched, nil)
	defer scripting.scheduler_destroy(&sched)

	parent := scripting.fiber_create(&sched, 0, nil)
	f1 := scripting.fiber_create(&sched, parent.id, nil)
	f2 := scripting.fiber_create(&sched, parent.id, nil)

	members := [2]^scripting.Fiber{f1, f2}
	scripting.task_setup_race(parent, members[:])

	// Simulate f1 finishing first
	f1.state = .Done

	done := scripting.task_check_race(&sched, parent)
	testing.expect(t, done)
	testing.expect_value(t, parent.state, scripting.Fiber_State.Ready)
	testing.expect_value(t, f1.state, scripting.Fiber_State.Done)
	testing.expect(t, f2.interrupted)
}

@(test)
test_all_failure_cancels_siblings :: proc(t: ^testing.T) {
	sched: scripting.Scheduler
	scripting.scheduler_init(&sched, nil)
	defer scripting.scheduler_destroy(&sched)

	parent := scripting.fiber_create(&sched, 0, nil)
	f1 := scripting.fiber_create(&sched, parent.id, nil)
	f2 := scripting.fiber_create(&sched, parent.id, nil)

	members := [2]^scripting.Fiber{f1, f2}
	scripting.task_setup_all(parent, members[:])

	// Simulate f1 failing
	f1.state = .Failed

	done, ok := scripting.task_check_all(&sched, parent)
	testing.expect(t, done)
	testing.expect(t, !ok) // failed
	testing.expect_value(t, parent.state, scripting.Fiber_State.Ready)
	testing.expect(t, f2.interrupted)
}

@(test)
test_fiber_lua_coroutine_execution :: proc(t: ^testing.T) {
	L := lua.luaL_newstate()
	testing.expect(t, L != nil)
	defer lua.close(L)

	lua.luaL_requiref(L, "_G", lua.luaopen_base, 1)
	lua.pop(L, 1)
	lua.luaL_requiref(L, "coroutine", lua.luaopen_coroutine, 1)
	lua.pop(L, 1)

	sched: scripting.Scheduler
	scripting.scheduler_init(&sched, L)
	defer scripting.scheduler_destroy(&sched)

	script := "return function() coroutine.yield(); return 42 end"
	err := lua.luaL_loadbufferx(L, raw_data(script), len(script), "test", "t")
	testing.expect_value(t, err, lua.OK)

	// Call the chunk to get the function
	pcall_res := lua.pcall(L, 0, 1, 0)
	testing.expect_value(t, pcall_res, lua.OK)

	// Create a new coroutine thread for the fiber
	co := lua.newthread(L)
	// Move the function to the new thread
	lua.pushvalue(L, -2)
	lua.xmove(L, co, 1)
	lua.pop(L, 2) // pop thread and original function

	fiber := scripting.scheduler_spawn_co(&sched, 0, co)
	testing.expect_value(t, fiber.state, scripting.Fiber_State.Ready)

	// First step: resumes and yields
	step1 := scripting.scheduler_step(&sched)
	if fiber.state == .Failed {
		testing.fail_now(t, fiber.error_msg)
	}
	testing.expect(t, step1)
	testing.expect_value(t, fiber.state, scripting.Fiber_State.Suspended)

	// Wake up suspended fiber
	fiber.wait_kind = .None
	fiber.state = .Ready

	// Second step: resumes to completion
	step2 := scripting.scheduler_step(&sched)
	testing.expect(t, !step2) // no more pending work
	testing.expect_value(t, fiber.state, scripting.Fiber_State.Done)
}

@(test)
test_script_runtime_program_execution :: proc(t: ^testing.T) {
	vm := scripting.script_vm_create()
	testing.expect(t, vm != nil)
	defer scripting.script_vm_destroy(vm)

	script := `
		local term = require "term"
		local task = term.task

		return term.program {
			name = "test-fibers",
			main = function()
				local step = 0
				task.fork(function()
					task.sleep(0.001)
					step = 1
				end)
				task.sleep(0.005)
				assert(step == 1, "child fiber should have run")
			end,
		}
	`

	err := lua.luaL_loadbufferx(vm.L, raw_data(script), len(script), "test", "t")
	testing.expect_value(t, err, lua.OK)

	// Call chunk to get manifest table
	pcall_err := lua.pcall(vm.L, 0, 1, 0)
	testing.expect_value(t, pcall_err, lua.OK)
	testing.expect(t, lua.type(vm.L, -1) == .Table)

	// Extract main
	lua.getfield(vm.L, -1, "main")
	testing.expect(t, lua.type(vm.L, -1) == .Function)

	root_co := lua.newthread(vm.L)
	lua.insert(vm.L, -2)
	lua.xmove(vm.L, root_co, 1)
	lua.pop(vm.L, 2)

	_ = scripting.scheduler_spawn_co(&vm.sched, 0, root_co)

	ok, err_msg := scripting.scheduler_run(&vm.sched)
	if !ok {
		testing.fail_now(t, err_msg)
	}
	testing.expect(t, ok)
}

@(test)
test_script_runtime_session_options :: proc(t: ^testing.T) {
	vm := scripting.script_vm_create()
	defer scripting.script_vm_destroy(vm)

	script := `
		local term = require "term"
		local session = term.session

		return term.program {
			name = "test-session-opts",
			main = function()
				assert(session.whoami() == nil, "whoami should be nil outside term")
			end,
		}
	`

	err := lua.luaL_loadbufferx(vm.L, raw_data(script), len(script), "test", "t")
	testing.expect_value(t, err, lua.OK)

	pcall_err := lua.pcall(vm.L, 0, 1, 0)
	testing.expect_value(t, pcall_err, lua.OK)

	lua.getfield(vm.L, -1, "main")
	root_co := lua.newthread(vm.L)
	lua.insert(vm.L, -2)
	lua.xmove(vm.L, root_co, 1)
	lua.pop(vm.L, 2)

	_ = scripting.scheduler_spawn_co(&vm.sched, 0, root_co)

	ok, err_msg := scripting.scheduler_run(&vm.sched)
	if !ok {
		testing.fail_now(t, err_msg)
	}
	testing.expect(t, ok)
}

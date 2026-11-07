package feature_automation

// Waiting for screens: a target is looked for on each snapshot, and between
// two looks the runner waits for the screen to change (MSG_SETTLE), never on
// a timer. A known interruption on screen (contract.on.interrupt, then
// adapter.interrupts: { {target, steps}, … }) runs its steps once per wait.

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import lua "../../platform/lua"
import ipc "../../platform/ipc"

// run_wait_for waits until the target at idx shows (present: its match is
// left on the stack) or is gone (nothing left). false: the run stopped.
run_wait_for :: proc(r: ^Runner, idx: c.int, present: bool, timeout: time.Duration) -> bool {
	L := r.vm.L
	target := lua.absindex(L, idx)
	deadline := time.tick_add(time.tick_now(), timeout)
	handled: [8]bool
	for r.stop == .Ok {
		gen := run_push_screen(r) or_return // screen
		matched := run_match(r, -1, target) or_return // screen, match
		if matched == present {
			lua.rotate(L, -2, 1)
			lua.pop(L, 1)
			if !present do lua.pop(L, 1)
			return true
		}
		lua.pop(L, 1)
		if run_check_exited(r) {
			lua.pop(L, 1)
			return false
		}
		if _interrupt(r, &handled) {
			lua.pop(L, 1)
			continue
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			what := run_describe(r, target)
			_evidence(r)
			lua.pop(L, 1)
			run_stop(r, .Unexpected, fmt.tprintf("%s did not %s within %v", what, "show" if present else "go away", timeout))
			return false
		}
		lua.pop(L, 1)
		run_settle(r, gen, time.tick_diff(time.tick_now(), deadline))
	}
	return false
}

// run_push_screen pushes the session's screen; gen is its generation.
run_push_screen :: proc(r: ^Runner) -> (gen: u64, ok: bool) {
	payload := run_snapshot(r) or_return
	rd := ipc.wire_reader(payload)
	_ = ipc.wr_u32(&rd)
	gen = ipc.wr_u64(&rd)
	if !lua_push_screen(r.vm.L, payload) {
		lua.pop(r.vm.L, 1)
		run_stop(r, .Contract, "malformed snapshot from the core")
		return 0, false
	}
	return gen, true
}

// run_match pushes t.match(screen, target): true when it matched.
run_match :: proc(r: ^Runner, screen, target: c.int) -> (matched, ok: bool) {
	L := r.vm.L
	s, t := lua.absindex(L, screen), lua.absindex(L, target)
	lua.getfield(L, lua.REGISTRYINDEX, RUN_TERM_KEY)
	lua.getfield(L, -1, "match")
	lua.rotate(L, -2, 1)
	lua.pop(L, 1)
	lua.pushvalue(L, s)
	lua.pushvalue(L, t)
	if err, called := vm_call(r.vm, 2, 1); !called {
		run_stop(r, .Contract, err)
		return false, false
	}
	return lua.type(L, -1) != .Nil, true
}

// _interrupt runs the steps of the first known interruption on the screen
// (on top of the stack) that has not run yet in this wait.
@(private = "file")
_interrupt :: proc(r: ^Runner, handled: ^[8]bool) -> bool {
	L := r.vm.L
	screen := lua.absindex(L, -1)
	top := lua.gettop(L)
	defer lua.settop(L, top)
	n := 0
	for source in ([2]cstring{"on", "adapter"}) {
		lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
		if lua.getfield(L, -1, source) != .Table || lua.getfield(L, -1, "interrupts" if source == "adapter" else "interrupt") != .Table do continue
		list := lua.absindex(L, -1)
		for i in 1 ..= lua.rawlen(L, list) {
			if n >= len(handled) do return false
			if lua.rawgeti(L, list, lua.Integer(i)) != .Table { // {target, steps}
				run_stop(r, .Contract, "interrupts are { {target, steps}, … }")
				return false
			}
			lua.rawgeti(L, -1, 1)
			matched, ok := run_match(r, screen, -1)
			if !ok do return false
			if matched && !handled[n] {
				handled[n] = true
				run_trace(r, "interrupt", fmt.tprintf(`"n":%d`, n))
				lua.rawgeti(L, -3, 2)
				run_exec(r, -1)
				return r.stop == .Ok
			}
			n += 1
			lua.pop(L, 3)
		}
	}
	return false
}

// run_describe: how a target reads in a failure message.
run_describe :: proc(r: ^Runner, target: c.int) -> string {
	L := r.vm.L
	switch lua.type(L, target) {
	case .String:   return fmt.tprintf("%q", lua.tostring(L, target))
	case .Function: return "the predicate"
	case .Table:    return fmt.tprintf("the element %s", lua_render(L, target))
	case .None, .Nil, .Boolean, .Light_Userdata, .Number, .Userdata, .Thread:
	}
	return "the target"
}

// _evidence keeps the screen on top of the stack as text and elements.
@(private = "file")
_evidence :: proc(r: ^Runner) {
	L := r.vm.L
	s := screen_ref_of(L, -1)
	if s == nil do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "  screen:\n")
	for row in 0 ..< s.rows {
		line := strings.trim_right(screen_text(s, row, 0, s.cols), " ")
		if len(line) > 0 do fmt.sbprintf(&b, "  %3d│%s\n", row + 1, line)
	}
	es := screen_elements_of(L, -1)
	if len(es) > 0 do strings.write_string(&b, "  elements:\n")
	for _, i in es do fmt.sbprintf(&b, "    %s\n", element_describe(es, i))
	delete(r.evidence)
	r.evidence = strings.clone(strings.to_string(b))
}

// run_check_exited stops the run when the program ended and a step still
// waits for its screen.
run_check_exited :: proc(r: ^Runner) -> bool {
	if !r.exited do return false
	run_stop(r, .Exited, fmt.tprintf("the program exited (%d) before the screen came", r.exit_code))
	return true
}

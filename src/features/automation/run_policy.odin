package feature_automation

// The contract's `on` handlers with their defaults: what a person's input
// does (Esc/^C cancels, anything else is held), the steps that always end a
// run that still holds the session, what happens to held input.

import "core:c"
import "core:fmt"
import lua "../../platform/lua"
import ipc "../../platform/ipc"

// _push_on pushes contract.on[key] and returns its type (the caller pops 1).
@(private = "file")
_push_on :: proc(r: ^Runner, key: cstring) -> lua.Type {
	L := r.vm.L
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	if lua.getfield(L, -1, "on") != .Table {
		lua.pop(L, 2)
		lua.pushnil(L)
		return .Nil
	}
	tp := lua.getfield(L, -1, key)
	lua.rotate(L, -3, 1)
	lua.pop(L, 2)
	return tp
}

// run_human_says_cancel: on.human(input) → "cancel" | "hold"; without it an
// interrupt (Esc, ^C) cancels.
run_human_says_cancel :: proc(r: ^Runner, ev: ipc.Lease_Event) -> bool {
	L := r.vm.L
	if _push_on(r, "human") != .Function {
		lua.pop(L, 1)
		return ev.interrupt
	}
	lua.createtable(L, 0, 2)
	lua.pushstring(L, ev.bytes)
	lua.setfield(L, -2, "bytes")
	lua.pushboolean(L, c.int(ev.interrupt))
	lua.setfield(L, -2, "interrupt")
	err, ok := vm_call(r.vm, 1, 1)
	if !ok {
		run_stop(r, .Contract, fmt.tprintf("on.human: %s", err))
		return false
	}
	verdict := lua.tostring(L, -1)
	lua.pop(L, 1)
	switch verdict {
	case "cancel": return true
	case "hold":   return false
	}
	run_stop(r, .Contract, fmt.tprintf("on.human must return \"hold\" or \"cancel\", not %q", verdict))
	return false
}

// run_finally carries out on.finally while the session is still held, even
// after a failure; its own failure is added to the first one.
run_finally :: proc(r: ^Runner) {
	L := r.vm.L
	tp := _push_on(r, "finally")
	defer lua.pop(L, 1)
	if tp == .Nil || !r.leased do return
	stop, msg := r.stop, r.stop_msg
	r.stop, r.stop_msg, r.done = .Ok, "", false
	run_trace(r, "finally", "")
	if tp == .Function {
		if err, ok := vm_call_keep(r, 0); !ok {
			run_stop(r, .Contract, fmt.tprintf("on.finally: %s", err))
		} else {
			run_exec(r, -1)
			lua.pop(L, 1)
		}
	} else {
		run_exec(r, -1)
	}
	if stop != .Ok {
		if r.stop != .Ok do msg = fmt.aprintf("%s (and on.finally: %s)", msg, r.stop_msg)
		delete(r.stop_msg)
		r.stop, r.stop_msg = stop, msg
	}
}

// vm_call_keep calls the function at the top (copying it first so the
// original stays) with nargs arguments pushed after the copy: none here.
vm_call_keep :: proc(r: ^Runner, nargs: c.int) -> (err: string, ok: bool) {
	lua.pushvalue(r.vm.L, -1 - nargs)
	return vm_call(r.vm, nargs, 1)
}

// run_release_flush: on.release == "flush" delivers held input at the end.
run_release_flush :: proc(r: ^Runner) -> bool {
	L := r.vm.L
	_push_on(r, "release")
	defer lua.pop(L, 1)
	return lua.tostring(L, -1) == "flush"
}

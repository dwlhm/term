package feature_automation

// The interpreter: steps are Lua tables built by the term module; Odin
// carries them out. Every call back into Lua (a continuation, a predicate, a
// matcher) is a pure call under the VM's budget.

import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import lua "../../platform/lua"
import ipc "../../platform/ipc"

// run_exec carries out the steps at idx (a step or nested lists of them).
run_exec :: proc(r: ^Runner, idx: c.int) {
	L := r.vm.L
	at := lua.absindex(L, idx)
	_push_term_fn(r, "flatten")
	lua.pushvalue(L, at)
	if err, ok := vm_call(r.vm, 1, 1); !ok {
		run_stop(r, .Contract, err)
		return
	}
	defer lua.pop(L, 1)
	n := lua.rawlen(L, -1)
	for i in 1 ..= n {
		if r.stop != .Ok || r.done do return
		if time.tick_diff(time.tick_now(), r.deadline) <= 0 {
			run_stop(r, .Timeout, "the run went over its time limit (timeouts.run)")
			return
		}
		lua.rawgeti(L, -1, lua.Integer(i))
		_exec_step(r)
		lua.pop(L, 1)
	}
}

// _exec_step carries out the step on top of the stack (left there).
@(private = "file")
_exec_step :: proc(r: ^Runner) {
	L := r.vm.L
	r.step += 1
	op := _str_field(L, "op")
	run_trace(r, "step", fmt.tprintf(`"n":%d,"op":%q`, r.step, op))
	switch op {
	case "press":            _step_press(r)
	case "type", "paste":    _step_text(r, op == "paste")
	case "click", "scroll":  _step_pointer(r, op == "scroll")
	case "expect", "gone":
		lua.getfield(L, -1, "target")
		shown := run_wait_for(r, -1, op == "expect", _timeout_field(r, -2))
		lua.pop(L, 2 if shown && op == "expect" else 1) // its match, the target
	case "read":    _step_read(r)
	case "choose":  run_choose(r)
	case "retry":   run_retry(r)
	case "call":    _step_call(r)
	case "ask":     _step_ask(r)
	case "handoff": run_handoff(r)
	case "done":
		lua.getfield(L, -1, "value")
		r.done, r.result = true, strings.clone(lua_render(L, -1))
		lua.pop(L, 1)
	case "fail":
		run_stop(r, .Failed, _str_field(L, "msg"))
	case:
		run_stop(r, .Contract, fmt.tprintf("unknown step %q (steps are made with t.press, t.expect, …)", op))
	}
}

@(private = "file")
_step_press :: proc(r: ^Runner) {
	L := r.vm.L
	lua.getfield(L, -1, "keys")
	defer lua.pop(L, 1)
	keys: [ipc.ACT_KEYS_MAX]ipc.Act_Key
	n := min(int(lua.rawlen(L, -1)), ipc.ACT_KEYS_MAX)
	for i in 0 ..< n {
		lua.rawgeti(L, -1, lua.Integer(i + 1))
		name := strings.clone(lua.tostring(L, -1), context.temp_allocator)
		lua.pop(L, 1)
		k, ok := parse_key(name)
		if !ok {
			run_stop(r, .Contract, fmt.tprintf("unknown key %q (names like Enter, Escape, Ctrl+C, ArrowUp, F5, a)", name))
			return
		}
		keys[i] = k
	}
	b: [ipc.ACT_KEYS_MAX * 6 + 16]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_act_keys(&w, r.sid, keys[:n])
	_act_and_settle(r, ipc.wire_bytes_written(&w))
}

@(private = "file")
_step_text :: proc(r: ^Runner, paste: bool) {
	text := strings.clone(_str_field(r.vm.L, "text"), context.temp_allocator)
	for len(text) > 0 {
		n := min(len(text), ipc.ACT_TEXT_MAX)
		buf := make([]u8, n + 16, context.temp_allocator)
		w := ipc.wire_writer(buf)
		ipc.enc_act_text(&w, r.sid, text[:n], paste)
		if !_act_and_settle(r, ipc.wire_bytes_written(&w)) do return
		text = text[n:]
	}
}

// _step_pointer clicks or scrolls at the middle of the target, once it shows.
@(private = "file")
_step_pointer :: proc(r: ^Runner, scroll: bool) {
	L := r.vm.L
	lua.getfield(L, -1, "target")
	defer lua.pop(L, 1)
	if !run_wait_for(r, -1, true, r.expect) do return
	defer lua.pop(L, 1) // the match
	if lua.type(L, -1) != .Table {
		run_stop(r, .Contract, "click and scroll need an element or a text, not a predicate")
		return
	}
	row := _int_field(L, "row") + _int_field(L, "height") / 2
	col := _int_field(L, "col") + max(_int_field(L, "width") - 1, 0) / 2
	m := ipc.Act_Mouse{col = u16(max(col, 1)), row = u16(max(row, 1))}
	if scroll {
		n := _int_field(L, "n", -3)
		m.kind = 4 if n >= 0 else 3
		for _ in 0 ..< max(abs(n), 1) do if !_mouse(r, m) do return
		return
	}
	switch _str_field(L, "button", -3) {
	case "right":  m.button = 2
	case "middle": m.button = 1
	}
	if _mouse(r, m) {
		m.kind = 1
		_mouse(r, m)
	}
}

@(private = "file")
_mouse :: proc(r: ^Runner, m: ipc.Act_Mouse) -> bool {
	b: [32]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_act_mouse(&w, r.sid, m)
	return _act_and_settle(r, ipc.wire_bytes_written(&w))
}

// _act_and_settle sends input, then waits for the screen to answer it (a
// screen that never goes quiet is not an error).
@(private = "file")
_act_and_settle :: proc(r: ^Runner, body: []u8) -> bool {
	gen := run_act(r, body) or_return
	run_settle(r, gen, r.expect)
	return r.stop == .Ok
}

// _step_read waits for the target and continues with k(value): an element's
// text (or name), or what a predicate returned.
@(private = "file")
_step_read :: proc(r: ^Runner) {
	L := r.vm.L
	lua.getfield(L, -1, "target")
	ok := run_wait_for(r, -1, true, r.expect)
	if !ok {
		lua.pop(L, 1)
		return
	}
	if lua.type(L, -1) == .Table {
		value := _str_field(L, "text")
		if len(value) == 0 do value = _str_field(L, "name")
		value = strings.clone(value, context.temp_allocator)
		lua.pop(L, 1)
		lua.pushstring(L, value)
	}
	lua.getfield(L, -3, "k") // step, target, value, k
	lua.insert(L, -2)
	run_continue(r, 1)
	lua.pop(L, 1)
}

// run_continue calls the continuation below nargs args and runs its steps.
run_continue :: proc(r: ^Runner, nargs: c.int) {
	if err, ok := vm_call(r.vm, nargs, 1); !ok {
		run_stop(r, .Contract, err)
		return
	}
	run_exec(r, -1)
	lua.pop(r.vm.L, 1)
}

@(private = "file")
_step_call :: proc(r: ^Runner) {
	L := r.vm.L
	name := strings.clone(_str_field(L, "name"), context.temp_allocator)
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	tp := lua.getfield(L, -1, strings.clone_to_cstring(name, context.temp_allocator))
	lua.rotate(L, -2, 1)
	lua.pop(L, 1)
	if tp != .Function || name == "serve" {
		lua.pop(L, 1)
		run_stop(r, .Contract, fmt.tprintf("t.call: the contract has no function %q", name))
		return
	}
	lua.getfield(L, -2, "args")
	args := lua.absindex(L, -1)
	n := _int_field(L, "n")
	for i in 1 ..= n do lua.rawgeti(L, args, lua.Integer(i))
	lua.rotate(L, args, -1) // the args table goes to the top, then away
	lua.pop(L, 1)
	run_continue(r, c.int(n))
}

@(private = "file")
_push_term_fn :: proc(r: ^Runner, name: cstring) {
	L := r.vm.L
	lua.getfield(L, lua.REGISTRYINDEX, RUN_TERM_KEY)
	lua.getfield(L, -1, name)
	lua.rotate(L, -2, 1)
	lua.pop(L, 1)
}

// _str_field: t[key] of the table at idx as a string ("" when absent); a view
// valid while that table is on the stack.
_str_field :: proc(L: ^lua.State, key: cstring, idx: c.int = -1) -> string {
	lua.getfield(L, idx, key)
	defer lua.pop(L, 1)
	if lua.type(L, -1) != .String && lua.type(L, -1) != .Number do return ""
	return strings.clone(lua.tostring(L, -1), context.temp_allocator)
}

_int_field :: proc(L: ^lua.State, key: cstring, idx: c.int = -1) -> int {
	lua.getfield(L, idx, key)
	defer lua.pop(L, 1)
	return int(lua.tointegerx(L, -1, nil))
}

// _timeout_field: the step at idx's timeout (seconds), else the contract's.
@(private = "file")
_timeout_field :: proc(r: ^Runner, idx: c.int) -> time.Duration {
	L := r.vm.L
	lua.getfield(L, idx, "timeout")
	defer lua.pop(L, 1)
	if lua.type(L, -1) != .Number do return r.expect
	return time.Duration(lua.tonumberx(L, -1, nil) * f64(time.Second))
}


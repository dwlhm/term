package feature_automation

// Steps that branch, repeat or hand over: choose, retry, ask, handoff.

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import lua "../../platform/lua"
import proto "../session_proto"
import ipc "../../platform/ipc"

// run_choose runs the first case whose target is on the screen; when none is
// and a default exists, the default; otherwise it waits for a case to show.
run_choose :: proc(r: ^Runner) {
	L := r.vm.L
	step := lua.absindex(L, -1)
	lua.getfield(L, step, "cases")
	cases := lua.absindex(L, -1)
	defer lua.settop(L, cases - 1)
	deadline := time.tick_add(time.tick_now(), r.expect)
	for run_running(r) {
		gen, ok := run_push_screen(r)
		if !ok do return
		screen := lua.absindex(L, -1)
		for i in 1 ..= lua.rawlen(L, cases) {
			lua.rawgeti(L, cases, lua.Integer(i))
			lua.rawgeti(L, -1, 1)
			matched, called := run_match(r, screen, -1)
			if !called do return
			if matched {
				lua.rawgeti(L, -3, 2)
				run_exec(r, -1)
				return
			}
			lua.pop(L, 3)
		}
		if run_check_exited(r) do return
		if lua.getfield(L, step, "default") != .Nil {
			run_exec(r, -1)
			return
		}
		lua.pop(L, 1)
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			lua.settop(L, screen)
			run_stop(r, .Unexpected, fmt.tprintf("none of the %d choices showed within %v", lua.rawlen(L, cases), r.expect))
			return
		}
		lua.settop(L, screen - 1)
		run_settle(r, gen, time.tick_diff(time.tick_now(), deadline))
	}
}

// run_retry runs steps up to `times` times, until they pass (and `until`
// shows, when given). Only an unexpected screen is retried.
run_retry :: proc(r: ^Runner) {
	L := r.vm.L
	step := lua.absindex(L, -1)
	times := max(_int_field(L, "times"), 1)
	for attempt in 1 ..= times {
		lua.getfield(L, step, "steps")
		run_exec(r, -1)
		lua.pop(L, 1)
		if r.stop == .Ok && lua.getfield(L, step, "until") != .Nil {
			if run_wait_for(r, -1, true, r.expect) do lua.pop(L, 1)
			lua.pop(L, 1)
		} else if r.stop == .Ok {
			lua.pop(L, 1)
		}
		if r.stop != .Unexpected || attempt == times do return
		run_trace(r, "retry", fmt.tprintf(`"attempt":%d,"after":%q`, attempt, r.stop_msg))
		delete(r.stop_msg)
		r.stop, r.stop_msg = .Ok, ""
	}
}

// _step_ask asks, then continues with k(answer) typed as spec.type.
_step_ask :: proc(r: ^Runner) {
	L := r.vm.L
	lua.getfield(L, -1, "spec")
	prompt := _str_field(L, "prompt")
	kind := _str_field(L, "type")
	if len(kind) == 0 do kind = "string"
	choices: [dynamic]string
	choices.allocator = context.temp_allocator
	if lua.getfield(L, -1, "choices") == .Table {
		for i in 1 ..= lua.rawlen(L, -1) {
			lua.rawgeti(L, -1, lua.Integer(i))
			append(&choices, strings.clone(lua.tostring(L, -1), context.temp_allocator))
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 2)
	answer, ok := run_ask(r, prompt, kind, choices[:])
	if !ok do return
	lua.getfield(L, -1, "k")
	switch kind {
	case "number":
		n, _ := strconv.parse_f64(answer)
		lua.pushnumber(L, n)
	case "boolean": lua.pushboolean(L, c.int(answer == "true" || answer == "yes" || answer == "1"))
	case:           lua.pushstring(L, answer)
	}
	run_continue(r, 1)
}

// run_handoff lets a person type in the program (the lease passes input
// through) until `until` shows or they reply that they are done.
run_handoff :: proc(r: ^Runner) {
	L := r.vm.L
	reason := _str_field(L, "reason")
	if !run_lease_pass(r, true) do return
	defer run_lease_pass(r, false)
	if !run_ensure_endpoint(r) do return
	fmt.printfln(`{{"handoff":%q,"reply":"term auto reply %d done"}}`, reason, r.endpoint)
	run_trace(r, "handoff", "")
	has_until := lua.getfield(L, -1, "until") != .Nil
	defer lua.pop(L, 1)
	run_listen(r)
	r.asking, r.replied = true, false
	defer r.asking = false
	for run_running(r) && !r.replied {
		if time.tick_diff(time.tick_now(), r.deadline) <= 0 {
			run_stop(r, .Timeout, "the handoff did not end before the run's time limit")
			return
		}
		if run_check_exited(r) do return
		gen, ok := run_push_screen(r)
		if !ok do return
		if has_until {
			matched, called := run_match(r, -1, -2)
			if !called do return
			lua.pop(L, 2)
			if matched do return
		} else {
			lua.pop(L, 1)
		}
		run_settle(r, gen, time.Second) // a reply is seen within a second
	}
	if r.replied do run_answer_reply(r, false, "ok")
}

// run_lease_pass switches the lease between holding and passing through a
// person's input.
run_lease_pass :: proc(r: ^Runner, pass: bool) -> bool {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, r.sid); ipc.ww_bool(&w, pass)
	f, ok := run_request(r, proto.MSG_LEASE_MODE, ipc.wire_bytes_written(&w), proto.MSG_OK, 5 * time.Second)
	return ok && f.kind == proto.MSG_OK
}

// lua_render: a Lua value as text — strings as they are, tables as JSON.
lua_render :: proc(L: ^lua.State, idx: c.int, depth := 0) -> string {
	at := lua.absindex(L, idx)
	switch lua.type(L, at) {
	case .Nil, .None: return ""
	case .Boolean:    return "true" if lua.toboolean(L, at) != 0 else "false"
	case .String, .Number: return strings.clone(lua.tostring(L, at), context.temp_allocator)
	case .Table:      if depth < 8 do return _render_table(L, at, depth)
	case .Function, .Userdata, .Thread, .Light_Userdata:
	}
	return strings.clone(string(lua.typename(L, lua.type(L, at))), context.temp_allocator)
}

@(private = "file")
_render_table :: proc(L: ^lua.State, t: c.int, depth: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := lua.rawlen(L, t)
	if n > 0 {
		strings.write_byte(&b, '[')
		for i in 1 ..= n {
			lua.rawgeti(L, t, lua.Integer(i))
			fmt.sbprintf(&b, "%s%s", "," if i > 1 else "", _json_value(L, -1, depth))
			lua.pop(L, 1)
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	}
	strings.write_byte(&b, '{')
	first := true
	lua.pushnil(L)
	for lua.next(L, t) != 0 {
		if lua.type(L, -2) == .String {
			fmt.sbprintf(&b, "%s%q:%s", "" if first else ",", lua.tostring(L, -2), _json_value(L, -1, depth))
			first = false
		}
		lua.pop(L, 1)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
_json_value :: proc(L: ^lua.State, idx: c.int, depth: int) -> string {
	#partial switch lua.type(L, idx) {
	case .String: return fmt.tprintf("%q", lua.tostring(L, idx))
	case .Number, .Boolean, .Table: return lua_render(L, idx, depth + 1)
	}
	return "null"
}

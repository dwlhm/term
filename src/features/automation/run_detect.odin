package feature_automation

// Which session a run drives: --session, checked with the adapter's detect,
// or the one live session the adapter detects.

import "core:fmt"
import "core:strings"
import lua "../../platform/lua"
import proto "../session_proto"
import ipc "../../platform/ipc"

// run_pick_session sets r.sid, or stops the run saying why it cannot.
run_pick_session :: proc(r: ^Runner) -> bool {
	L := r.vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	lua.getfield(L, lua.REGISTRYINDEX, RUN_CONTRACT_KEY)
	has_adapter := lua.getfield(L, -1, "adapter") == .Table
	name := _str_field(L, "name") if has_adapter else ""
	if r.sid != 0 {
		if !has_adapter do return true
		is, ok := _detects(r, r.sid)
		if ok && !is do run_stop(r, .Failed, fmt.tprintf("session %d does not look like %s (its adapter's detect said no)", r.sid, name))
		return ok && is
	}
	if !has_adapter {
		run_stop(r, .Contract, "which session? pass --session <id> (term session ls), or give the contract an adapter to find it")
		return false
	}
	found: [dynamic]u32
	found.allocator = context.temp_allocator
	for id in _live_sessions(r) {
		is, ok := _detects(r, id)
		if !ok do return false
		if is do append(&found, id)
	}
	switch len(found) {
	case 1:
		r.sid = found[0]
		return true
	case 0:
		run_stop(r, .Failed, fmt.tprintf("no session looks like %s: start it, or pass --session", name))
	case:
		ids := make([]string, len(found), context.temp_allocator)
		for id, i in found do ids[i] = fmt.tprint(id)
		run_stop(r, .Failed, fmt.tprintf("sessions %s all look like %s: pass --session", strings.join(ids, ", ", context.temp_allocator), name))
	}
	return false
}

// _detects calls adapter.detect(screen of id); the adapter is on top.
@(private = "file")
_detects :: proc(r: ^Runner, id: u32) -> (is, ok: bool) {
	L := r.vm.L
	keep := r.sid
	r.sid = id
	defer r.sid = keep
	lua.getfield(L, -1, "detect")
	if _, pushed := run_push_screen(r); !pushed {
		lua.pop(L, 1)
		return false, false
	}
	if err, called := vm_call(r.vm, 1, 1); !called {
		run_stop(r, .Contract, fmt.tprintf("adapter detect: %s", err))
		return false, false
	}
	defer lua.pop(L, 1)
	return lua.toboolean(L, -1) != 0, true
}

// _live_sessions: the ids of sessions that run a program.
@(private = "file")
_live_sessions :: proc(r: ^Runner) -> []u32 {
	a, err := run_call(r, proto.MSG_LIST, nil, ipc.CALL_DEFAULT)
	if err.kind != .None do return nil
	rd := ipc.wire_reader(a.body)
	n := int(ipc.wr_u32(&rd))
	ids := make([dynamic]u32, 0, n, context.temp_allocator)
	for _ in 0 ..< n {
		row := proto.dec_row(&rd)
		if !rd.ok do break
		if row.state != .Exited && !row.endpoint do append(&ids, row.id)
	}
	return ids[:]
}

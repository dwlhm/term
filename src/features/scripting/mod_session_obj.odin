package feature_scripting

// Methods on `Session` userdata instances (send, read, wait, signal, cancel, kill).

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"
import api "../session_api"
import proto "../session_proto"
import lua "../../platform/lua"

push_session_userdata :: proc(L: ^lua.State, id: u32) {
	ptr := (^u32)(lua.newuserdatauv(L, size_of(u32), 0))
	ptr^ = id
	lua.getfield(L, lua.REGISTRYINDEX, SESSION_MT)
	lua.setmetatable(L, -2)
}

_session_from_userdata :: proc(L: ^lua.State, idx: c.int) -> (u32, bool) {
	ptr := (^u32)(lua.touserdata(L, idx))
	if ptr == nil do return 0, false
	return ptr^, true
}

_init_session_metatable :: proc(L: ^lua.State) {
	lua.createtable(L, 0, 8) // mt
	lua.createtable(L, 0, 7) // methods

	methods := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"send", _session_obj_send},
		{"read", _session_obj_read},
		{"wait", _session_obj_wait},
		{"signal", _session_obj_signal},
		{"cancel", _session_obj_cancel},
		{"kill", _session_obj_kill},
		{"id", _session_obj_id},
	}

	for m in methods {
		lua.pushcfunction(L, m.fn)
		lua.setfield(L, -2, m.name)
	}

	lua.setfield(L, -2, "__index")
	lua.pushvalue(L, -1)
	lua.setfield(L, lua.REGISTRYINDEX, SESSION_MT)
	lua.pop(L, 1)
}

@(private = "file")
_session_obj_id :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0
	lua.pushinteger(L, lua.Integer(id))
	return 1
}

@(private = "file")
_session_obj_send :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	items: [dynamic]proto.Act_Batch_Item
	defer delete(items)

	top := lua.gettop(L)
	for i in 2 ..= top {
		if lua.type(L, c.int(i)) == .String {
			text := lua.tostring(L, c.int(i))
			append(&items, proto.Act_Batch_Item{kind = .Text, text = text})
		} else if lua.type(L, c.int(i)) == .Table {
			lua.getfield(L, c.int(i), "key")
			if lua.type(L, -1) == .String {
				key_str := lua.tostring(L, -1)
				if k, k_ok := proto.parse_key(key_str); k_ok {
					append(&items, proto.Act_Batch_Item{
						kind = .Keys, n_keys = 1, keys = {0 = k},
					})
				}
			}
			lua.pop(L, 1)
		}
	}

	if len(items) == 0 do return 0
	gen, err := api.api_act_batch(vm.sched.ipc_client, id, items[:])
	if err.kind != .None {
		lua.pushnil(L)
		lua.pushstring(L, proto.error_text(err))
		return 2
	}
	lua.pushinteger(L, lua.Integer(gen))
	return 1
}

@(private = "file")
_session_obj_read :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	lines: u32 = 0
	last := false
	if lua.type(L, 2) == .Table {
		lua.getfield(L, 2, "n")
		if lua.type(L, -1) == .Number do lines = u32(lua.tointegerx(L, -1, nil))
		lua.pop(L, 1)

		lua.getfield(L, 2, "last")
		if lua.type(L, -1) == .Boolean do last = lua.toboolean(L, -1) != 0
		lua.pop(L, 1)
	}

	text, err := api.api_read(vm.sched.ipc_client, id, lines, last, context.temp_allocator)
	if err.kind != .None {
		lua.pushnil(L)
		lua.pushstring(L, proto.error_text(err))
		return 2
	}
	lua.pushstring(L, text)
	return 1
}

@(private = "file")
_session_obj_wait :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	pattern := ""
	wait_prompt := false
	wait_exit := false
	timeout_sec := 10.0
	if lua.type(L, 2) == .Table {
		lua.getfield(L, 2, "text")
		if lua.type(L, -1) == .String do pattern = lua.tostring(L, -1)
		lua.pop(L, 1)

		lua.getfield(L, 2, "prompt")
		if lua.type(L, -1) == .Boolean do wait_prompt = lua.toboolean(L, -1) != 0
		lua.pop(L, 1)

		lua.getfield(L, 2, "exit")
		if lua.type(L, -1) == .Boolean do wait_exit = lua.toboolean(L, -1) != 0
		lua.pop(L, 1)

		lua.getfield(L, 2, "timeout")
		if lua.type(L, -1) == .Number do timeout_sec = lua.tonumberx(L, -1, nil)
		lua.pop(L, 1)
	}

	baseline_snap, base_err := api.api_snapshot(vm.sched.ipc_client, id, 0, -1, context.temp_allocator)
	baseline_seq := baseline_snap.cmd_seq if base_err.kind == .None else 0

	deadline := time.time_add(time.now(), time.Duration(timeout_sec * f64(time.Second)))
	for time.diff(deadline, time.now()) < 0 {
		snap, err := api.api_snapshot(vm.sched.ipc_client, id, 0, -1, context.temp_allocator)
		if err.kind != .None do break

		if wait_exit && snap.exited {
			lua.pushboolean(L, 1)
			lua.pushinteger(L, lua.Integer(snap.exit_code))
			return 2
		}

		if wait_prompt && (snap.cmd_seq > baseline_seq || snap.prompt_state == .Prompt) {
			lua.pushboolean(L, 1)
			lua.pushinteger(L, lua.Integer(snap.cmd_exit_code if snap.has_cmd_exit else 0))
			return 2
		}

		if len(pattern) > 0 {
			found := false
			for row in snap.screen {
				for run in row.runs {
					if strings.contains(run.text, pattern) {
						found = true
						break
					}
				}
				if found do break
			}
			if found {
				lua.pushboolean(L, 1)
				return 1
			}
		}

		time.sleep(20 * time.Millisecond)
	}

	lua.pushboolean(L, 0)
	lua.pushstring(L, "timeout waiting for condition")
	return 2
}

@(private = "file")
_session_obj_signal :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	sig := i32(2) // default SIGINT
	if lua.type(L, 2) == .Number {
		sig = i32(lua.tointegerx(L, 2, nil))
	}
	err := api.api_signal(vm.sched.ipc_client, id, sig)
	lua.pushboolean(L, 1 if err.kind == .None else 0)
	return 1
}

@(private = "file")
_session_obj_cancel :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	err := api.api_signal(vm.sched.ipc_client, id, 2)
	lua.pushboolean(L, 1 if err.kind == .None else 0)
	return 1
}

@(private = "file")
_session_obj_kill :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	id, ok := _session_from_userdata(L, 1)
	if !ok do return 0

	err := api.api_kill(vm.sched.ipc_client, id)
	lua.pushboolean(L, 1 if err.kind == .None else 0)
	return 1
}

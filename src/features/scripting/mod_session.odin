package feature_scripting

// `term.session` Lua module: lifecycle, lookup, and session enumeration.

import "base:runtime"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import api "../session_api"
import proto "../session_proto"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

SESSION_MT :: "term.Session"

Session_Kill_Ctx :: struct {
	client: ^ipc.Client,
	id:     u32,
}

_finalizer_kill_session :: proc(data: rawptr) {
	ctx := (^Session_Kill_Ctx)(data)
	if ctx != nil && ctx.client != nil && ctx.id != 0 {
		_ = api.api_kill(ctx.client, ctx.id)
		free(ctx)
	}
}

open_mod_session :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.newtable(L)

	methods := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"new", _session_new},
		{"get", _session_get},
		{"ls", _session_ls},
		{"whoami", _session_whoami},
	}

	for m in methods {
		lua.pushcfunction(L, m.fn)
		lua.setfield(L, -2, m.name)
	}

	_init_session_metatable(L)
	return 1
}

@(private = "file")
_session_new :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil {
		lua.pushstring(L, "session.new: IPC client not connected")
		return lua.error(L)
	}

	spec: proto.Spawn_Msg
	spec.size = {cols = 120, rows = 36}
	spec.cwd = os.get_env("PWD", context.temp_allocator)

	owned := false
	if lua.type(L, 1) == .Table {
		owned = _parse_spawn_table(L, 1, &spec)
	}

	id, err := api.api_new(vm.sched.ipc_client, &spec)
	if err.kind != .None {
		lua.pushnil(L)
		lua.pushstring(L, proto.error_text(err))
		return 2
	}

	// If owned, register finalizer on the current fiber's Scope
	if owned && vm.sched.current != nil {
		kctx := new(Session_Kill_Ctx)
		kctx.client = vm.sched.ipc_client
		kctx.id = id
		scope_add_finalizer(&vm.sched.current.scope, _finalizer_kill_session, kctx)
	}

	push_session_userdata(L, id)
	return 1
}

@(private = "file")
_session_get :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	if lua.type(L, 1) == .Number {
		id := u32(lua.tointegerx(L, 1, nil))
		push_session_userdata(L, id)
		return 1
	}

	if lua.type(L, 1) == .String {
		name := lua.tostring(L, 1)
		rows, err := api.api_ls(vm.sched.ipc_client, context.temp_allocator)
		if err.kind != .None do return 0
		for r in rows {
			if r.process == name || r.title == name {
				push_session_userdata(L, r.id)
				return 1
			}
		}
	}
	lua.pushnil(L)
	return 1
}

@(private = "file")
_session_ls :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vm := script_vm_of(L)
	if vm == nil || vm.sched.ipc_client == nil do return 0

	rows, err := api.api_ls(vm.sched.ipc_client, context.temp_allocator)
	if err.kind != .None {
		lua.newtable(L)
		return 1
	}

	lua.createtable(L, c.int(len(rows)), 0)
	for r, i in rows {
		lua.createtable(L, 0, 11)
		lua.pushinteger(L, lua.Integer(r.id))
		lua.setfield(L, -2, "id")
		lua.pushinteger(L, lua.Integer(r.pid))
		lua.setfield(L, -2, "pid")
		lua.pushstring(L, r.name)
		lua.setfield(L, -2, "name")
		lua.pushstring(L, r.process)
		lua.setfield(L, -2, "process")
		lua.pushstring(L, r.cwd)
		lua.setfield(L, -2, "cwd")
		lua.pushstring(L, r.title)
		lua.setfield(L, -2, "title")
		lua.pushstring(L, r.status)
		lua.setfield(L, -2, "status")
		lua.pushinteger(L, lua.Integer(r.cmd_seq))
		lua.setfield(L, -2, "cmd_seq")
		lua.pushboolean(L, 1 if r.attached else 0)
		lua.setfield(L, -2, "attached")

		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

@(private = "file")
_session_whoami :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	env_val := os.get_env(proto.SESSION_ID_ENV, context.temp_allocator)
	if id, ok := strconv.parse_uint(env_val, 10); ok && id > 0 {
		lua.pushinteger(L, lua.Integer(id))
		return 1
	}
	lua.pushnil(L)
	return 1
}

@(private = "file")
_parse_spawn_table :: proc(L: ^lua.State, idx: c.int, spec: ^proto.Spawn_Msg) -> bool {
	lua.getfield(L, idx, "dir")
	if lua.type(L, -1) == .String {
		spec.cwd = strings.clone(lua.tostring(L, -1), context.temp_allocator)
	}
	lua.pop(L, 1)

	lua.getfield(L, idx, "name")
	if lua.type(L, -1) == .String {
		spec.name = strings.clone(lua.tostring(L, -1), context.temp_allocator)
	}
	lua.pop(L, 1)

	owned := false
	lua.getfield(L, idx, "owned")
	if lua.type(L, -1) == .Boolean {
		owned = lua.toboolean(L, -1) != 0
	}
	lua.pop(L, 1)

	lua.getfield(L, idx, "cmd")
	if lua.type(L, -1) == .Table {
		n := int(lua.rawlen(L, -1))
		spec.argc = min(n, proto.STREAM_MAX_ARGV)
		for i in 0 ..< spec.argc {
			lua.rawgeti(L, -1, lua.Integer(i + 1))
			spec.argv[i] = strings.clone(lua.tostring(L, -1), context.temp_allocator)
			lua.pop(L, 1)
		}
	} else if lua.type(L, -1) == .String {
		spec.argc = 1
		spec.argv[0] = strings.clone(lua.tostring(L, -1), context.temp_allocator)
	} else {
		shell := os.get_env("SHELL", context.temp_allocator)
		spec.argv[0] = shell if len(shell) > 0 else "/bin/sh"
		spec.argc = 1
	}
	lua.pop(L, 1)
	return owned
}

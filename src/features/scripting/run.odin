package feature_scripting

// Top-level script runner for `term run <script.lua> [args...]`.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import api "../session_api"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

@(private = "file")
_load_script_main :: proc(L: ^lua.State, path: string, content: []u8) -> (ok: bool, err_msg: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if lua.luaL_loadbufferx(L, raw_data(content), c.size_t(len(content)), cpath, "t") != lua.OK {
		return false, lua.tostring(L, -1)
	}
	if lua.pcall(L, 0, 1, 0) != lua.OK {
		return false, lua.tostring(L, -1)
	}
	if lua.type(L, -1) != .Table {
		return false, "script must return term.program { ... } or term.script { ... }"
	}
	lua.getfield(L, -1, "main")
	if lua.type(L, -1) != .Function {
		return false, "script manifest missing 'main' function"
	}
	return true, ""
}

@(private = "file")
_spawn_script_root :: proc(vm: ^Script_Vm, args: []string) -> ^Fiber {
	root_co := lua.newthread(vm.L)
	lua.insert(vm.L, -2)
	lua.xmove(vm.L, root_co, 1)
	lua.pop(vm.L, 2)

	lua.newtable(root_co)
	for arg, i in args {
		lua.pushstring(root_co, arg)
		lua.rawseti(root_co, -2, lua.Integer(i + 1))
	}
	return scheduler_spawn_co(&vm.sched, 0, root_co)
}

run_script :: proc(path: string, args: []string, trust := false) -> int {
	real_path := path
	if strings.has_prefix(real_path, "~/") {
		if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
			real_path = strings.concatenate({home, real_path[1:]}, context.temp_allocator)
		}
	}

	content, read_err := os.read_entire_file(real_path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("term: cannot read script %s", path)
		return 1
	}

	defer {
		if _raw_mode_active {
			posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &_orig_termios)
			_raw_mode_active = false
		}
	}

	ipc_cli: ipc.Client
	if err := api.api_open(&ipc_cli, start = true); err.kind != .None {
		fmt.eprintfln("term: cannot connect to session core")
		return 2
	}
	defer ipc.client_close(&ipc_cli)

	vm := script_vm_create()
	if vm == nil {
		fmt.eprintln("term: failed to initialize scripting runtime")
		return 1
	}
	defer script_vm_destroy(vm)
	vm.sched.ipc_client = &ipc_cli

	if ok, err_msg := _load_script_main(vm.L, path, content); !ok {
		fmt.eprintfln("term: %s", err_msg)
		return 1
	}

	root_fiber := _spawn_script_root(vm, args)
	ok, err_msg := scheduler_run(&vm.sched)
	if !ok {
		if len(err_msg) > 0 do fmt.eprintfln("term: %s", err_msg)
		return 130 if root_fiber.interrupted else 1
	}
	return 0
}

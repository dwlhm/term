package feature_scripting

// Top-level script runner for `term run <script.lua> [args...]`.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import api "../session_api"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

run_script :: proc(path: string, args: []string, trust := false) -> int {
	content, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("term: cannot read script %s", path)
		return 1
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

	// Load script file
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if lua.luaL_loadbufferx(vm.L, raw_data(content), c.size_t(len(content)), cpath, "t") != lua.OK {
		fmt.eprintfln("term: %s", lua.tostring(vm.L, -1))
		return 1
	}

	// Execute top-level to obtain manifest
	if lua.pcall(vm.L, 0, 1, 0) != lua.OK {
		fmt.eprintfln("term: %s", lua.tostring(vm.L, -1))
		return 1
	}

	if lua.type(vm.L, -1) != .Table {
		fmt.eprintln("term: script must return term.program { ... } or term.script { ... }")
		return 1
	}

	// Extract main function
	lua.getfield(vm.L, -1, "main")
	if lua.type(vm.L, -1) != .Function {
		fmt.eprintln("term: script manifest missing 'main' function")
		return 1
	}

	// Create root fiber coroutine
	root_co := lua.newthread(vm.L)
	lua.insert(vm.L, -2) // put thread below function
	lua.xmove(vm.L, root_co, 1) // move main function to root_co
	lua.pop(vm.L, 2) // pop thread and manifest

	// Push argv to root_co as arguments
	lua.newtable(root_co)
	for arg, i in args {
		lua.pushstring(root_co, arg)
		lua.rawseti(root_co, -2, lua.Integer(i + 1))
	}

	root_fiber := scheduler_spawn_co(&vm.sched, 0, root_co)

	// Run scheduler
	ok, err_msg := scheduler_run(&vm.sched)
	if !ok {
		if len(err_msg) > 0 {
			fmt.eprintfln("term: %s", err_msg)
		}
		if root_fiber.interrupted do return 130
		return 1
	}

	return 0
}

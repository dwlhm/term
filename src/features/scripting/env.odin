package feature_scripting

// Sandboxed Lua environment initialization for term scripts.
// Exposes only memory-bounded, safe standard libraries without raw I/O or OS.

import "core:c"
import "core:c/libc"
import lua "../../platform/lua"

SCRIPT_MEM_CAP :: 64 * 1024 * 1024 // 64 MiB

Script_Vm :: struct {
	L:        ^lua.State,
	mem_used: int,
	mem_cap:  int,
	sched:    Scheduler,
}

@(private = "file")
_script_alloc :: proc "c" (ud, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	vm := (^Script_Vm)(ud)
	old := int(osize) if ptr != nil else 0
	if nsize == 0 {
		libc.free(ptr)
		vm.mem_used -= old
		return nil
	}
	if vm.mem_used - old + int(nsize) > vm.mem_cap do return nil
	p := libc.realloc(ptr, nsize)
	if p != nil do vm.mem_used += int(nsize) - old
	return p
}

script_vm_create :: proc(allocator := context.allocator) -> ^Script_Vm {
	vm := new(Script_Vm, allocator)
	vm.mem_cap = SCRIPT_MEM_CAP
	vm.L = lua.newstate(_script_alloc, vm)
	if vm.L == nil {
		free(vm, allocator)
		return nil
	}

	// Open standard safe libraries
	libs := [?]struct {
		name: cstring,
		open: lua.CFunction,
	}{
		{"_G", lua.luaopen_base},
		{"string", lua.luaopen_string},
		{"table", lua.luaopen_table},
		{"math", lua.luaopen_math},
		{"utf8", lua.luaopen_utf8},
		{"coroutine", lua.luaopen_coroutine},
	}

	for lib in libs {
		lua.luaL_requiref(vm.L, lib.name, lib.open, 1)
		lua.pop(vm.L, 1)
	}

	install_module_loader(vm.L)

	// Register Vm pointer in registry for C callbacks
	lua.pushlightuserdata(vm.L, vm)
	lua.setfield(vm.L, lua.REGISTRYINDEX, SCRIPT_VM_REGISTRY_KEY)

	scheduler_init(&vm.sched, vm.L, nil, allocator)
	return vm
}

SCRIPT_VM_REGISTRY_KEY :: "term.script_vm"

script_vm_of :: proc "c" (L: ^lua.State) -> ^Script_Vm {
	lua.getfield(L, lua.REGISTRYINDEX, SCRIPT_VM_REGISTRY_KEY)
	vm := (^Script_Vm)(lua.touserdata(L, -1))
	lua.pop(L, 1)
	return vm
}

script_vm_destroy :: proc(vm: ^Script_Vm) {
	if vm == nil do return
	allocator := vm.sched.allocator
	scheduler_destroy(&vm.sched)
	if vm.L != nil {
		lua.close(vm.L)
	}
	free(vm, allocator)
}

package feature_automation

// The sandbox contracts and adapters run in: a Lua 5.4 state with only the
// pure standard libraries (base without load/dofile/loadfile/print, string
// without dump, table, math, utf8), text chunks only (no bytecode), a memory
// cap and a time budget for every call into Lua. `require` reaches only the
// built-in `term` modules and adapter files (vm_require.odin).

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:os"
import "core:strings"
import "core:time"
import lua "../../platform/lua"

VM_MEMORY_MAX :: 64 * 1024 * 1024
VM_CALL_BUDGET :: 100 * time.Millisecond // one pure call: a contract function, a predicate, an adapter hook
VM_HOOK_EVERY :: 1000 // instructions between budget checks

Vm :: struct {
	L:           ^lua.State,
	mem_used:    int,
	mem_cap:     int,
	deadline:    time.Tick,
	over_budget: bool,
	adapter_dirs: [dynamic]string, // searched for `term.adapter.<name>` (owned)
}

vm_open :: proc(adapter_dirs: []string = nil) -> (vm: ^Vm, ok: bool) {
	vm = new(Vm)
	vm.mem_cap = VM_MEMORY_MAX
	for d in adapter_dirs do append(&vm.adapter_dirs, strings.clone(d))
	vm.L = lua.newstate(_vm_alloc, vm)
	if vm.L == nil {
		vm_close(vm)
		return nil, false
	}
	lua.sethook(vm.L, _vm_hook, lua.MASKCOUNT, VM_HOOK_EVERY)
	_vm_open_libs(vm)
	_vm_install_require(vm)
	return vm, true
}

vm_close :: proc(vm: ^Vm) {
	if vm == nil do return
	if vm.L != nil do lua.close(vm.L)
	for d in vm.adapter_dirs do delete(d)
	delete(vm.adapter_dirs)
	free(vm)
}

// vm_load_file runs a contract or adapter file and leaves its one result on the
// stack. err (temp allocator) explains a failure.
vm_load_file :: proc(vm: ^Vm, path: string) -> (err: string, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return strings.concatenate({path, ": cannot read it"}, context.temp_allocator), false
	defer delete(data)
	return vm_load_chunk(vm, data, path)
}

vm_load_chunk :: proc(vm: ^Vm, source: []u8, name: string) -> (err: string, ok: bool) {
	cname := strings.clone_to_cstring(strings.concatenate({"@", name}, context.temp_allocator), context.temp_allocator)
	if lua.luaL_loadbufferx(vm.L, raw_data(source), c.size_t(len(source)), cname, "t") != lua.OK {
		return vm_pop_error(vm), false
	}
	return vm_call(vm, 0, 1)
}

// vm_call calls the function below nargs arguments within the budget; the
// results (or nothing, on error) are left on the stack.
vm_call :: proc(vm: ^Vm, nargs, nresults: c.int) -> (err: string, ok: bool) {
	vm.over_budget = false
	vm.deadline = time.tick_add(time.tick_now(), VM_CALL_BUDGET)
	status := lua.pcall(vm.L, nargs, nresults, 0)
	vm.deadline = {}
	if status == lua.OK do return "", true
	return vm_pop_error(vm), false
}

// vm_pop_error turns the error on top of the stack into text and pops it.
vm_pop_error :: proc(vm: ^Vm) -> string {
	msg := strings.clone(lua.tostring(vm.L, -1), context.temp_allocator)
	if len(msg) == 0 do msg = "error object is not a string"
	lua.pop(vm.L, 1)
	return msg
}

@(private = "file")
_vm_open_libs :: proc(vm: ^Vm) {
	L := vm.L
	libs := [?]struct {
		name: cstring,
		open: lua.CFunction,
	}{{"_G", lua.luaopen_base}, {"string", lua.luaopen_string}, {"table", lua.luaopen_table}, {"math", lua.luaopen_math}, {"utf8", lua.luaopen_utf8}}
	for lib in libs {
		lua.luaL_requiref(L, lib.name, lib.open, 1)
		lua.pop(L, 1)
	}
	for name in ([?]cstring{"dofile", "loadfile", "load", "print", "collectgarbage"}) {
		lua.pushnil(L)
		lua.setglobal(L, name)
	}
	lua.getglobal(L, "string")
	lua.pushnil(L)
	lua.setfield(L, -2, "dump")
	lua.pop(L, 1)
	// math.random would make a pure function return different steps per run.
	lua.getglobal(L, "math")
	for name in ([?]cstring{"random", "randomseed"}) {
		lua.pushnil(L)
		lua.setfield(L, -2, name)
	}
	lua.pop(L, 1)
}

@(private = "file")
_vm_alloc :: proc "c" (ud, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
	vm := (^Vm)(ud)
	// osize is a type tag, not a size, when ptr is nil.
	old := int(osize) if ptr != nil else 0
	if nsize == 0 {
		libc.free(ptr)
		vm.mem_used -= old
		return nil
	}
	if vm.mem_used - old + int(nsize) > vm.mem_cap do return nil // Lua raises "not enough memory"
	p := libc.realloc(ptr, nsize)
	if p != nil do vm.mem_used += int(nsize) - old
	return p
}

@(private = "file")
_vm_hook :: proc "c" (L: ^lua.State, ar: rawptr) {
	vm := _vm_of(L)
	if vm == nil || vm.deadline == {} || time.tick_diff(vm.deadline, time.tick_now()) < 0 do return
	vm.over_budget = true
	context = runtime.default_context()
	lua.pushstring(L, "the call ran over its time budget (an endless loop?)")
	lua.error(L)
}

VM_REGISTRY_KEY :: "term.vm"

// _vm_of finds the Vm a state belongs to (stored in the registry).
_vm_of :: proc "c" (L: ^lua.State) -> ^Vm {
	lua.getfield(L, lua.REGISTRYINDEX, VM_REGISTRY_KEY)
	vm := (^Vm)(lua.touserdata(L, -1))
	lua.pop(L, 1)
	return vm
}

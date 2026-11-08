package feature_automation

// `require` in the sandbox: built-in `term` modules, and `term.adapter.<name>`
// files from the adapter directories. Nothing else, so a contract cannot reach
// the file system, the network or native code. Every module loads once.

import "base:runtime"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import lua "../../platform/lua"

ADAPTER_PREFIX :: "term.adapter."

@(private = "file")
LOADED_KEY :: "term.loaded"

// Builtin_Module: a built-in module's opener pushes its table.
@(private = "file")
Builtin_Module :: struct {
	name: string,
	open: lua.CFunction,
}

// Adapters that ship with term; a file of the same name in an adapter
// directory wins (a project or a user can replace one).
@(private = "file")
_BUNDLED := [?]struct {
	name:   string,
	source: string,
}{
	{"lazygit", #load("adapters/lazygit.lua", string)},
	{"fzf", #load("adapters/fzf.lua", string)},
	{"agent", #load("adapters/agent.lua", string)},
	{"claude_code", #load("adapters/claude_code.lua", string)},
	{"opencode", #load("adapters/opencode.lua", string)},
	{"agy", #load("adapters/agy.lua", string)},
}

bundled_adapter_names :: proc() -> []string {
	names := make([]string, len(_BUNDLED), context.temp_allocator)
	for b, i in _BUNDLED do names[i] = b.name
	return names
}

@(private = "file")
_BUILTINS := [?]Builtin_Module{
	{"term", term_module_open},
	{"term.screen", screen_module_open},
}

_vm_install_require :: proc(vm: ^Vm) {
	L := vm.L
	lua.pushlightuserdata(L, vm)
	lua.setfield(L, lua.REGISTRYINDEX, VM_REGISTRY_KEY)
	lua.newtable(L)
	lua.setfield(L, lua.REGISTRYINDEX, LOADED_KEY)
	lua.pushcfunction(L, _require)
	lua.setglobal(L, "require")
}

@(private = "file")
_require :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) != .String {
		lua.pushstring(L, "require expects a module name")
		return lua.error(L)
	}
	lua.settop(L, 1)
	lua.getfield(L, lua.REGISTRYINDEX, LOADED_KEY) // 2: loaded
	lua.pushvalue(L, 1)
	switch lua.rawget(L, 2) { // 3: loaded[name]
	case .Nil:
	case .Boolean:
		lua.pushstring(L, "require loop: a module requires itself")
		return lua.error(L)
	case .None, .Number, .String, .Table, .Function, .Userdata, .Thread, .Light_Userdata:
		return 1
	}
	lua.pop(L, 1)
	lua.pushvalue(L, 1)
	lua.pushboolean(L, 0) // loading: a cycle finds false
	lua.rawset(L, 2)
	if err, ok := _require_load(L, lua.tostring(L, 1)); !ok {
		lua.pushvalue(L, 1)
		lua.pushnil(L)
		lua.rawset(L, 2)
		lua.pushstring(L, err)
		return lua.error(L)
	}
	// 3: the module
	lua.pushvalue(L, 1)
	lua.pushvalue(L, 3)
	lua.rawset(L, 2)
	return 1
}

// _require_load pushes the module (true) or returns why it cannot load.
@(private = "file")
_require_load :: proc(L: ^lua.State, name: string) -> (err: string, ok: bool) {
	for b in _BUILTINS {
		if b.name != name do continue
		lua.pushcfunction(L, b.open)
		if lua.pcall(L, 0, 1, 0) != lua.OK do return _pop_text(L), false
		return "", true
	}
	if !strings.has_prefix(name, ADAPTER_PREFIX) || !_plain_name(name[len(ADAPTER_PREFIX):]) {
		return strings.concatenate({"module '", name, "' is not available: contracts require only term modules and term.adapter.<name>"}, context.temp_allocator), false
	}
	vm := _vm_of(L)
	file := strings.concatenate({name[len(ADAPTER_PREFIX):], ".lua"}, context.temp_allocator)
	for dir in vm.adapter_dirs {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil do continue
		cname := strings.clone_to_cstring(strings.concatenate({"@", path}, context.temp_allocator), context.temp_allocator)
		if lua.luaL_loadbufferx(L, raw_data(data), c.size_t(len(data)), cname, "t") != lua.OK do return _pop_text(L), false
		if lua.pcall(L, 0, 1, 0) != lua.OK do return _pop_text(L), false
		return "", true
	}
	short := name[len(ADAPTER_PREFIX):]
	for b in _BUNDLED {
		if b.name != short do continue
		cname := strings.clone_to_cstring(strings.concatenate({"=term.adapter.", short}, context.temp_allocator), context.temp_allocator)
		if lua.luaL_loadbufferx(L, raw_data(b.source), c.size_t(len(b.source)), cname, "t") != lua.OK do return _pop_text(L), false
		if lua.pcall(L, 0, 1, 0) != lua.OK do return _pop_text(L), false
		return "", true
	}
	return strings.concatenate({"adapter '", name, "' not found in the adapter directories or among the bundled ones"}, context.temp_allocator), false
}

// _plain_name: lowercase letters, digits and '_' only (no paths).
@(private = "file")
_plain_name :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 do return false
	for ch in s {
		switch ch {
		case 'a' ..= 'z', '0' ..= '9', '_':
		case: return false
		}
	}
	return true
}

@(private = "file")
_pop_text :: proc(L: ^lua.State) -> string {
	msg := strings.clone(lua.tostring(L, -1), context.temp_allocator)
	lua.pop(L, 1)
	return msg
}

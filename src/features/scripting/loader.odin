package feature_scripting

// Root module loader (`require "term"`, `require "term.*"`) and manifest validator.

import "base:runtime"
import "core:c"
import "core:strings"
import lua "../../platform/lua"

install_module_loader :: proc(L: ^lua.State) {
	lua.pushcfunction(L, _custom_require)
	lua.setglobal(L, "require")
}

@(private = "file")
_custom_require :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) != .String {
		lua.pushstring(L, "require expects a string module name")
		return lua.error(L)
	}

	name := lua.tostring(L, 1)
	switch name {
	case "term":
		return _open_mod_term(L)
	case "term.session":
		return open_mod_session(L)
	case "term.task":
		return open_mod_task(L)
	case "term.io":
		return open_mod_io(L)
	case "term.window":
		return open_mod_window(L)
	case:
		lua.pushstring(L, strings.concatenate({"unknown module '", name, "'"}, context.temp_allocator))
		return lua.error(L)
	}
}

@(private = "file")
_open_mod_term :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	// Submodules
	open_mod_session(L)
	lua.setfield(L, -2, "session")

	open_mod_task(L)
	lua.setfield(L, -2, "task")

	open_mod_io(L)
	lua.setfield(L, -2, "io")

	open_mod_window(L)
	lua.setfield(L, -2, "window")

	// Program manifest constructors (term.program / term.script)
	lua.pushcfunction(L, _term_program)
	lua.setfield(L, -2, "program")

	lua.pushcfunction(L, _term_program)
	lua.setfield(L, -2, "script")

	return 1
}

@(private = "file")
_term_program :: proc "c" (L: ^lua.State) -> c.int {
	if lua.type(L, 1) == .Function {
		lua.newtable(L)
		lua.pushvalue(L, 1)
		lua.setfield(L, -2, "main")
		return 1
	}
	if lua.type(L, 1) == .Table {
		lua.pushvalue(L, 1)
		return 1
	}
	lua.pushstring(L, "term.program expects a table or a main function")
	return lua.error(L)
}

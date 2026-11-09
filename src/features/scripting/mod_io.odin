package feature_scripting

// `term.io` Lua module: stdout printing and interactive input.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import lua "../../platform/lua"

open_mod_io :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	methods := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"print", _io_print},
		{"ask", _io_ask},
	}

	for m in methods {
		lua.pushcfunction(L, m.fn)
		lua.setfield(L, -2, m.name)
	}
	return 1
}

@(private = "file")
_io_print :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	n := lua.gettop(L)
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= n {
		s := lua.tostring(L, c.int(i))
		strings.write_string(&b, s)
		if i < n do strings.write_byte(&b, '\t')
	}
	fmt.println(strings.to_string(b))
	return 0
}

@(private = "file")
_io_ask :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	prompt := lua.tostring(L, 1)
	if len(prompt) > 0 {
		fmt.print(prompt)
		fmt.print(" ")
	}

	buf: [4096]u8
	bytes_read, err := os.read(os.stdin, buf[:])
	if err != nil || bytes_read <= 0 {
		lua.pushnil(L)
		return 1
	}

	line := strings.trim_space(string(buf[:bytes_read]))
	lua.pushstring(L, line)
	return 1
}

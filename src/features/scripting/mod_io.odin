package feature_scripting

// `term.io` Lua module: stdout printing, interactive input, and raw terminal I/O.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import lua "../../platform/lua"

@(private)
_orig_termios: posix.termios
@(private)
_raw_mode_active: bool

open_mod_io :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)

	methods := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"print",    _io_print},
		{"ask",      _io_ask},
		{"raw_mode", _io_raw_mode},
		{"read_raw", _io_read_raw},
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

@(private = "file")
_io_raw_mode :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	enable := true
	if lua.type(L, 1) == .Boolean {
		enable = lua.toboolean(L, 1) != 0
	}

	if enable {
		if _raw_mode_active {
			lua.pushboolean(L, 1)
			return 1
		}
		if posix.tcgetattr(posix.FD(0), &_orig_termios) != .OK {
			lua.pushboolean(L, 0)
			return 1
		}
		raw := _orig_termios
		raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
		raw.c_oflag -= {.OPOST}
		raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
		raw.c_cflag -= {.PARENB, .CSTOPB}
		raw.c_cflag += {.CS8}
		raw.c_cc[.VMIN] = 0
		raw.c_cc[.VTIME] = 0
		if posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &raw) != .OK {
			lua.pushboolean(L, 0)
			return 1
		}
		_raw_mode_active = true
		lua.pushboolean(L, 1)
		return 1
	}

	if _raw_mode_active {
		posix.tcsetattr(posix.FD(0), .TCSAFLUSH, &_orig_termios)
		_raw_mode_active = false
	}
	lua.pushboolean(L, 1)
	return 1
}

@(private = "file")
_io_read_raw :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	timeout := c.int(0)
	if lua.type(L, 1) == .Number {
		timeout = c.int(lua.tointegerx(L, 1, nil))
	}

	pfd := posix.pollfd{
		fd = posix.FD(0),
		events = {.IN},
	}
	res := posix.poll(&pfd, 1, timeout)
	if res <= 0 || .IN not_in pfd.revents {
		lua.pushnil(L)
		return 1
	}

	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 {
		lua.pushnil(L)
		return 1
	}
	lua.pushstring(L, string(buf[:n]))
	return 1
}

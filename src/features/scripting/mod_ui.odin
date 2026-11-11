package feature_scripting

// `term.ui` Lua module: ergonomic OSC 8400 (Surface & Layer Protocol) builders,
// direct stdout writer, and event parser for single-PTY TUI applications.
import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import lua "../../platform/lua"

open_mod_ui :: proc "c" (L: ^lua.State) -> c.int {
	lua.newtable(L)
	methods := [?]struct { name: cstring, fn: lua.CFunction }{
		{"probe", _ui_probe}, {"reset", _ui_reset}, {"target", _ui_target},
		{"split", _ui_split}, {"popup", _ui_popup}, {"focus", _ui_focus},
		{"show", _ui_show}, {"hide", _ui_hide}, {"close", _ui_close},
		{"write", _ui_write}, {"parse_event", _ui_parse_event},
	}
	for m in methods {
		lua.pushcfunction(L, m.fn)
		lua.setfield(L, -2, m.name)
	}
	return 1
}

@(private = "file")
_ui_opt_int :: proc(L: ^lua.State, idx: c.int, field: cstring, def: int) -> int {
	lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .Number do return int(lua.tointegerx(L, -1, nil))
	return def
}

@(private = "file")
_ui_opt_bool :: proc(L: ^lua.State, idx: c.int, field: cstring, def: bool) -> bool {
	lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .Boolean do return lua.toboolean(L, -1) != 0
	if lua.type(L, -1) == .Number do return lua.tointegerx(L, -1, nil) != 0
	return def
}

@(private = "file")
_ui_opt_str :: proc(L: ^lua.State, idx: c.int, field: cstring) -> string {
	lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if lua.type(L, -1) == .String do return lua.tostring(L, -1)
	return ""
}

@(private = "file")
_ui_probe :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushstring(L, "\x1b]8400;?\x1b\\")
	return 1
}

@(private = "file")
_ui_reset :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushstring(L, "\x1b]8400;0\x1b\\")
	return 1
}

@(private = "file")
_ui_target :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	id := int(lua.tointegerx(L, 1, nil)) if lua.type(L, 1) == .Number else 0
	text := lua.tostring(L, 2) if lua.type(L, 2) == .String else ""
	res := fmt.tprintf("\x1b]8400;1;%d\x07%s", max(0, id), text)
	lua.pushstring(L, res)
	free_all(context.temp_allocator)
	return 1
}

@(private = "file")
_ui_split :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) != .Table {
		lua.pushstring(L, "term.ui.split expects an options table")
		return lua.error(L)
	}
	id := max(1, _ui_opt_int(L, 1, "id", 1))
	parent := max(0, _ui_opt_int(L, 1, "parent", 0))
	ratio := clamp(_ui_opt_int(L, 1, "ratio", 50), 10, 90)
	foc := 1 if _ui_opt_bool(L, 1, "focus", false) else 0
	dir := _ui_opt_int(L, 1, "dir", 0)
	switch _ui_opt_str(L, 1, "dir") {
	case "right": dir = 0
	case "down":  dir = 1
	case "left":  dir = 2
	case "up":    dir = 3
	}
	return _ui_push_osc_fmt(L, "\x1b]8400;2;%d;%d;%d;%d;%d\x1b\\", id, parent, dir, ratio, foc)
}

@(private = "file")
_ui_popup :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) != .Table {
		lua.pushstring(L, "term.ui.popup expects an options table")
		return lua.error(L)
	}
	id, w, h := max(1, _ui_opt_int(L, 1, "id", 1)), max(1, _ui_opt_int(L, 1, "w", 30)), max(1, _ui_opt_int(L, 1, "h", 8))
	x, y, z := _ui_opt_int(L, 1, "x", 0), _ui_opt_int(L, 1, "y", 0), _ui_opt_int(L, 1, "z", 10)
	foc := 1 if _ui_opt_bool(L, 1, "focus", true) else 0
	anchor, chrome := _ui_popup_enums(L)
	title := _ui_opt_str(L, 1, "title")
	b64 := base64.encode(transmute([]u8)title, base64.ENC_TABLE, context.temp_allocator) if len(title) > 0 else ""
	res := fmt.tprintf("\x1b]8400;3;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s\x1b\\", id, w, h, anchor, x, y, z, chrome, foc, b64)
	lua.pushstring(L, res)
	free_all(context.temp_allocator)
	return 1
}

@(private = "file")
_ui_popup_enums :: proc(L: ^lua.State) -> (anchor: int, chrome: int) {
	anchor = _ui_opt_int(L, 1, "anchor", 0)
	switch _ui_opt_str(L, 1, "anchor") {
	case "center":   anchor = 0
	case "absolute": anchor = 1
	case "cursor":   anchor = 2
	}
	chrome = _ui_opt_int(L, 1, "chrome", 2)
	switch _ui_opt_str(L, 1, "chrome") {
	case "none":  chrome = 0
	case "box":   chrome = 1
	case "modal": chrome = 2
	}
	return
}

@(private = "file")
_ui_push_osc_fmt :: proc(L: ^lua.State, fmt_str: string, args: ..any) -> c.int {
	buf: [64]u8
	lua.pushstring(L, fmt.bprintf(buf[:], fmt_str, ..args))
	return 1
}

@(private = "file")
_ui_focus :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _ui_push_osc_fmt(L, "\x1b]8400;4;%d\x1b\\", max(0, int(lua.tointegerx(L, 1, nil))))
}

@(private = "file")
_ui_show :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _ui_push_osc_fmt(L, "\x1b]8400;5;%d;1\x1b\\", max(1, int(lua.tointegerx(L, 1, nil))))
}

@(private = "file")
_ui_hide :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _ui_push_osc_fmt(L, "\x1b]8400;5;%d;0\x1b\\", max(1, int(lua.tointegerx(L, 1, nil))))
}

@(private = "file")
_ui_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _ui_push_osc_fmt(L, "\x1b]8400;6;%d\x1b\\", max(1, int(lua.tointegerx(L, 1, nil))))
}

@(private = "file")
_ui_write :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) == .String {
		s := lua.tostring(L, 1)
		if len(s) > 0 do _, _ = os.write(os.stdout, transmute([]u8)s)
	}
	return 0
}

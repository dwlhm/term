package feature_automation

// The fields and methods of a screen in Lua (lua_screen.odin).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:unicode/utf8"
import "core:os"
import "core:strings"
import lua "../../platform/lua"

push_screen_field :: proc(L: ^lua.State, s: ^Screen, key: string) -> bool {
	snap := &s.snap
	switch key {
	case "cols":    lua.pushinteger(L, lua.Integer(s.cols))
	case "rows":    lua.pushinteger(L, lua.Integer(s.rows))
	case "gen":     lua.pushinteger(L, lua.Integer(snap.gen))
	case "alt":     lua.pushboolean(L, c.int(snap.alt_screen))
	case "title":   lua.pushstring(L, snap.title)
	case "process": lua.pushstring(L, snap.process)
	case "prompt":  lua.pushstring(L, _lower(snap.prompt_state))
	case "cursor":
		lua.createtable(L, 0, 3)
		_set_int(L, "row", int(snap.cursor_row) + 1)
		_set_int(L, "col", int(snap.cursor_col) + 1)
		_set_bool(L, "visible", snap.cursor_visible)
	case "status":
		states := [?]string{"clear", "idle", "working", "blocked", "done", "error"}
		lua.createtable(L, 0, 4)
		_set_str(L, "state", states[snap.status_state] if int(snap.status_state) < len(states) else "clear")
		_set_str(L, "app", snap.status_app)
		_set_str(L, "kind", snap.status_kind)
		_set_str(L, "msg", snap.status_msg)
	case:
		return false
	}
	return true
}

screen_method :: proc(key: string) -> lua.CFunction {
	switch key {
	case "line":     return _m_line
	case "lines":    return _m_lines
	case "history":  return _m_history
	case "cell":     return _m_cell
	case "elements": return _m_elements
	}
	return nil
}

// s:line(n): row n's text without trailing blanks ("" outside the screen).
@(private = "file")
_m_line :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := screen_ref_of(L, 1)
	if s == nil do return _fail(L, "line: call it as screen:line(n)")
	r := int(lua.tointegerx(L, 2, nil)) - 1
	lua.pushstring(L, strings.trim_right(screen_text(s, r, 0, s.cols), " ") if r >= 0 && r < s.rows else "")
	return 1
}

@(private = "file")
_m_lines :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := screen_ref_of(L, 1)
	if s == nil do return _fail(L, "lines: call it as screen:lines()")
	lua.createtable(L, c.int(s.rows), 0)
	for r in 0 ..< s.rows {
		lua.pushstring(L, strings.trim_right(screen_text(s, r, 0, s.cols), " "))
		lua.rawseti(L, -2, lua.Integer(r + 1))
	}
	return 1
}

// s:history(): scrollback lines in the snapshot, oldest first.
@(private = "file")
_m_history :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := screen_ref_of(L, 1)
	if s == nil do return _fail(L, "history: call it as screen:history()")
	lua.createtable(L, c.int(len(s.snap.history)), 0)
	for row, i in s.snap.history {
		b := strings.builder_make(context.temp_allocator)
		for run in row.runs do strings.write_string(&b, run.text)
		lua.pushstring(L, strings.to_string(b))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// s:cell(row, col): {char, fg, bg, rgb_fg, rgb_bg, bold, dim, italic,
// underline, inverse, strike, link, wide}; nil outside the screen.
@(private = "file")
_m_cell :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := screen_ref_of(L, 1)
	if s == nil do return _fail(L, "cell: call it as screen:cell(row, col)")
	cell := screen_cell(s, int(lua.tointegerx(L, 2, nil)) - 1, int(lua.tointegerx(L, 3, nil)) - 1)
	if cell == nil {
		lua.pushnil(L)
		return 1
	}
	st := cell.style
	lua.createtable(L, 0, 13)
	buf, n := utf8.encode_rune(cell.ch)
	_set_str(L, "char", string(buf[:n]))
	_set_int(L, "fg", int(st.fg)); _set_int(L, "bg", int(st.bg))
	if st.has_fg_rgb do _set_int(L, "rgb_fg", int(st.fg_rgb[0]) << 16 | int(st.fg_rgb[1]) << 8 | int(st.fg_rgb[2]))
	if st.has_bg_rgb do _set_int(L, "rgb_bg", int(st.bg_rgb[0]) << 16 | int(st.bg_rgb[1]) << 8 | int(st.bg_rgb[2]))
	flags := [?]cstring{"bold", "dim", "italic", "underline", "inverse", "strike", "blink", "hidden"}
	for f, i in flags do _set_bool(L, f, st.style & (1 << u8(i)) != 0)
	_set_int(L, "link", int(st.link))
	_set_bool(L, "wide", cell.cont)
	return 1
}

// s:elements(): {ref, role, name, text, row, col, width, height, parent,
// selected, focused, checked, source} per element.
@(private = "file")
_m_elements :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if screen_ref_of(L, 1) == nil do return _fail(L, "elements: call it as screen:elements()")
	es := screen_elements_of(L, 1)
	lua.createtable(L, c.int(len(es)), 0)
	for e, i in es {
		push_element(L, es, i)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

push_element :: proc(L: ^lua.State, es: []Element, i: int) {
	e := es[i]
	lua.createtable(L, 0, 13)
	_set_str(L, "ref", element_ref(i))
	_set_str(L, "role", _lower(e.role))
	_set_str(L, "name", e.name)
	_set_str(L, "text", e.text)
	_set_int(L, "row", e.box.row + 1); _set_int(L, "col", e.box.col + 1)
	_set_int(L, "width", e.box.width); _set_int(L, "height", e.box.height)
	if e.parent >= 0 do _set_str(L, "parent", element_ref(e.parent))
	_set_bool(L, "selected", e.selected); _set_bool(L, "focused", e.focused); _set_bool(L, "checked", e.checked)
	_set_str(L, "source", "inferred" if e.source == .Inferred else ("osc133" if e.source == .Osc133 else "osc8"))
}

@(private = "file")
_lower :: proc(v: any) -> string {
	return strings.to_lower(fmt.tprint(v), context.temp_allocator)
}

@(private = "file")
_set_str :: proc(L: ^lua.State, k: cstring, v: string) { lua.pushstring(L, v); lua.setfield(L, -2, k) }
@(private = "file")
_set_int :: proc(L: ^lua.State, k: cstring, v: int) { lua.pushinteger(L, lua.Integer(v)); lua.setfield(L, -2, k) }
@(private = "file")
_set_bool :: proc(L: ^lua.State, k: cstring, v: bool) { lua.pushboolean(L, c.int(v)); lua.setfield(L, -2, k) }

os_read :: proc(path: string) -> (data: []u8, failed: bool) {
	d, err := os.read_entire_file(path, context.allocator)
	return d, err != nil
}

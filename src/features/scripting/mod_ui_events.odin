package feature_scripting

// Event parser & hex decoder for OSC 8400 (Surface & Layer Protocol).

import "base:runtime"
import "core:c"
import "core:strconv"
import "core:strings"
import lua "../../platform/lua"

@(private)
_ui_set_int :: proc(L: ^lua.State, k: cstring, v: int) {
	lua.pushinteger(L, lua.Integer(v))
	lua.setfield(L, -2, k)
}

@(private)
_ui_set_str :: proc(L: ^lua.State, k: cstring, v: string) {
	lua.pushstring(L, v)
	lua.setfield(L, -2, k)
}

@(private)
_ui_push_nil :: proc(L: ^lua.State) -> c.int {
	lua.pushnil(L)
	return 1
}

@(private)
_from_hex_digit :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a' + 10)
	case 'A' ..= 'F': return int(c - 'A' + 10)
	case: return -1
	}
}

@(private)
_hex_decode :: proc(hex: string) -> string {
	if len(hex) < 2 do return ""
	b := make([]u8, len(hex) / 2, context.temp_allocator)
	out_len := 0
	for i := 0; i + 1 < len(hex); i += 2 {
		h1 := _from_hex_digit(hex[i])
		h2 := _from_hex_digit(hex[i + 1])
		if h1 < 0 || h2 < 0 do break
		b[out_len] = u8((h1 << 4) | h2)
		out_len += 1
	}
	return string(b[:out_len])
}

@(private)
_ui_extract_osc_body :: proc(raw: string) -> (body: string, ok: bool) {
	idx := strings.index(raw, "\x1b]8400;")
	if idx < 0 do return "", false
	body = raw[idx + 7:]
	end := strings.index(body, "\x1b\\")
	if end < 0 do end = strings.index_byte(body, 0x07)
	if end >= 0 do body = body[:end]
	return body, true
}

@(private)
_ui_parse_event :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.type(L, 1) != .String do return _ui_push_nil(L)
	body, ok := _ui_extract_osc_body(lua.tostring(L, 1))
	if !ok do return _ui_push_nil(L)
	if body == "?1" {
		lua.newtable(L)
		_ui_set_str(L, "kind", "probe")
		lua.pushboolean(L, 1)
		lua.setfield(L, -2, "supported")
		return 1
	}
	return _ui_parse_event_fields(L, body)
}

@(private = "file")
_ui_parse_resize :: proc(L: ^lua.State, id: int, rem: ^string) -> c.int {
	c_s, ok2 := strings.split_iterator(rem, ";")
	r_s, ok3 := strings.split_iterator(rem, ";")
	if !ok2 || !ok3 do return _ui_push_nil(L)
	cols, _ := strconv.parse_int(c_s)
	rows, _ := strconv.parse_int(r_s)
	lua.newtable(L)
	_ui_set_str(L, "kind", "resize")
	_ui_set_int(L, "id", id)
	_ui_set_int(L, "cols", cols)
	_ui_set_int(L, "rows", rows)
	return 1
}

@(private = "file")
_ui_parse_event_fields :: proc(L: ^lua.State, body: string) -> c.int {
	rem := body
	op, ok0 := strings.split_iterator(&rem, ";")
	id_s, ok1 := strings.split_iterator(&rem, ";")
	if !ok0 || !ok1 do return _ui_push_nil(L)
	id, _ := strconv.parse_int(id_s)

	switch op {
	case "6":
		lua.newtable(L)
		_ui_set_str(L, "kind", "close")
		_ui_set_int(L, "id", id)
		return 1
	case "7":
		hex_s, _ := strings.split_iterator(&rem, ";")
		data := _hex_decode(hex_s)
		lua.newtable(L)
		_ui_set_str(L, "kind", "input")
		_ui_set_int(L, "id", id)
		_ui_set_str(L, "data", data)
		return 1
	case "8":
		lua.newtable(L)
		_ui_set_str(L, "kind", "focus")
		_ui_set_int(L, "id", id)
		return 1
	case "9":
		return _ui_parse_resize(L, id, &rem)
	}
	return _ui_push_nil(L)
}

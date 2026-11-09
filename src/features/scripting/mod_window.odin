package feature_scripting

// `term.window` module: split, tab, show, attach window control bindings.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import ctrl_feat "../control"
import proto "../session_proto"
import ipc "../../platform/ipc"
import lua "../../platform/lua"

open_mod_window :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.createtable(L, 0, 4)

	funcs := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"split", _mod_window_split},
		{"tab", _mod_window_tab},
		{"show", _mod_window_show},
		{"attach", _mod_window_attach},
	}

	for f in funcs {
		lua.pushcfunction(L, f.fn)
		lua.setfield(L, -2, f.name)
	}

	return 1
}

@(private = "package")
send_window_cmd :: proc(cmd: string) -> (ok: bool, err_msg: string) {
	at_buf: [256]u8
	at, aerr := proto.control_endpoint(at_buf[:])
	if aerr.kind != .None do return false, "gui window not available"

	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	backoff := 25 * time.Millisecond
	reply: string
	err: ipc.Error
	for attempt in 0..<5 {
		reply, err = ipc.line_call(at, cmd, reply_buf[:])
		if err.kind != .None || reply != "err busy\n" || attempt == 4 do break
		time.sleep(backoff)
		backoff *= 2
	}

	if err.kind != .None {
		if err.kind == .No_Server do return false, "gui window not running"
		return false, err.reason if len(err.reason) > 0 else ipc.error_message(err)
	}

	res_ok, code, msg, _, well_formed := ctrl_feat.control_split_reply(reply)
	if !well_formed || !res_ok {
		if len(msg) > 0 do return false, msg
		if len(code) > 0 do return false, code
		return false, "unknown control error"
	}
	return true, ""
}

@(private = "package")
extract_session_id :: proc(L: ^lua.State, idx: c.int) -> (u32, bool) {
	if lua.type(L, idx) == .Number {
		val := lua.tointegerx(L, idx, nil)
		if val > 0 && val <= 0xFFFF_FFFF do return u32(val), true
		return 0, false
	}
	if lua.type(L, idx) == .Userdata {
		ptr := (^u32)(lua.touserdata(L, idx))
		if ptr != nil && ptr^ > 0 do return ptr^, true
	}
	return 0, false
}

@(private = "file")
_push_cmd_res :: proc(L: ^lua.State, ok: bool, err_msg: string) -> c.int {
	lua.pushboolean(L, 1 if ok else 0)
	if !ok {
		lua.pushstring(L, err_msg)
		return 2
	}
	return 1
}

@(private = "file")
_mod_window_split :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	dir := "right"
	sid: u32 = 0
	has_sid := false

	if lua.type(L, 1) == .String {
		dir = lua.tostring(L, 1)
		if id, ok := extract_session_id(L, 2); ok {
			sid = id
			has_sid = true
		}
	} else if lua.type(L, 1) == .Table {
		lua.getfield(L, 1, "direction")
		if lua.type(L, -1) == .String do dir = lua.tostring(L, -1)
		lua.pop(L, 1)

		lua.getfield(L, 1, "session")
		if id, ok := extract_session_id(L, -1); ok {
			sid = id
			has_sid = true
		}
		lua.pop(L, 1)
	} else if id, ok := extract_session_id(L, 1); ok {
		sid = id
		has_sid = true
	}

	cmd := fmt.tprintf("split %s %d", dir, sid) if has_sid else fmt.tprintf("split %s", dir)
	ok, err_msg := send_window_cmd(cmd)
	return _push_cmd_res(L, ok, err_msg)
}

@(private = "file")
_mod_window_tab :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sid: u32 = 0
	has_sid := false

	if lua.type(L, 1) == .Table {
		lua.getfield(L, 1, "session")
		if id, ok := extract_session_id(L, -1); ok {
			sid = id
			has_sid = true
		}
		lua.pop(L, 1)
	} else if id, ok := extract_session_id(L, 1); ok {
		sid = id
		has_sid = true
	}

	cmd := fmt.tprintf("tab %d", sid) if has_sid else "tab"
	ok, err_msg := send_window_cmd(cmd)
	return _push_cmd_res(L, ok, err_msg)
}

@(private = "file")
_mod_window_show :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	ok, err_msg := send_window_cmd("show")
	return _push_cmd_res(L, ok, err_msg)
}

@(private = "file")
_mod_window_attach :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sid: u32 = 0
	has_sid := false

	if lua.type(L, 1) == .Table {
		lua.getfield(L, 1, "session")
		if id, ok := extract_session_id(L, -1); ok {
			sid = id
			has_sid = true
		}
		lua.pop(L, 1)
	} else if id, ok := extract_session_id(L, 1); ok {
		sid = id
		has_sid = true
	}

	if !has_sid do return _push_cmd_res(L, false, "missing session to attach")

	cmd := fmt.tprintf("attach %d", sid)
	ok, err_msg := send_window_cmd(cmd)
	return _push_cmd_res(L, ok, err_msg)
}

@(private = "package")
session_obj_split :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	id, ok := extract_session_id(L, 1)
	if !ok do return 0

	dir := "right"
	if lua.type(L, 2) == .String {
		dir = lua.tostring(L, 2)
	} else if lua.type(L, 2) == .Table {
		lua.getfield(L, 2, "direction")
		if lua.type(L, -1) == .String do dir = lua.tostring(L, -1)
		lua.pop(L, 1)
	}

	cmd := fmt.tprintf("split %s %d", dir, id)
	ok_res, err_msg := send_window_cmd(cmd)
	return _push_cmd_res(L, ok_res, err_msg)
}

@(private = "package")
session_obj_attach :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	id, ok := extract_session_id(L, 1)
	if !ok do return 0

	cmd := fmt.tprintf("attach %d", id)
	ok_res, err_msg := send_window_cmd(cmd)
	return _push_cmd_res(L, ok_res, err_msg)
}


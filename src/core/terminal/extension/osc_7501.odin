package terminal_extension

// OSC 7501 Program Status Protocol (Mitchell Hashimoto, October 2026)
// Autonomous Core Terminal Engine (src/core/terminal/extension/*).
//
// Invariant: Wire format parsing of the standard `key=val[:key=val]...` sequence.
// Zero heap allocations in steady-state reporting.

import "core:encoding/base64"
import "core:strings"

MAX_PROGRAM_APP_LEN   :: 32
MAX_PROGRAM_MSG_LEN   :: 256
MAX_PROGRAM_TITLE_LEN :: 128

Program_State :: enum u8 {
	Clear   = 0,
	Idle    = 1,
	Working = 2,
	Blocked = 3,
	Done    = 4,
	Error   = 5,
}

Program_Status :: struct {
	state:     Program_State,
	app_buf:   [MAX_PROGRAM_APP_LEN]u8,
	app_len:   int,
	msg_buf:   [MAX_PROGRAM_MSG_LEN]u8,
	msg_len:   int,
	title_buf: [MAX_PROGRAM_TITLE_LEN]u8,
	title_len: int,
	kind_buf:  [32]u8,
	kind_len:  int,
}

program_status_app :: proc "contextless" (p: ^Program_Status) -> string {
	if p == nil || p.app_len == 0 do return ""
	return string(p.app_buf[:p.app_len])
}

program_status_msg :: proc "contextless" (p: ^Program_Status) -> string {
	if p == nil || p.msg_len == 0 do return ""
	return string(p.msg_buf[:p.msg_len])
}

program_status_title :: proc "contextless" (p: ^Program_Status) -> string {
	if p == nil || p.title_len == 0 do return ""
	return string(p.title_buf[:p.title_len])
}

Osc_7501_Sink :: #type proc(user_data: rawptr, status: Program_Status) -> bool

Osc_7501_Context :: struct {
	sink:      Osc_7501_Sink,
	user_data: rawptr,
}

@(private = "file")
_parse_program_state :: proc(val: string) -> (Program_State, bool) {
	switch val {
	case "clear":   return .Clear, true
	case "idle":    return .Idle, true
	case "working": return .Working, true
	case "blocked": return .Blocked, true
	case "done":    return .Done, true
	case "error":   return .Error, true
	}
	return .Clear, false
}

// osc_7501_parse decodes a `key=value[:key=value]...` payload into Program_Status.
osc_7501_parse :: proc(payload: string) -> (status: Program_Status, ok: bool) {
	if len(payload) == 0 do return {}, false

	it := payload
	has_state := false

	for len(it) > 0 {
		part: string
		colon_idx := strings.index_byte(it, ':')
		if colon_idx >= 0 {
			part = it[:colon_idx]
			it = it[colon_idx + 1:]
		} else {
			part = it
			it = ""
		}

		eq_idx := strings.index_byte(part, '=')
		if eq_idx < 1 do continue
		k := part[:eq_idx]
		v := part[eq_idx + 1:]

		switch k {
		case "state":
			if st, valid := _parse_program_state(v); valid {
				status.state = st
				has_state = true
			}
		case "app":
			copy_len := min(len(v), MAX_PROGRAM_APP_LEN)
			copy(status.app_buf[:copy_len], v[:copy_len])
			status.app_len = copy_len
		case "kind":
			copy_len := min(len(v), len(status.kind_buf))
			copy(status.kind_buf[:copy_len], v[:copy_len])
			status.kind_len = copy_len
		case "title":
			copy_len := min(len(v), MAX_PROGRAM_TITLE_LEN)
			copy(status.title_buf[:copy_len], v[:copy_len])
			status.title_len = copy_len
		case "msg":
			// Attempt base64 decode first; fallback to raw string if not base64
			msg_str := v
			if decoded, dec_err := base64.decode(v, allocator = context.temp_allocator); dec_err == nil && len(decoded) > 0 {
				msg_str = string(decoded)
			}
			copy_len := min(len(msg_str), MAX_PROGRAM_MSG_LEN)
			copy(status.msg_buf[:copy_len], msg_str[:copy_len])
			status.msg_len = copy_len
		}
	}

	return status, has_state
}

osc_7501_handler :: proc(user_data: rawptr, osc_id: int, payload: string, term: rawptr) -> bool {
	ctx := (^Osc_7501_Context)(user_data)
	if ctx == nil || ctx.sink == nil do return false

	status, ok := osc_7501_parse(payload)
	if !ok do return false

	return ctx.sink(ctx.user_data, status)
}

// osc_7501_encode appends the report that reproduces p (a new viewer's first
// paint carries the latest one). Nothing for .Clear. msg goes out base64.
osc_7501_encode :: proc(p: ^Program_Status, out: ^[dynamic]u8) {
	if p == nil || p.state == .Clear do return
	STATES := [Program_State]string{.Clear = "clear", .Idle = "idle", .Working = "working", .Blocked = "blocked", .Done = "done", .Error = "error"}
	append(out, "\x1b]7501;state=")
	append(out, STATES[p.state])
	_encode_field(out, "app", p.app_buf[:p.app_len])
	_encode_field(out, "kind", p.kind_buf[:p.kind_len])
	_encode_field(out, "title", p.title_buf[:p.title_len])
	if p.msg_len > 0 {
		append(out, ":msg=")
		_append_base64(out, p.msg_buf[:p.msg_len])
	}
	append(out, "\x1b\\")
}

@(private = "file")
_encode_field :: proc(out: ^[dynamic]u8, key: string, v: []u8) {
	if len(v) == 0 do return
	append(out, ":")
	append(out, key)
	append(out, "=")
	append(out, ..v)
}

@(private = "file")
_append_base64 :: proc(out: ^[dynamic]u8, src: []u8) {
	ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i := 0; i < len(src); i += 3 {
		n := min(3, len(src) - i)
		v := u32(src[i]) << 16
		if n > 1 do v |= u32(src[i + 1]) << 8
		if n > 2 do v |= u32(src[i + 2])
		for k in 0..<4 {
			if k <= n do append(out, ALPHABET[(v >> (18 - 6 * u32(k))) & 63])
			else do append(out, '=')
		}
	}
}

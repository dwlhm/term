package feature_control

// Term Control Protocol (text, one request line → one reply)
// Feature Composition Layer (src/features/control/*). Pure: no I/O, no app state.
//
// Requests (single spaces, lowercase verbs, ids are decimal u32 > 0):
//   ping | show | quit | ls | attach <id> | kill <id>
// Reply:
//   "ok\n" [body]            success; body only for ls / ping
//   "err <code> <message>\n" failure; <code> is a Control_Err_Code name in snake_case
// ls body: one row per session, fields separated by '\t', row ends with '\n':
//   id  state  pid  elapsed_s  process  cwd  status
//   state ∈ {idle, busy, exited}; elapsed_s integer seconds (0 if unknown);
//   any '\t' / '\n' / '\r' inside text fields is replaced with ' '.
// ping body: "term <version>\n".

import "core:strings"

Control_Verb :: enum u8 {
	Ping,
	Show,
	Quit,
	List,
	Attach,
	Kill,
}

Control_Request :: struct {
	verb: Control_Verb,
	id:   u32, // only for .Attach / .Kill
}

Control_Parse_Error :: enum u8 {
	None,
	Empty,
	Unknown_Verb,
	Missing_Id,
	Bad_Id,     // not decimal, 0, or overflows u32
	Extra_Args,
}

Control_Err_Code :: enum u8 {
	Bad_Request, // → "bad_request"
	Not_Found,   // → "not_found"
	Exited,      // → "exited"   (attach on a dead session)
	Internal,    // → "internal"
}

Control_Session_State :: enum u8 {
	Idle,   // → "idle"
	Busy,   // → "busy"
	Exited, // → "exited"
}

Control_Session_Row :: struct {
	id:        u32,
	state:     Control_Session_State,
	pid:       int,
	elapsed_s: int,
	process:   string,
	cwd:       string,
	status:    string,
}

// control_parse_request parses one request line (no trailing '\n').
// Leading/trailing ASCII whitespace is trimmed; tokens are split on runs of ' '.
control_parse_request :: proc(line: string) -> (req: Control_Request, err: Control_Parse_Error) {
	unimplemented("T6")
}

// control_format_request writes the canonical request line (no '\n') into buf.
control_format_request :: proc(req: Control_Request, buf: []u8) -> string {
	unimplemented("T6")
}

control_write_ok :: proc(b: ^strings.Builder) {
	unimplemented("T6")
}

// control_write_err writes "err <code> <message>\n"; '\n'/'\r' in message → ' '.
control_write_err :: proc(b: ^strings.Builder, code: Control_Err_Code, message: string) {
	unimplemented("T6")
}

control_write_session_row :: proc(b: ^strings.Builder, row: Control_Session_Row) {
	unimplemented("T6")
}

// control_parse_session_row parses one ls row (no trailing '\n'); string
// fields alias line. false on wrong field count / bad numbers / bad state.
control_parse_session_row :: proc(line: string) -> (row: Control_Session_Row, ok: bool) {
	unimplemented("T6")
}

// control_parse_error_message returns a short human message for err.
control_parse_error_message :: proc(err: Control_Parse_Error) -> string {
	unimplemented("T6")
}

// control_split_reply splits a full reply. ok = head line is exactly "ok";
// otherwise code/message come from "err <code> <message>" (message may be
// empty). body is everything after the first '\n'. well_formed = false when
// the head is neither form or there is no '\n'. All strings alias reply.
control_split_reply :: proc(reply: string) -> (ok: bool, code, message, body: string, well_formed: bool) {
	unimplemented("T6")
}

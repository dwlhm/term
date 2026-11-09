package feature_control

// Term Control Protocol (text, one request line → one reply)
// Feature Composition Layer (src/features/control/*). Pure: no I/O, no app state.
//
// Requests (single spaces, lowercase verbs, ids are decimal u32 > 0):
//   ping | show | quit | ls | attach <id> | kill <id>
// ls and kill are parsed here (the CLI shares this grammar) but served by the
// session core over the stream protocol, not by this line protocol.
// Reply:
//   "ok\n" [body]            success; body only for ping
//   "err <code> <message>\n" failure; <code> is a Control_Err_Code name in snake_case
// ping body: "term <version>\n".

import "core:fmt"
import "core:strconv"
import "core:strings"

Split_Dir :: enum u8 {
	Right,
	Down,
}

Control_Verb :: enum u8 {
	Ping,
	Show,
	Quit,
	List,
	Attach,
	Kill,
	Split,
	Tab,
}

Control_Request :: struct {
	verb:      Control_Verb,
	id:        u32,       // .Attach / .Kill / .Split / .Tab
	split_dir: Split_Dir, // only for .Split
	force:     bool,      // only for .Quit
}

Control_Parse_Error :: enum u8 {
	None,
	Empty,
	Unknown_Verb,
	Missing_Id,
	Bad_Id,     // not decimal, 0, or overflows u32
	Missing_Direction,
	Bad_Direction,
	Extra_Args,
}

Control_Err_Code :: enum u8 {
	Bad_Request, // → "bad_request"
	Not_Found,   // → "not_found"
	Exited,      // → "exited"   (attach on a dead session)
	Internal,    // → "internal"
}

@(private = "file")
_ERR_CODES := [Control_Err_Code]string{.Bad_Request = "bad_request", .Not_Found = "not_found", .Exited = "exited", .Internal = "internal"}
@(private = "file")
_PARSE_MESSAGES := [Control_Parse_Error]string{
	.None              = "",
	.Empty             = "empty request",
	.Unknown_Verb      = "unknown command",
	.Missing_Id        = "missing session id",
	.Bad_Id            = "invalid session id",
	.Missing_Direction = "missing split direction (right|down)",
	.Bad_Direction     = "invalid split direction (expected right|down)",
	.Extra_Args        = "too many arguments",
}

// control_parse_request parses one request line (no trailing '\n').
// Leading/trailing ASCII whitespace is trimmed; tokens are split on runs of ' '.
control_parse_request :: proc(line: string) -> (req: Control_Request, err: Control_Parse_Error) {
	s := strings.trim_space(line)
	if len(s) == 0 do return {}, .Empty

	pos := 0
	verb_token, _ := _next_token(s, &pos)
	verb, needs_id, verb_ok := _parse_verb(verb_token)
	if !verb_ok do return {}, .Unknown_Verb
	req.verb = verb

	if needs_id {
		id_token, has_id := _next_token(s, &pos)
		if !has_id do return {}, .Missing_Id
		id, id_ok := _parse_id(id_token)
		if !id_ok do return {}, .Bad_Id
		req.id = id
	} else if verb == .Split {
		dir_token, has_dir := _next_token(s, &pos)
		if !has_dir do return {}, .Missing_Direction
		switch dir_token {
		case "right", "horizontal", "h":
			req.split_dir = .Right
		case "down", "vertical", "v":
			req.split_dir = .Down
		case:
			return {}, .Bad_Direction
		}
		if id_token, has_id := _next_token(s, &pos); has_id {
			id, id_ok := _parse_id(id_token)
			if !id_ok do return {}, .Bad_Id
			req.id = id
		}
	} else if verb == .Tab {
		if id_token, has_id := _next_token(s, &pos); has_id {
			id, id_ok := _parse_id(id_token)
			if !id_ok do return {}, .Bad_Id
			req.id = id
		}
	} else if verb == .Quit {
		if opt_token, has_opt := _next_token(s, &pos); has_opt {
			switch opt_token {
			case "--force", "-f", "force", "--all", "-a":
				req.force = true
			case:
				return {}, .Extra_Args
			}
		}
	}
	if _, extra := _next_token(s, &pos); extra do return {}, .Extra_Args
	return req, .None
}

// control_format_request writes the canonical request line (no '\n') into buf.
control_format_request :: proc(req: Control_Request, buf: []u8) -> string {
	switch req.verb {
	case .Ping:   return fmt.bprintf(buf, "ping")
	case .Show:   return fmt.bprintf(buf, "show")
	case .Quit:
		if req.force do return fmt.bprintf(buf, "quit --force")
		return fmt.bprintf(buf, "quit")
	case .List:   return fmt.bprintf(buf, "ls")
	case .Attach: return fmt.bprintf(buf, "attach %d", req.id)
	case .Kill:   return fmt.bprintf(buf, "kill %d", req.id)
	case .Split:
		dir_str := "right" if req.split_dir == .Right else "down"
		if req.id > 0 do return fmt.bprintf(buf, "split %s %d", dir_str, req.id)
		return fmt.bprintf(buf, "split %s", dir_str)
	case .Tab:
		if req.id > 0 do return fmt.bprintf(buf, "tab %d", req.id)
		return fmt.bprintf(buf, "tab")
	}
	return ""
}

control_write_ok :: proc(b: ^strings.Builder) {
	_ = fmt.sbprintf(b, "ok\n")
}

// control_write_err writes "err <code> <message>\n"; '\n'/'\r' in message → ' '.
control_write_err :: proc(b: ^strings.Builder, code: Control_Err_Code, message: string) {
	_ = fmt.sbprintf(b, "err %s", _ERR_CODES[code])
	if len(message) > 0 {
		strings.write_byte(b, ' ')
		_write_sanitized(b, message)
	}
	strings.write_byte(b, '\n')
}

// control_parse_error_message returns a short human message for err.
control_parse_error_message :: proc(err: Control_Parse_Error) -> string {
	return _PARSE_MESSAGES[err]
}

// control_split_reply splits a full reply. ok = head line is exactly "ok";
// otherwise code/message come from "err <code> <message>" (message may be
// empty). body is everything after the first '\n'. well_formed = false when
// the head is neither form or there is no '\n'. All strings alias reply.
control_split_reply :: proc(reply: string) -> (ok: bool, code, message, body: string, well_formed: bool) {
	nl := strings.index_byte(reply, '\n')
	if nl < 0 do return false, "", "", "", false

	head := reply[:nl]
	body = reply[nl + 1:]
	if head == "ok" do return true, "", "", body, true
	if !strings.has_prefix(head, "err ") do return false, "", "", body, false

	rest := head[4:]
	sep := strings.index_byte(rest, ' ')
	if sep < 0 do return false, rest, "", body, true
	return false, rest[:sep], rest[sep + 1:], body, true
}

@(private = "file")
_next_token :: proc(s: string, pos: ^int) -> (token: string, ok: bool) {
	i := pos^
	for i < len(s) && s[i] == ' ' do i += 1
	if i >= len(s) {
		pos^ = i
		return "", false
	}
	start := i
	for i < len(s) && s[i] != ' ' do i += 1
	pos^ = i
	return s[start:i], true
}

@(private = "file")
_parse_verb :: proc(token: string) -> (verb: Control_Verb, needs_id: bool, ok: bool) {
	switch token {
	case "ping":   return .Ping, false, true
	case "show":   return .Show, false, true
	case "quit":   return .Quit, false, true
	case "ls":     return .List, false, true
	case "attach": return .Attach, true, true
	case "kill":   return .Kill, true, true
	case "split":  return .Split, false, true
	case "tab":    return .Tab, false, true
	}
	return {}, false, false
}

@(private = "file")
_parse_id :: proc(s: string) -> (id: u32, ok: bool) {
	if len(s) == 0 do return 0, false
	value: u64 = 0
	for i in 0..<len(s) {
		c := s[i]
		if c < '0' || c > '9' do return 0, false
		digit := u64(c - '0')
		if value > (u64(0xFFFF_FFFF) - digit) / 10 do return 0, false
		value = value * 10 + digit
	}
	if value == 0 do return 0, false
	return u32(value), true
}

@(private = "file")
_write_sanitized :: proc(b: ^strings.Builder, s: string) {
	start := 0
	for i in 0..<len(s) {
		c := s[i]
		if c != '\t' && c != '\n' && c != '\r' do continue
		if i > start do strings.write_string(b, s[start:i])
		strings.write_byte(b, ' ')
		start = i + 1
	}
	if start < len(s) do strings.write_string(b, s[start:])
}

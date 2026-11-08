package feature_session_core

// The broker in the core: the shell adapter's inputs (OSC 133 edges, what a
// person types, the command's output), session ends, deadlines, and
// core_broker_apply, which carries out the effects of every broker call.

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import terminal "../../core/terminal"
import proto "../session_proto"

// core_broker_shell_edges feeds a session's OSC 133 edges to the broker.
core_broker_shell_edges :: proc(c: ^Core, s: ^Core_Session, e: Shell_Edges) {
	p := &s.sess.term.parser
	if e.started {
		broker_shell_started(&c.broker, s.id)
		core_broker_apply(c)
	}
	if e.finished {
		broker_shell_done(&c.broker, s.id, p.last_cmd_exit if p.has_cmd_exit else 0, _shell_output(c, s))
		core_broker_apply(c)
	}
	if e.prompted {
		broker_shell_ready(&c.broker, s.id)
		core_broker_apply(c)
	}
}

// core_broker_human_input: a person typed into s (a window, or `send`).
core_broker_human_input :: proc(c: ^Core, s: ^Core_Session, typed: []u8) {
	p := _party_find(&c.broker, s.id)
	if p == nil || p.shell < 0 do return // the shell adapter runs nothing here: the common case
	broker_human_input(&c.broker, s.id, core_human_kind(typed), _shell_output(c, s, to_cursor = true))
	core_broker_apply(c)
}

core_broker_session_gone :: proc(c: ^Core, id: u32, exit_code: i32) {
	broker_session_gone(&c.broker, id, exit_code)
	core_broker_apply(c)
}

core_broker_tick :: proc(c: ^Core, now: i64) {
	broker_tick(&c.broker, now)
	core_broker_apply(c)
}

// core_shell_readiness: what the parser says about typing a command now.
core_shell_readiness :: proc(s: ^Core_Session) -> Shell_Readiness {
	p := &s.sess.term.parser
	switch {
	case s.endpoint.used: return .None // no program: only workers (`next --as`) take its requests
	case terminal.terminal_in_alt_screen(&s.sess.term): return .Busy
	case p.prompt_state == .Input || p.prompt_state == .Prompt: return .Ready
	case p.prompt_state == .Executing: return .Busy
	case p.cmd_seq == 0 && _now_unix() - s.started_unix < BROKER_START_MS / 1000: return .Starting
	}
	return .None
}

// core_broker_apply carries out the effects of the last broker call.
core_broker_apply :: proc(c: ^Core) {
	b := &c.broker
	for e in b.effects[:b.n_effects] {
		r := &b.reqs[max(e.req, 0)] // read only by the effects that name a request
		s := core_session_find(c, e.sid)
		switch e.kind {
		case .Inject:
			if s != nil do _type(c, s, broker_body(r))
		case .Interrupt:
			if s == nil || s.exited do continue
			sig := _i32_bytes(i32(posix.Signal.SIGINT))
			core_holder_send(c, s.holder, proto.MSG_SIGNAL, s.id, sig[:])
		case .Assign:   core_reply_request(c, e.viewer, r)
		case .Result:   core_reply_result(c, e.viewer, r, .Finished)
		case .Progress: core_reply_result(c, e.viewer, r, .Progress)
		case .Expired:
			if _viewer_ok(c, e.viewer) do core_viewer_fail(c, e.viewer, 0, .Timeout, "timed out")
		case .Gone:
			if _viewer_ok(c, e.viewer) do core_viewer_fail(c, e.viewer, 0, .Not_Found, "the session ended")
		case .Row:
			if s != nil do core_row_changed(c, s)
		}
	}
	b.n_effects = 0
	c.broker_due_ns = broker_next_due(b)
}

@(private)
_viewer_ok :: proc(c: ^Core, vi: int) -> bool {
	return vi >= 0 && vi < CORE_MAX_VIEWERS && c.viewers[vi].used
}

// _type writes a command (the broker dropped its control bytes) and Enter.
@(private = "file")
_type :: proc(c: ^Core, s: ^Core_Session, text: string) {
	if s.exited do return
	clear(&c.typed)
	append(&c.typed, text)
	append(&c.typed, '\r')
	core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, c.typed[:])
}

// _shell_output is the text of the command s's shell adapter runs ("" when it
// runs none); the core's text buffer holds it until the next read.
@(private = "file")
_shell_output :: proc(c: ^Core, s: ^Core_Session, to_cursor := false) -> string {
	p := _party_find(&c.broker, s.id)
	if p == nil || p.shell < 0 do return ""
	clear(&c.text)
	b := strings.Builder{buf = c.text}
	ok, head_lost := terminal.terminal_cmd_output(&s.sess.term, &b, to_cursor)
	c.text = b.buf
	if !ok do return ""
	if head_lost do return fmt.tprintf("[… earlier output left the scrollback]\n%s", string(c.text[:]))
	return string(c.text[:])
}

// core_human_kind: ^C or Esc (also as kitty-keyboard CSI 99;5u / CSI 27u or
// modifyOtherKeys CSI 27;5;99~) stops what runs; any other input takes over.
core_human_kind :: proc(typed: []u8) -> Human_Input {
	s := string(typed)
	switch {
	case strings.index_byte(s, 0x03) >= 0, s == "\x1b", strings.has_prefix(s, "\x1b[27;5;99~"):
		return .Interrupt
	case len(s) > 3 && strings.has_prefix(s, "\x1b[") && s[len(s) - 1] == 'u':
		key, _, mods := strings.partition(s[2:len(s) - 1], ";")
		mod, _, _ := strings.partition(mods, ":")
		if key == "27" || (key == "99" && mod == "5") do return .Interrupt
	}
	return .Other
}

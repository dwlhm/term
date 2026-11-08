package feature_session_core

// Event watches (`term session watch`): a viewer is answered once on the next
// shell-integration edge (OSC 133) or exit.

import proto "../session_proto"
import ipc "../../platform/ipc"

CORE_MAX_WATCHERS :: 32

Core_Watcher :: struct {
	used:           bool,
	target_sess_id: u32,
	req:            ipc.Request,
	events:         proto.Watch_Event_Flags,
	due_ns:         i64,
}

// core_viewer_watch answers at once when the event already happened (exit,
// or a command finished after `since`), otherwise registers a watcher.
core_viewer_watch :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Watch_Request
	if !ipc.request_decode(req, &m, proto.dec_watch_req) do return
	if m.events == {} {
		core_viewer_fail(c, req, .Bad_Request, "a watch needs an event")
		return
	}
	s := _target(c, req, m.id, false)
	if s == nil do return
	w := Core_Watcher{
		used           = true,
		target_sess_id = m.id,
		req            = req^,
		events         = m.events,
		due_ns         = (_now() + i64(m.timeout_ms) * 1_000_000) if m.timeout_ms > 0 else 0,
	}
	// An exited target never changes again: every watch ends now.
	if s.exited {
		_watch_fire(c, &w, s, .Exit)
		return
	}
	if .Prompt in m.events && m.has_since && s.sess.term.parser.cmd_seq > m.since {
		_watch_fire(c, &w, s, .Prompt)
		return
	}
	for &slot in c.watchers {
		if slot.used do continue
		slot = w
		return
	}
	core_viewer_fail(c, req, .Busy, "too many active watchers")
}

Shell_Edges :: struct {
	started:  bool, // a command started (also one that ended in the same chunk)
	finished: bool, // 133;D moved cmd_seq
	prompted: bool, // a prompt appeared after none or a command
}

// core_shell_edges reads the OSC 133 edges the last output produced. A fast
// command's start and end can arrive in one chunk: the state looks unchanged
// but cmd_seq moved.
core_shell_edges :: proc(s: ^Core_Session) -> (e: Shell_Edges) {
	p := &s.sess.term.parser
	prev, curr := s.last_prompt_state, proto.Prompt_State(p.prompt_state)
	ran := p.cmd_seq != s.last_cmd_seq
	if prev == curr && !ran do return
	s.last_prompt_state, s.last_cmd_seq = curr, p.cmd_seq
	at_prompt := curr == .Prompt || curr == .Input
	e.started = (curr == .Executing && prev != .Executing) || (ran && prev != .Executing)
	e.finished = ran
	e.prompted = at_prompt && (prev == .None || prev == .Executing)
	return
}

// core_watch_output fires the watches the edges answer (Prompt = a command
// finished or a prompt appeared).
core_watch_output :: proc(c: ^Core, s: ^Core_Session, e: Shell_Edges) {
	if e.started do core_watch_trigger(c, s, .Executing)
	if e.finished || e.prompted do core_watch_trigger(c, s, .Prompt)
}

// core_watch_trigger answers the watchers of s waiting for event (Exit ends all).
core_watch_trigger :: proc(c: ^Core, s: ^Core_Session, event: proto.Watch_Event) {
	for &w in c.watchers {
		if !w.used || w.target_sess_id != s.id do continue
		if event not_in w.events && event != .Exit do continue
		_watch_fire(c, &w, s, event)
		w = {}
	}
}

// core_watch_target_gone ends the watches of a session being removed (killed:
// there is no exit code to report).
core_watch_target_gone :: proc(c: ^Core, s: ^Core_Session) {
	for &w in c.watchers {
		if !w.used || w.target_sess_id != s.id do continue
		core_viewer_fail(c, &w.req, .Not_Found, "session was removed")
		w = {}
	}
}

// core_watchers_due fails watchers whose deadline passed.
core_watchers_due :: proc(c: ^Core, now: i64) {
	for &w in c.watchers {
		if !w.used || w.due_ns == 0 || now < w.due_ns do continue
		core_viewer_fail(c, &w.req, .Timeout, "watch timed out")
		w = {}
	}
}

// core_watchers_cancel_viewer drops a disconnected viewer's watches.
core_watchers_cancel_viewer :: proc(c: ^Core, peer: ipc.Peer) {
	for &w in c.watchers do if w.used && w.req.peer == peer do w = {}
}

@(private = "file")
_watch_fire :: proc(c: ^Core, w: ^Core_Watcher, s: ^Core_Session, event: proto.Watch_Event) {
	p := &s.sess.term.parser
	res := proto.Watch_Result{
		id           = s.id,
		event        = event,
		exit_code    = s.exit.code if event == .Exit else (p.last_cmd_exit if p.has_cmd_exit else 0),
		prompt_state = proto.Prompt_State(p.prompt_state),
		cmd_seq      = p.cmd_seq,
	}
	msg := ipc.wire_writer(c.msg)
	proto.enc_watch_result(&msg, res)
	ipc.reply(&c.srv, w.req, ipc.wire_bytes_written(&msg))
}

package feature_session_core

// Session lifecycle in the core: create/adopt, program output, exit, kill.

import "core:sys/posix"
import terminal "../../core/terminal"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

core_session_find :: proc(c: ^Core, id: u32) -> ^Core_Session {
	for &s in c.sessions do if s.used && s.id == id do return &s
	return nil
}

core_session_count :: proc(c: ^Core) -> int {
	n := 0
	for &s in c.sessions do if s.used do n += 1
	return n
}

// _session_new allocates the Terminal for id; its link goes to the session's holder.
@(private)
_session_new :: proc(c: ^Core, id: u32, holder: int, size: proto.Size_Msg) -> ^Core_Session {
	for &s in c.sessions {
		if s.used do continue
		s = {used = true, id = id, holder = holder, started_unix = _now_unix(), output_ns = _now()}
		s.link = {core = c, id = id}
		// The core's own Terminal has no typist: its replies and writes both go to the program.
		s.sess = session.session_create(size, {write = _link_write, reply = _link_write, resize = _link_resize, user = &s.link})
		c.next_id = max(c.next_id, id + 1)
		return &s
	}
	return nil
}

@(private = "file")
_link_write :: proc(user: rawptr, data: []u8) {
	l := (^Core_Link)(user)
	if s := core_session_find(l.core, l.id); s != nil && !s.exited {
		core_holder_send(l.core, s.holder, proto.MSG_INPUT, s.id, data)
	}
}

@(private = "file")
_link_resize :: proc(user: rawptr, size: proto.Size_Msg) {
	l := (^Core_Link)(user)
	s := core_session_find(l.core, l.id)
	if s == nil || s.exited do return
	b: [8]u8
	w := ipc.wire_writer(b[:])
	proto.enc_size(&w, size)
	core_holder_send(l.core, s.holder, proto.MSG_RESIZE, s.id, ipc.wire_bytes_written(&w))
}

// core_session_create asks the current holder to start spec as a new session.
core_session_create :: proc(c: ^Core, spec_payload: []u8, size: proto.Size_Msg) -> ^Core_Session {
	hi := core_current_holder(c)
	if hi < 0 && core_start_holder(c) do hi = core_current_holder(c)
	if hi < 0 do return nil
	s := _session_new(c, c.next_id, hi, size)
	if s == nil do return nil
	core_holder_send(c, hi, proto.MSG_SPAWN, s.id, spec_payload)
	core_broadcast_row(c, s)
	return s
}

// core_session_adopt takes over a session a holder already runs.
core_session_adopt :: proc(c: ^Core, hi: int, held: proto.Held_Session) {
	if core_session_find(c, held.id) != nil {
		// Two holders claim one id: it can't be addressed, end the newcomer's.
		core_holder_send(c, hi, proto.MSG_RELEASE, held.id)
		return
	}
	s := _session_new(c, held.id, hi, held.size)
	if s == nil do return
	s.started_unix = held.started_unix
	s.sess.info.pid = i32(held.pid)
	if held.exited do core_session_exited(c, s, held.exit, "")
}

// core_session_adopt_tail rebuilds the screen: from the planned-restart
// snapshot plus the tail since (output nobody answered yet: its replies go to
// the program), or from the tail alone after a crash (its replies were sent
// long ago: dropped) followed by a size nudge so full-screen programs repaint.
core_session_adopt_tail :: proc(c: ^Core, s: ^Core_Session, tail: []u8) {
	h := &c.holders[s.holder] if s.holder >= 0 else nil
	// A tail that keeps crashing cores is skipped: programs keep running, their screens start empty.
	if h != nil && h.poisoned do return
	exact := core_restore_snapshot(c, s)
	clear(&c.viewer_out)
	clear(&c.replies)
	terminal.relay_feed(&s.relay, &s.sess.term, tail, &c.viewer_out, &c.replies)
	terminal.relay_flush(&s.relay, &s.sess.term)
	for terminal.terminal_drain_response(&s.sess.term, c.msg[:4096]) > 0 {}
	_ = terminal.terminal_consume_damage(&s.sess.term)
	// A viewer can attach between WELCOME (empty screen) and this tail.
	core_attach_repaint(c, s)
	if exact && h != nil && h.handover && len(c.replies) > 0 && !s.exited {
		core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, c.replies[:])
	}
	if s.exited || exact do return
	size := proto.Size_Msg{cols = u16(s.sess.term.cols), rows = u16(s.sess.term.rows)}
	nudge := size
	nudge.rows = max(1, size.rows - 1)
	_link_resize(&s.link, nudge)
	_link_resize(&s.link, size)
}

core_session_output :: proc(c: ^Core, s: ^Core_Session, bytes: []u8) {
	clear(&c.viewer_out)
	clear(&c.replies)
	terminal.relay_feed(&s.relay, &s.sess.term, bytes, &c.viewer_out, &c.replies)
	_ = terminal.terminal_consume_damage(&s.sess.term)
	if len(c.replies) > 0 do core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, c.replies[:])
	if s.stitch != nil && s.stitch.active {
		// A stitch is scrolling this screen: the viewers get one repaint at the
		// end instead of every intermediate page.
		s.stitch.last_out_ns = _now()
	} else {
		for &a in s.attaches do if a.used do core_attach_push(c, s, &a, c.viewer_out[:])
	}
	// A command starting or ending prints something: look at the foreground (and
	// resync viewers that skipped output) once it settles.
	s.output_ns = _now()
	s.gen += 1
	s.settle_due_ns = s.output_ns + CORE_SETTLE_MS * 1_000_000
	edges := core_shell_edges(s)
	if edges.prompted || s.sess.term.parser.prompt_state == .Prompt {
		s.prompt_gen = s.gen
	}
	if u8(s.sess.program_status.state) != s.last_status_state {
		s.last_status_state = u8(s.sess.program_status.state)
		s.status_gen = s.gen
	}
	core_watch_output(c, s, edges)
	core_broker_shell_edges(c, s, edges)
	core_row_changed(c, s)
}

// core_settle_due handles sessions whose output settled: stale viewers get
// their history, and the holder is asked for the foreground process.
core_settle_due :: proc(c: ^Core, now: i64) {
	for &s in c.sessions {
		if !s.used || s.settle_due_ns == 0 || now < s.settle_due_ns do continue
		s.settle_due_ns = now + CORE_SETTLE_MS * 1_000_000 if core_attach_resync(c, &s) else 0
		if s.exited || s.proc_pending do continue
		s.proc_pending = true
		core_holder_send(c, s.holder, proto.MSG_PROC_QUERY, s.id)
	}
}

core_session_spawned :: proc(c: ^Core, s: ^Core_Session, pid: i32, started_unix: i64) {
	s.sess.info.pid = pid
	if started_unix > 0 do s.started_unix = started_unix
	core_broadcast_row(c, s)
}

core_session_exited :: proc(c: ^Core, s: ^Core_Session, exit: proto.Exit_Msg, reason: string) {
	if s.exited do return
	s.exited, s.exit = true, exit
	s.sess.info.alive, s.sess.info.exit_code = false, int(exit.code)
	core_holder_send(c, s.holder, proto.MSG_RELEASE, s.id)
	for &a in s.attaches {
		if !a.used do continue
		if len(reason) > 0 do ipc.server_stream_close(&c.srv, a.peer, a.channel, reason)
		else do ipc.server_stream_finish(&c.srv, a.peer, a.channel)
		a = {}
	}
	core_watch_trigger(c, s, .Exit)
	core_broker_session_gone(c, s.id, exit.code)
	core_lease_session_ended(c, s, false)
	core_broadcast_row(c, s)
}

core_session_proc_info :: proc(c: ^Core, s: ^Core_Session, info: proto.Proc_Info_Msg) {
	s.proc_pending = false
	session.session_set_info(s.sess, s.sess.info.pid, info.pgid, s.sess.info.alive, s.sess.info.exit_code, info.name, info.cwd)
	core_row_changed(c, s)
}

// core_session_kill ends the program (the holder hangs up its process group)
// and forgets the session.
core_session_kill :: proc(c: ^Core, s: ^Core_Session) {
	hup := _i32_bytes(i32(posix.Signal.SIGHUP))
	if !s.exited do core_holder_send(c, s.holder, proto.MSG_SIGNAL, s.id, hup[:])
	core_holder_send(c, s.holder, proto.MSG_RELEASE, s.id)
	core_stitch_abort(c, s)
	for &a in s.attaches do if a.used do ipc.server_stream_close(&c.srv, a.peer, a.channel, "killed")
	id := s.id
	core_watch_target_gone(c, s)
	core_broker_session_gone(c, id, s.exit.code)
	core_lease_session_ended(c, s, true)
	core_session_free(c, s)
	b := _i32_bytes(i32(id))
	ipc.notify(&c.srv, ipc.Notify_All{}, proto.MSG_REMOVED, b[:])
}

core_session_free :: proc(c: ^Core, s: ^Core_Session) {
	core_stitch_free(s)
	delete(s.lease.held) // a lease still open when the session goes
	for r in s.ref_table do delete(r.text)
	delete(s.ref_table)
	if s.sess != nil do session.session_destroy(s.sess)
	s^ = {}
}

@(private)
_i32_bytes :: proc(v: i32) -> [4]u8 {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_i32(&w, v)
	return b
}

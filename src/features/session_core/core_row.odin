package feature_session_core

// Session rows for viewers and the CLI: LIST (with fresh foreground info from
// the holders) and EVENT whenever a row's visible facts change.

import "core:hash"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"
import extension "../../core/terminal/extension"

// core_row_get: the row's title may be written into title_buf, which must
// outlive the row.
core_row_get :: proc(c: ^Core, s: ^Core_Session, title_buf: []u8) -> proto.Session_Row {
	sess := s.sess
	title := session.session_resolve_title(sess, title_buf, "Shell")
	active := !s.exited && session.session_is_running_job(sess)
	state: proto.Session_State = .Exited if s.exited else (.Busy if active else .Idle)
	attached := false
	for &a in s.attaches do attached ||= a.used && !a.observe
	process := session.session_process_name(sess)
	if len(process) == 0 && sess.program_status.app_len > 0 do process = extension.program_status_app(&sess.program_status)
	p := &sess.term.parser if sess != nil else nil
	cmd_seq := p.cmd_seq if p != nil else 0
	last_cmd_exit := p.last_cmd_exit if p != nil else 0
	has_cmd_exit := p.has_cmd_exit if p != nil else false
	return {
		id              = s.id,
		state           = state,
		active          = active,
		attached        = attached,
		pid             = u32(max(sess.info.pid, 0)),
		elapsed_s       = u32(max(i64(0), _now_unix() - s.started_unix)) if s.started_unix > 0 else 0,
		quiet_s         = u32(max(i64(0), _now() - s.output_ns) / 1_000_000_000),
		exit_code       = s.exit.code,
		cols            = u16(sess.term.grid.col_count) if sess != nil else 0,
		rows            = u16(sess.term.grid.row_count) if sess != nil else 0,
		cmd_seq         = cmd_seq,
		last_cmd_exit   = last_cmd_exit,
		has_cmd_exit    = has_cmd_exit,
		name            = core_session_name(s),
		process         = process,
		cwd             = session.session_get_cwd_path(sess) if sess.cwd_len > 0 else session.session_process_cwd(sess),
		title           = title,
		status          = extension.program_status_msg(&sess.program_status),
		controller      = core_lease_owner(s),
		controller_pass = s.lease.used && s.lease.pass,
	}
}

core_row_write :: proc(w: ^ipc.Wire_Writer, c: ^Core, s: ^Core_Session) {
	title_buf: [256]u8
	proto.enc_row(w, core_row_get(c, s, title_buf[:]))
}

// core_row_changed broadcasts an EVENT when what a row shows changed
// (elapsed time is not part of it).
core_row_changed :: proc(c: ^Core, s: ^Core_Session) {
	w := ipc.wire_writer(c.msg)
	core_row_write(&w, c, s)
	row := ipc.wire_bytes_written(&w)
	// pid … elapsed_s start after id(4) state(1) active(1) attached(1) pid(4);
	// skip elapsed_s and quiet_s (4 + 4): clocks, not facts that changed.
	h := hash.fnv64a(row[:11]) ~ hash.fnv64a(row[19:])
	if h == s.row_hash do return
	s.row_hash = h
	_broadcast(c, proto.MSG_EVENT, row)
}

core_broadcast_row :: proc(c: ^Core, s: ^Core_Session) {
	s.row_hash = 0
	core_row_changed(c, s)
}

@(private = "file")
_broadcast :: proc(c: ^Core, kind: u8, payload: []u8) {
	ipc.notify(&c.srv, ipc.Notify_All{}, kind, payload)
}

// core_list_request asks every live session's holder for its foreground
// process; the SESSIONS reply goes out when all answered or CORE_PROC_WAIT_MS passed.
core_list_request :: proc(c: ^Core, req: ^ipc.Request) {
	m: proto.Empty_Request
	if !ipc.request_decode(req, &m, proto.dec_empty) do return
	slot: ^Core_List
	for &l in c.lists do if !l.used { slot = &l; break }
	if slot == nil {
		core_viewer_fail(c, req, .Busy, "too many session lists are being gathered")
		return
	}
	for &s in c.sessions {
		if !s.used || s.exited || s.proc_pending do continue
		s.proc_pending = true
		core_holder_send(c, s.holder, proto.MSG_PROC_QUERY, s.id)
	}
	slot^ = {used = true, req = req^, due_ns = _now() + CORE_PROC_WAIT_MS * 1_000_000}
	core_lists_due(c)
}

core_lists_due :: proc(c: ^Core) {
	pending := false
	for &s in c.sessions do pending ||= s.used && s.proc_pending && s.holder >= 0
	for &l in c.lists {
		if !l.used || (pending && _now() < l.due_ns) do continue
		_send_sessions(c, &l.req)
		l = {}
	}
}

@(private = "file")
_send_sessions :: proc(c: ^Core, req: ^ipc.Request) {
	w := ipc.wire_writer(c.msg)
	ipc.ww_u32(&w, u32(core_session_count(c)))
	for &s in c.sessions do if s.used do core_row_write(&w, c, &s)
	if w.ok do ipc.reply(&c.srv, req^, ipc.wire_bytes_written(&w))
	else do core_viewer_fail(c, req, .Busy, "the session rows do not fit in one answer")
}

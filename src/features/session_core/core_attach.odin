package feature_session_core

// Viewer attachments: first paint, live bytes, repaint after overflow (and
// the history resync once output settles), and the size owner (the most
// recently active attachment that is not observing).

import terminal "../../core/terminal"
import extension "../../core/terminal/extension"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

CORE_PAINT_HISTORY_MAX :: 10_000

// core_attach opens an attach channel to req's peer and answers ATTACHED
// before the first paint goes out on it. false = no free attach slot.
core_attach :: proc(c: ^Core, s: ^Core_Session, req: ^ipc.Request, m: proto.Attach_Msg) -> bool {
	slot := -1
	for &a, i in s.attaches do if !a.used { slot = i; break }
	if slot < 0 do return false
	channel, ok := ipc.server_stream_open(&c.srv, req.peer, true)
	if !ok do return false
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, s.id); ipc.ww_u32(&w, channel)
	ipc.reply(&c.srv, req^, b[:])
	a := &s.attaches[slot]
	history := int(min(m.history, CORE_PAINT_HISTORY_MAX))
	a^ = {used = true, observe = m.observe, peer = req.peer, channel = channel, size = m.size, active_ns = _now(), history = history}
	core_apply_leader(c, s)
	_attach_paint(c, s, a, history)
	if a.recovering do _attach_stale(s, a) // the paint waits for ground and goes out without history
	return true
}

core_attach_find :: proc(c: ^Core, peer: ipc.Peer, channel: u32) -> (^Core_Session, ^Core_Attach) {
	for &s in c.sessions {
		if !s.used do continue
		for &a in s.attaches do if a.used && a.peer == peer && a.channel == channel do return &s, &a
	}
	return nil, nil
}

core_detach :: proc(c: ^Core, s: ^Core_Session, a: ^Core_Attach, notify: bool) {
	if notify do ipc.server_stream_close(&c.srv, a.peer, a.channel)
	a^ = {}
	core_apply_leader(c, s)
	core_broadcast_row(c, s)
}

// core_attach_push sends live output, or a repaint once a viewer that fell
// behind can take one (the parser is at ground: no half sequence in flight).
core_attach_push :: proc(c: ^Core, s: ^Core_Session, a: ^Core_Attach, bytes: []u8) {
	if !a.recovering {
		if ipc.server_stream_data(&c.srv, a.peer, a.channel, bytes) do return
		a.recovering = true
		_attach_stale(s, a)
	}
	if terminal.terminal_parser_at_ground(&s.sess.term) do _attach_paint(c, s, a, 0)
}

@(private = "file")
_attach_paint :: proc(c: ^Core, s: ^Core_Session, a: ^Core_Attach, history: int) {
	if !terminal.terminal_parser_at_ground(&s.sess.term) {
		a.recovering = true
		return
	}
	hist := history
	for {
		terminal.terminal_paint(&s.sess.term, &c.paint, hist)
		if len(c.paint) <= ipc.STREAM_MAX_PENDING / 2 || hist == 0 do break
		hist /= 2
	}
	// The screen does not keep OSC 7501; the session does. A new viewer needs the latest report too.
	extension.osc_7501_encode(&s.sess.program_status, &c.paint)
	// A paint that does not fit behind the backlog has the backlog dropped
	// (server_stream_data false): it then goes alone, replacing it.
	ok := ipc.server_stream_data(&c.srv, a.peer, a.channel, c.paint[:])
	if !ok do ok = ipc.server_stream_data(&c.srv, a.peer, a.channel, c.paint[:])
	a.recovering = !ok
}

// core_attach_touch: typing, resizing or focusing makes an attachment the size owner.
core_attach_touch :: proc(c: ^Core, s: ^Core_Session, a: ^Core_Attach) {
	if a.observe do return
	a.active_ns = _now()
	core_apply_leader(c, s)
}

core_apply_leader :: proc(c: ^Core, s: ^Core_Session) {
	leader: ^Core_Attach
	for &a in s.attaches {
		if a.used && !a.observe && (leader == nil || a.active_ns > leader.active_ns) do leader = &a
	}
	if leader == nil || leader.size.cols == 0 || leader.size.rows == 0 do return
	t := &s.sess.term
	if int(leader.size.cols) == t.cols && int(leader.size.rows) == t.rows do return
	session.session_resize(s.sess, leader.size.cols, leader.size.rows, leader.size.xpixel, leader.size.ypixel)
	s.gen += 1 // the screen reflowed
	_ = terminal.terminal_consume_damage(t)
}

// core_attach_repaint gives every viewer of a session one fresh paint after
// its screen changed without live frames (a stitch held them back, a tail was
// adopted); their history follows once output settles.
core_attach_repaint :: proc(c: ^Core, s: ^Core_Session) {
	for &a in s.attaches {
		if !a.used do continue
		_attach_paint(c, s, &a, 0)
		_attach_stale(s, &a)
	}
}

// core_attach_resync repaints every stale viewer with the history it asked
// for, replacing its scrollback. true = one is still stale (its paint waits
// for the parser to reach ground): try again at the next settle.
core_attach_resync :: proc(c: ^Core, s: ^Core_Session) -> (retry: bool) {
	for &a in s.attaches {
		if !a.used || !a.stale do continue
		_attach_paint(c, s, &a, a.history)
		a.stale = a.recovering
		retry ||= a.stale
	}
	return
}

// _attach_stale: the viewer missed output its scrollback should have; output
// settling resyncs it (a viewer that asked for no history has nothing to fix).
@(private = "file")
_attach_stale :: proc(s: ^Core_Session, a: ^Core_Attach) {
	if a.history == 0 do return
	a.stale = true
	if s.settle_due_ns == 0 do s.settle_due_ns = _now() + CORE_SETTLE_MS * 1_000_000
}

// core_attach_input handles a viewer frame on an attach channel (CLOSE = detach).
core_attach_input :: proc(c: ^Core, f: ipc.Stream_Input) {
	s, a := core_attach_find(c, f.peer, f.channel)
	if s == nil do return
	r := ipc.wire_reader(f.body)
	switch f.kind {
	case proto.MSG_V_INPUT:
		// The typist owns the size first: its input is read at its size.
		core_attach_touch(c, s, a)
		s.input_gen = s.gen
		if core_lease_human_input(c, s, f.body) do return // held for the automation
		core_broker_human_input(c, s, f.body)
		if core_stitch_hold(s, f.body) do return // delivered when the stitch ends
		if !s.exited do core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, f.body)
	case proto.MSG_V_TAKEOVER:
		core_lease_takeover(c, s)
	case proto.MSG_V_REPLY:
		if core_stitch_hold(s, f.body) do return
		if !s.exited do core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, f.body)
	case proto.MSG_V_RESIZE:
		size := proto.dec_size(&r)
		if !ipc.wr_done(&r) || size.cols == 0 || size.rows == 0 do return
		a.size = size
		core_attach_touch(c, s, a)
	case proto.MSG_V_FOCUS:
		focused := ipc.wr_bool(&r)
		core_attach_touch(c, s, a)
		if r.ok && s.sess.term.parser.report_focus && !a.observe {
			core_holder_send(c, s.holder, proto.MSG_INPUT, s.id, transmute([]u8)string("\x1b[I" if focused else "\x1b[O"))
		}
	case proto.MSG_V_FACTS:
		facts := proto.dec_facts(&r)
		if ipc.wr_done(&r) && facts.cell_w > 0 && facts.cell_h > 0 {
			terminal.terminal_set_cell_size(&s.sess.term, int(facts.cell_w), int(facts.cell_h))
		}
	case ipc.STREAM_CLOSE:
		core_detach(c, s, a, false)
	}
}

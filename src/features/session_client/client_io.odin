package feature_session_client

// The IO thread: send the queued ops, then wait in client_poll (woken by
// client_interrupt when the UI queues more) and route what comes: DATA to
// session inboxes, answers and notices to the event queue.

import "core:sync"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

@(private)
_io_main :: proc(data: rawptr) {
	c := (^Client)(data)
	for !sync.atomic_load(&c.stopping) && !sync.atomic_load(&c.overflow) {
		_io_ops(c)
		ev, err := ipc.client_poll(&c.link, ipc.WAIT_FOREVER)
		if err.kind == .Interrupted do continue
		if err.kind != .None || !_io_event(c, ev) do break
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&c.broken, !sync.atomic_load(&c.stopping))
	if c.wake != nil do c.wake(c.wake_data)
}

// _io_settle runs on the closing thread once the IO thread stopped: it sends
// what is queued and answers the core's replies to released-but-pending links
// (their KILL/CLOSE), so nothing a released pane started is left behind.
@(private)
_io_settle :: proc(c: ^Client, deadline_ns: i64) {
	_io_ops(c)
	for time.tick_now()._nsec < deadline_ns {
		cancelled := false
		for &l in c.links do cancelled ||= l.cancelled
		if !cancelled do return
		ev, err := ipc.client_poll(&c.link, time.Duration(deadline_ns - time.tick_now()._nsec))
		if err.kind != .None || !_io_event(c, ev) do return
		_io_ops(c)
	}
}

// _io_ops sends every queued op.
@(private)
_io_ops :: proc(c: ^Client) {
	for {
		sync.mutex_lock(&c.mutex)
		kind, key, body, ok := _rec_pop(&c.ops, c.io_buf)
		if ok do _io_op(c, _Op(kind), _link_of_key(c, key), body)
		sync.mutex_unlock(&c.mutex)
		if !ok do return
	}
}

// _io_op sends one op (c.mutex held).
@(private = "file")
_io_op :: proc(c: ^Client, op: _Op, l: ^Client_Link, body: []u8) {
	r := ipc.wire_reader(body)
	switch op {
	case .Create, .Attach:
		if l == nil do return // released before the IO thread got to it
		kind := proto.MSG_CREATE if op == .Create else proto.MSG_ATTACH
		tk, err := ipc.client_start(&c.link, kind, body)
		if err.kind == .None do l.ticket = tk
		else do _link_failed(c, l, .Busy, proto.error_text(err))
	case .Release:
		kill, id, channel := ipc.wr_bool(&r), ipc.wr_u32(&r), ipc.wr_u32(&r)
		_undo(c, kill, id, channel)
	case .Kill:
		_, _ = ipc.client_start(&c.link, proto.MSG_KILL, body)
	case .List:
		_, _ = ipc.client_start(&c.link, proto.MSG_LIST, nil)
	case .Stream:
		if l != nil && l.state == .Attached do _ = ipc.client_stream_send(&c.link, l.channel, body[0], body[1:])
	case .Ack:
		if l != nil && l.state == .Attached do ipc.client_stream_ack(&c.link, l.channel, int(ipc.wr_u32(&r)))
	}
}

// _undo ends what a released pane had: its program (kill) or its attachment.
@(private = "file")
_undo :: proc(c: ^Client, kill: bool, id, channel: u32) {
	if kill {
		b := _u32(id)
		_, _ = ipc.client_start(&c.link, proto.MSG_KILL, b[:])
	} else {
		_ = ipc.client_stream_send(&c.link, channel, ipc.STREAM_CLOSE, nil)
	}
}

// _io_event routes one event; false = the link to the core is unusable.
@(private)
_io_event :: proc(c: ^Client, ev: ipc.Client_Event) -> bool {
	ok := true
	sync.mutex_lock(&c.mutex)
	#partial switch e in ev {
	case ipc.Stream_Data:
		if l := _link_by_channel(c, e.channel); l != nil do ok = session.session_inbox_push(l.sess, e.bytes) // false: past its credit
	case ipc.Stream_End:
		if l := _link_by_channel(c, e.channel); l != nil do _emit(c, .Closed, _link_key(c, l), transmute([]u8)e.reason)
	case ipc.Late_Answer:
		_late_answer(c, e)
	case ipc.Notice:
		switch e.kind {
		case proto.MSG_EVENT:   _emit(c, .Row, _NO_LINK, e.body)
		case proto.MSG_REMOVED: _emit(c, .Removed, _NO_LINK, e.body)
		}
	}
	sync.mutex_unlock(&c.mutex)
	if c.wake != nil do c.wake(c.wake_data)
	return ok
}

// _late_answer: ATTACHED (or FAIL) for a link's CREATE/ATTACH, or the answer
// to a KILL/LIST, which has no link (c.mutex held).
@(private = "file")
_late_answer :: proc(c: ^Client, e: ipc.Late_Answer) {
	l := _link_by_ticket(c, e.ticket)
	r := ipc.wire_reader(e.answer.body)
	switch {
	case l != nil && e.err.kind != .None:
		code := proto.Fail_Code(e.err.code) if e.err.kind == .Failed else .Busy
		_link_failed(c, l, code, proto.error_text(e.err))
	case l != nil:
		_bind(c, l, ipc.wr_u32(&r), ipc.wr_u32(&r))
	case e.err.kind != .None:
		code := proto.Fail_Code(e.err.code) if e.err.kind == .Failed else .Busy
		_emit(c, .Failed, _NO_LINK, []u8{u8(code)}, transmute([]u8)proto.error_text(e.err))
	case e.answer.kind == proto.MSG_SESSIONS:
		_emit(c, .Sessions, _NO_LINK, e.answer.body)
	case:
		_emit(c, .Ok, _NO_LINK)
	}
}

// _bind maps the channel (before any DATA on it is read), then sends the
// size and the input held while the link was pending (c.mutex held).
@(private = "file")
_bind :: proc(c: ^Client, l: ^Client_Link, id, channel: u32) {
	l.ticket = 0
	if l.cancelled {
		_undo(c, l.cancel_kill, id, channel)
		l^ = {gen = l.gen}
		return
	}
	l.id, l.channel, l.state = id, channel, .Attached
	// The size first: held input then reaches a program that already has it.
	if size, resized := l.pending_size.?; resized do _send_size(c, l, size)
	l.pending_size = nil
	if l.pending_len > 0 do _ = ipc.client_stream_send(&c.link, channel, proto.MSG_V_INPUT, l.pending[:l.pending_len])
	l.pending_len = 0
	_emit(c, .Attached, _link_key(c, l))
}

// _link_failed: a released link is just freed, a shown one hears why (c.mutex held).
@(private = "file")
_link_failed :: proc(c: ^Client, l: ^Client_Link, code: proto.Fail_Code, reason: string) {
	if l.cancelled {
		l^ = {gen = l.gen}
		return
	}
	l.ticket = 0
	_emit(c, .Failed, _link_key(c, l), []u8{u8(code)}, transmute([]u8)reason)
}

@(private = "file")
_send_size :: proc(c: ^Client, l: ^Client_Link, size: proto.Size_Msg) {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	proto.enc_size(&w, size)
	_ = ipc.client_stream_send(&c.link, l.channel, proto.MSG_V_RESIZE, ipc.wire_bytes_written(&w))
}

@(private)
_link_by_channel :: proc(c: ^Client, channel: u32) -> ^Client_Link {
	for &l in c.links do if l.state == .Attached && l.channel == channel do return &l
	return nil
}

@(private = "file")
_link_by_ticket :: proc(c: ^Client, tk: ipc.Ticket) -> ^Client_Link {
	if tk == 0 do return nil
	for &l in c.links do if l.state != .Free && l.ticket == tk do return &l
	return nil
}

@(private)
_u32 :: proc(v: u32) -> [4]u8 {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, v)
	return b
}

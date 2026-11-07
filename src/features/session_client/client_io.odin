package feature_session_client

// The IO thread: read frames, route DATA to session inboxes, queue control
// frames for the UI thread, flush what the UI thread queued.

import "core:sync"
import "core:time"
import "core:sys/posix"
import ipc "../../platform/ipc"
import session "../session"

@(private)
_io_main :: proc(data: rawptr) {
	c := (^Client)(data)
	for !sync.atomic_load(&c.stopping) {
		sync.mutex_lock(&c.mutex)
		want_out := ipc.stream_wants_write(&c.conn)
		sync.mutex_unlock(&c.mutex)
		fds := [2]posix.pollfd{
			{fd = c.conn.fd, events = {.IN, .OUT} if want_out else {.IN}},
			{fd = c.wake_pipe[0], events = {.IN}},
		}
		if posix.poll(&fds[0], 2, -1) < 0 && posix.errno() != .EINTR do break
		if .IN in fds[1].revents do _drain_pipe(c.wake_pipe[0])
		if !_io_turn(c) do break
	}
	sync.atomic_store(&c.broken, !sync.atomic_load(&c.stopping))
	if c.wake != nil do c.wake(c.wake_data)
}

// _io_turn: false once the core is gone.
@(private = "file")
_io_turn :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c.mutex)
	ipc.stream_flush(&c.conn)
	ipc.stream_fill(&c.conn)
	woke := false
	for f in ipc.stream_next(&c.conn) {
		woke = true
		if f.channel != 0 && f.kind == ipc.STREAM_DATA {
			if l := _link_by_channel(c, f.channel); l != nil && !session.session_inbox_push(l.sess, f.payload) {
				c.conn.err = .Bad_Frame // the core sent past its credit
			}
			continue
		}
		if f.kind == ipc.MSG_ATTACHED do _bind_attached(c, f.payload)
		if f.kind == ipc.MSG_FAIL do _drop_cancelled(c, f.payload)
		hdr: [ipc.STREAM_HEADER]u8
		ipc.stream_put_header(hdr[:], f.kind, f.channel, len(f.payload))
		if !ipc.ring_push(&c.ctl_inbox, hdr[:], f.payload) do c.conn.err = .Overflow
	}
	ipc.stream_flush(&c.conn)
	ok := c.conn.err == .None
	sync.mutex_unlock(&c.mutex)
	if woke && c.wake != nil do c.wake(c.wake_data)
	return ok
}

// _io_settle runs on the closing thread once the IO thread stopped: it sends
// what is queued and answers the core's replies to released-but-pending links
// (their KILL/DETACH), so nothing a released pane started is left behind.
@(private)
_io_settle :: proc(c: ^Client, deadline_ns: i64) {
	for c.conn.fd >= 0 && c.conn.err == .None && time.tick_now()._nsec < deadline_ns {
		cancelled := false
		for &l in c.links do cancelled ||= l.cancelled
		if !cancelled && !ipc.stream_wants_write(&c.conn) do return
		events: posix.Poll_Event = {.IN, .OUT} if ipc.stream_wants_write(&c.conn) else {.IN}
		pfd := posix.pollfd{fd = c.conn.fd, events = events}
		posix.poll(&pfd, 1, 50)
		ipc.stream_flush(&c.conn)
		ipc.stream_fill(&c.conn)
		for f in ipc.stream_next(&c.conn) {
			if f.kind == ipc.MSG_ATTACHED do _bind_attached(c, f.payload)
			if f.kind == ipc.MSG_FAIL do _drop_cancelled(c, f.payload)
		}
	}
}

// _bind_attached maps the channel before any DATA on it can arrive.
@(private = "file")
_bind_attached :: proc(c: ^Client, payload: []u8) {
	r := ipc.wire_reader(payload)
	token, id, channel := ipc.wr_u32(&r), ipc.wr_u32(&r), ipc.wr_u32(&r)
	if !r.ok do return
	for &l in c.links {
		if l.token != token do continue
		if l.cancelled {
			b: [4]u8
			w := ipc.wire_writer(b[:])
			ipc.ww_u32(&w, id if l.cancel_kill else channel)
			ipc.stream_send(&c.conn, ipc.MSG_KILL if l.cancel_kill else ipc.MSG_DETACH, 0, b[:])
			l = {}
			return
		}
		if l.state != .Pending do continue
		l.id, l.channel, l.state = id, channel, .Attached
		// The size first: held input then reaches a program that already has it.
		if size, resized := l.pending_size.?; resized do client_send_size(c, channel, size)
		l.pending_size = nil
		if l.pending_len > 0 do ipc.stream_send(&c.conn, ipc.MSG_V_INPUT, channel, l.pending[:l.pending_len])
		l.pending_len = 0
		return
	}
}

// _drop_cancelled frees a released link whose request failed anyway.
@(private = "file")
_drop_cancelled :: proc(c: ^Client, payload: []u8) {
	r := ipc.wire_reader(payload)
	token := ipc.wr_u32(&r)
	for &l in c.links do if r.ok && token != 0 && l.cancelled && l.token == token do l = {}
}

@(private)
_link_by_channel :: proc(c: ^Client, channel: u32) -> ^Client_Link {
	for &l in c.links do if l.state == .Attached && l.channel == channel do return &l
	return nil
}

@(private = "file")
_drain_pipe :: proc(fd: posix.FD) {
	buf: [64]u8
	for posix.read(fd, &buf[0], len(buf)) > 0 {}
}

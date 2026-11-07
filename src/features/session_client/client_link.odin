package feature_session_client

// Session_Link procs of an attached session: input, replies, resize and
// credit go to the core on the session's channel.

import "core:sync"
import ipc "../../platform/ipc"
import session "../session"

@(private)
_link_write :: proc(user: rawptr, data: []u8) {
	_link_send(user, ipc.MSG_V_INPUT, data)
}

// _link_reply: a Pending session has printed nothing, so it has no query to
// answer yet; replies are never held as typed input.
@(private)
_link_reply :: proc(user: rawptr, data: []u8) {
	_link_send(user, ipc.MSG_V_REPLY, data)
}

@(private = "file")
_link_send :: proc(user: rawptr, kind: u8, data: []u8) {
	l := (^Client_Link)(user)
	c := l.client
	sync.mutex_lock(&c.mutex)
	switch l.state {
	case .Pending:
		if kind == ipc.MSG_V_INPUT do l.pending_len += copy(l.pending[l.pending_len:], data)
	case .Attached:
		for off := 0; ; off += ipc.STREAM_DATA_CHUNK { // an empty frame is sent once
			ipc.stream_send(&c.conn, kind, l.channel, data[off:min(len(data), off + ipc.STREAM_DATA_CHUNK)])
			if off + ipc.STREAM_DATA_CHUNK >= len(data) do break
		}
	case .Free, .Closed:
	}
	sync.mutex_unlock(&c.mutex)
	_poke(c)
}

@(private)
_link_resize :: proc(user: rawptr, size: ipc.Size_Msg) {
	l := (^Client_Link)(user)
	c := l.client
	sync.mutex_lock(&c.mutex)
	switch l.state {
	case .Pending:  l.pending_size = size
	case .Attached: client_send_size(c, l.channel, size)
	case .Free, .Closed:
	}
	sync.mutex_unlock(&c.mutex)
	_poke(c)
}

// client_send_size queues a V_RESIZE (c.mutex held).
@(private)
client_send_size :: proc(c: ^Client, channel: u32, size: ipc.Size_Msg) {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_size(&w, size)
	ipc.stream_send(&c.conn, ipc.MSG_V_RESIZE, channel, ipc.wire_bytes_written(&w))
}

@(private)
_link_consumed :: proc(user: rawptr, n: int) {
	l := (^Client_Link)(user)
	c := l.client
	sync.mutex_lock(&c.mutex)
	if l.state == .Attached do ipc.stream_ack(&c.conn, l.channel, n)
	sync.mutex_unlock(&c.mutex)
	_poke(c)
}

// client_focus / client_facts report the viewer's focus and cell size for sess.
client_focus :: proc(l: ^Client_Link, focused: bool) {
	b := [1]u8{1 if focused else 0}
	_channel_send(l, ipc.MSG_V_FOCUS, b[:])
}

client_facts :: proc(l: ^Client_Link, cell_w, cell_h: u16) {
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.enc_facts(&w, {cell_w = cell_w, cell_h = cell_h})
	_channel_send(l, ipc.MSG_V_FACTS, b[:])
}

@(private = "file")
_channel_send :: proc(l: ^Client_Link, kind: u8, payload: []u8) {
	if l == nil do return
	c := l.client
	sync.mutex_lock(&c.mutex)
	if l.state == .Attached do ipc.stream_send(&c.conn, kind, l.channel, payload)
	sync.mutex_unlock(&c.mutex)
	_poke(c)
}

// client_takeover takes sess back from the automation that holds it (the
// person confirmed it in the window). The core ends the lease.
client_takeover :: proc(c: ^Client, sess: ^session.Terminal_Session) {
	l := client_link_of(c, sess)
	if l != nil do _link_send(l, ipc.MSG_V_TAKEOVER, nil)
}

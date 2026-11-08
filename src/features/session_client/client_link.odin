package feature_session_client

// Session_Link procs of an attached session (UI thread): input, replies,
// resize and credit are queued for the IO thread, which sends them on the
// session's channel. Before the core confirmed the attach, typed input and
// the latest size are held on the link and sent when it binds.

import "core:sync"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

@(private)
_link_write :: proc(user: rawptr, data: []u8) {
	_link_send(user, proto.MSG_V_INPUT, data)
}

// _link_reply: a Pending session has printed nothing, so it has no query to
// answer yet; replies are never held as typed input.
@(private)
_link_reply :: proc(user: rawptr, data: []u8) {
	_link_send(user, proto.MSG_V_REPLY, data)
}

@(private = "file")
_link_send :: proc(user: rawptr, kind: u8, data: []u8) {
	l := (^Client_Link)(user)
	c := l.client
	sync.mutex_lock(&c.mutex)
	switch l.state {
	case .Pending:
		if kind == proto.MSG_V_INPUT do l.pending_len += copy(l.pending[l.pending_len:], data)
	case .Attached:
		for off := 0; ; off += ipc.STREAM_DATA_CHUNK { // an empty frame is sent once
			_queue_stream(c, l, kind, data[off:min(len(data), off + ipc.STREAM_DATA_CHUNK)])
			if off + ipc.STREAM_DATA_CHUNK >= len(data) do break
		}
	case .Free, .Closed:
	}
	sync.mutex_unlock(&c.mutex)
	ipc.client_interrupt(&c.link)
}

@(private)
_link_resize :: proc(user: rawptr, size: proto.Size_Msg) {
	l := (^Client_Link)(user)
	c := l.client
	b: [8]u8
	w := ipc.wire_writer(b[:])
	proto.enc_size(&w, size)
	sync.mutex_lock(&c.mutex)
	switch l.state {
	case .Pending:  l.pending_size = size
	case .Attached: _queue_stream(c, l, proto.MSG_V_RESIZE, ipc.wire_bytes_written(&w))
	case .Free, .Closed:
	}
	sync.mutex_unlock(&c.mutex)
	ipc.client_interrupt(&c.link)
}

@(private)
_link_consumed :: proc(user: rawptr, n: int) {
	l := (^Client_Link)(user)
	c := l.client
	b := _u32(u32(n))
	sync.mutex_lock(&c.mutex)
	if l.state == .Attached do _rec_push(&c.ops, u8(_Op.Ack), _link_key(c, l), b[:])
	sync.mutex_unlock(&c.mutex)
	ipc.client_interrupt(&c.link)
}

// client_takeover takes sess back from the automation that holds it (the
// person confirmed it in the window). The core ends the lease.
client_takeover :: proc(c: ^Client, sess: ^session.Terminal_Session) {
	l := client_link_of(c, sess)
	if l != nil do _link_send(l, proto.MSG_V_TAKEOVER, nil)
}

// _queue_stream queues one frame for l's channel (c.mutex held). A full
// queue drops it: the IO thread is that far behind.
@(private = "file")
_queue_stream :: proc(c: ^Client, l: ^Client_Link, kind: u8, data: []u8) {
	k := [1]u8{kind}
	_rec_push(&c.ops, u8(_Op.Stream), _link_key(c, l), k[:], data)
}

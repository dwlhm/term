package feature_session_core_tests

// An in-process core driven from the test thread: session 1 adopted the way a
// holder WELCOME does (80×24, no holder), viewers on socketpairs. No poll
// loop and no clock: each step is explicit, so orderings are exact.

import "core:sys/posix"
import core ".."
import terminal "../../../core/terminal"
import ipc "../../../platform/ipc"

RIG_VIEWERS :: 2

Rig :: struct {
	c:     ^core.Core,
	s:     ^core.Core_Session,
	peers: [RIG_VIEWERS]ipc.Stream_Conn,
	n:     int,
}

rig_make :: proc(r: ^Rig) -> bool {
	r.c = core.core_new()
	core.core_session_adopt(r.c, -1, {id = 1, size = {cols = 80, rows = 24}})
	r.s = core.core_session_find(r.c, 1)
	return r.s != nil
}

// rig_attach links one more viewer and attaches it to session 1; its index.
rig_attach :: proc(r: ^Rig, history: u32 = 0) -> int {
	fds: [2]posix.FD
	if r.n == RIG_VIEWERS || posix.socketpair(.UNIX, .STREAM, .IP, &fds) != .OK do return -1
	i := r.n
	r.n += 1
	v := &r.c.viewers[i]
	v^ = {used = true, hello = true, role = .Viewer}
	if !ipc.stream_conn_init(&v.conn, fds[0], core.CORE_VIEWER_CTL) || !ipc.stream_conn_init(&r.peers[i], fds[1], 2 << 20) {
		return -1
	}
	_, ok := core.core_attach(r.c, r.s, i, {id = 1, size = {cols = 80, rows = 24}, history = history})
	return i if ok else -1
}

rig_destroy :: proc(r: ^Rig) {
	for i in 0 ..< r.n do ipc.stream_conn_destroy(&r.peers[i])
	core.core_destroy(r.c)
}

// rig_deliver hands viewer i everything the core queued for it, feeding the
// DATA into `into` when given and granting credit as it goes; the DATA bytes.
rig_deliver :: proc(r: ^Rig, i: int, into: ^terminal.Terminal = nil) -> int {
	total := 0
	for {
		ipc.stream_flush(&r.c.viewers[i].conn)
		ipc.stream_fill(&r.peers[i])
		got := 0
		for f in ipc.stream_next(&r.peers[i]) {
			if f.kind != ipc.STREAM_DATA do continue
			got += len(f.payload)
			if into != nil do terminal.terminal_feed_bytes(into, f.payload)
			ipc.stream_ack(&r.peers[i], f.channel, len(f.payload))
		}
		ipc.stream_flush(&r.peers[i])
		core.core_viewer_service(r.c, i, {.IN})
		total += got
		if got == 0 && !ipc.stream_wants_write(&r.c.viewers[i].conn) do return total
	}
}

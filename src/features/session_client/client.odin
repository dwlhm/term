package feature_session_client

// Viewer side of the core link. The IO thread owns reading: it pushes DATA
// into each attached session's inbox and every control frame into ctl_inbox,
// then wakes the UI. The UI thread sends through the same conn under mutex
// and drains ctl_inbox with client_poll. Nothing here blocks the UI thread
// except client_connect and client_request_sync (CLI), both with deadlines.

import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import ipc "../../platform/ipc"
import session "../session"

CLIENT_MAX_LINKS   :: 128
CLIENT_CTL_INBOX   :: 4 << 20
CLIENT_CONN_CTL    :: 2 << 20
CLIENT_START_MS    :: 3000
CLIENT_PENDING_IN  :: 4096 // input typed before the core confirmed the attach
CLIENT_FLUSH_MS    :: 500

Client_Wake :: #type proc "contextless" (user: rawptr)

Link_State :: enum u8 { Free, Pending, Attached, Closed }

Client_Link :: struct {
	state:       Link_State,
	token:       u32,
	id:          u32,
	channel:     u32,
	client:      ^Client,
	sess:        ^session.Terminal_Session,
	pending:     [CLIENT_PENDING_IN]u8,
	pending_len: int,
	pending_size: Maybe(ipc.Size_Msg), // the latest resize before ATTACHED: sent first on bind
	observe:     bool,
	cancelled:   bool, // released before the core answered: undo the attach when it does
	cancel_kill: bool,
}

Client :: struct {
	conn:       ipc.Stream_Conn,
	mutex:      sync.Mutex,
	io:         ^thread.Thread,
	wake_pipe:  [2]posix.FD,
	stopping:   bool,
	broken:     bool, // the core went away
	wake:       Client_Wake,
	wake_data:  rawptr,
	links:      [CLIENT_MAX_LINKS]Client_Link,
	ctl_inbox:  ipc.Byte_Ring,
	next_token: u32,
	scratch:    []u8, // one event payload, see client_poll
}

// client_connect links to the session dir's core, starting one if none runs,
// and starts the IO thread. wake is called (from the IO thread) when there is
// something for client_poll or a session inbox.
client_connect :: proc(c: ^Client, wake: Client_Wake, wake_data: rawptr) -> bool {
	c^ = {wake = wake, wake_data = wake_data, wake_pipe = {-1, -1}}
	if posix.pipe(&c.wake_pipe) != .OK do return false
	ipc.ipc_set_nonblocking_cloexec(c.wake_pipe[0])
	ipc.ipc_set_nonblocking_cloexec(c.wake_pipe[1])
	c.ctl_inbox.buf = make([]u8, CLIENT_CTL_INBOX)
	c.scratch = make([]u8, ipc.STREAM_MAX_PAYLOAD)
	return _link_up(c)
}

// client_reconnect re-links after Core_Lost (the holder restarts a crashed
// core): every shown session is attached again under a new token and its
// Terminal is repainted by the new core. A session still being created is lost.
client_reconnect :: proc(c: ^Client) -> bool {
	_io_stop(c)
	ipc.stream_conn_destroy(&c.conn)
	ipc.ring_clear(&c.ctl_inbox)
	if !_link_up(c) do return false
	msg: [64]u8
	for &l in c.links {
		switch {
		case l.cancelled:
			l = {}
		case l.state == .Attached:
			c.next_token += 1
			l.token, l.state, l.channel = c.next_token, .Pending, 0
			w := ipc.wire_writer(msg[:])
			ipc.ww_u32(&w, l.token)
			size := ipc.Size_Msg{cols = u16(l.sess.term.cols), rows = u16(l.sess.term.rows)}
			ipc.enc_attach(&w, {id = l.id, size = size, observe = l.observe})
			_send(c, ipc.MSG_ATTACH, 0, ipc.wire_bytes_written(&w))
		case l.state == .Pending:
			l.sess.info.alive = false // its CREATE died with the old core
		}
	}
	return true
}

@(private = "file")
_link_up :: proc(c: ^Client) -> bool {
	fd, ok := client_dial(.Viewer, true)
	if !ok do return false
	if !ipc.stream_conn_init(&c.conn, fd, CLIENT_CONN_CTL) do return false
	sync.atomic_store(&c.stopping, false)
	c.io = thread.create_and_start_with_data(c, _io_main)
	return c.io != nil
}

@(private = "file")
_io_stop :: proc(c: ^Client) {
	if c.io == nil do return
	sync.atomic_store(&c.stopping, true)
	_poke(c)
	thread.join(c.io)
	thread.destroy(c.io)
	c.io = nil
}

// client_dial connects to the core (starting it when absent and start is set)
// and completes the HELLO exchange synchronously. Returns a non-blocking fd.
client_dial :: proc(role: ipc.Stream_Role, start: bool) -> (fd: posix.FD, ok: bool) {
	dir_buf, sock_buf, log_buf: [256]u8
	dir, err := ipc.ipc_session_dir(dir_buf[:])
	if err != .None do return -1, false
	sock, _ := ipc.ipc_session_path(sock_buf[:], dir, "core.sock")
	if fd, err = ipc.ipc_connect(sock, 500); err != .None {
		if !start do return -1, false
		log_path := ipc.ipc_log_path(log_buf[:], "core.log")
		if !ipc.ipc_spawn_self_detached({"--core"}, log_path) do return -1, false
		deadline := time.tick_now()._nsec + CLIENT_START_MS * 1_000_000
		for err != .None && time.tick_now()._nsec < deadline {
			time.sleep(20 * time.Millisecond)
			fd, err = ipc.ipc_connect(sock, 500)
		}
		if err != .None do return -1, false
	}
	return _hello(fd, role)
}

// _hello owns fd: it comes back open after a good HELLO exchange, else it is closed.
@(private = "file")
_hello :: proc(fd: posix.FD, role: ipc.Stream_Role) -> (posix.FD, bool) {
	conn: ipc.Stream_Conn
	if !ipc.stream_conn_init(&conn, fd, 0) do return -1, false
	defer ipc.stream_conn_destroy(&conn)
	build_buf, msg: [128]u8
	w := ipc.wire_writer(msg[:])
	ipc.enc_hello(&w, {version = ipc.STREAM_PROTO_VERSION, role = role, build = ipc.ipc_build_id(build_buf[:])})
	ipc.stream_send(&conn, ipc.MSG_HELLO, 0, ipc.wire_bytes_written(&w))
	f, got := client_wait_frame(&conn, 2000)
	if !got || f.kind != ipc.MSG_HELLO do return -1, false
	if _, _, ok := ipc.stream_hello_check(f.payload, {.Core}); !ok do return -1, false
	return ipc.stream_conn_release(&conn), true
}

// client_wait_frame flushes and waits for the next frame (CLI / handshake only).
client_wait_frame :: proc(conn: ^ipc.Stream_Conn, timeout_ms: int) -> (ipc.Stream_Frame, bool) {
	deadline := time.tick_now()._nsec + i64(timeout_ms) * 1_000_000
	for {
		ipc.stream_flush(conn)
		if f, ok := ipc.stream_next(conn); ok do return f, true
		if conn.err != .None do return {}, false
		left := (deadline - time.tick_now()._nsec) / 1_000_000
		if left <= 0 do return {}, false
		events: posix.Poll_Event = {.IN, .OUT} if ipc.stream_wants_write(conn) else {.IN}
		pfd := posix.pollfd{fd = conn.fd, events = events}
		if posix.poll(&pfd, 1, i32(left)) > 0 do ipc.stream_fill(conn)
	}
}

// client_disconnect delivers what is still queued (a KILL from the last
// release, say) within CLIENT_FLUSH_MS, then closes the link.
client_disconnect :: proc(c: ^Client) {
	_io_stop(c)
	_io_settle(c, time.tick_now()._nsec + CLIENT_FLUSH_MS * 1_000_000)
	for &l in c.links do if l.sess != nil do session.session_destroy(l.sess)
	for p in c.wake_pipe do if p >= 0 do posix.close(p)
	ipc.stream_conn_destroy(&c.conn)
	delete(c.ctl_inbox.buf)
	delete(c.scratch)
	c^ = {}
}

@(private)
_poke :: proc(c: ^Client) {
	b := [1]u8{1}
	posix.write(c.wake_pipe[1], &b[0], 1)
}

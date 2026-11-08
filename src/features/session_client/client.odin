package feature_session_client

// Viewer side of the session link. The IO thread owns the ipc.Client (it is
// not thread-safe): it sends what the UI thread queued (client_queue.odin),
// pushes stream DATA into each attached session's inbox and queues every
// other event for client_poll, then wakes the UI. The UI thread never blocks
// except in client_connect/client_reconnect, which have deadlines.

import "core:sync"
import "core:thread"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

CLIENT_MAX_LINKS   :: 128 // ≤ 256: a link key keeps the index in 8 bits
CLIENT_EVENTS      :: 4 << 20 // events waiting for client_poll
CLIENT_OPS         :: 4 << 20 // ops waiting for the IO thread (typed input included)
CLIENT_PENDING_IN  :: 4096 // input typed before the core confirmed the attach
CLIENT_FLUSH_MS    :: 500

Client_Wake :: #type proc "contextless" (user: rawptr)

Link_State :: enum u8 { Free, Pending, Attached, Closed }

Client_Link :: struct {
	state:       Link_State,
	ticket:      ipc.Ticket, // the CREATE/ATTACH whose ATTACHED it waits for
	id:          u32,
	channel:     u32,
	client:      ^Client,
	sess:        ^session.Terminal_Session,
	pending:     [CLIENT_PENDING_IN]u8,
	pending_len: int,
	pending_size: Maybe(proto.Size_Msg), // the latest resize before ATTACHED: sent first on bind
	observe:     bool,
	cancelled:   bool, // released before the core answered: undo the attach when it does
	cancel_kill: bool,
	gen:         u32, // per use of the slot (records name it, client_queue.odin)
}

Client :: struct {
	link:      ipc.Client, // the session link: the IO thread's alone while it runs
	mutex:     sync.Mutex, // links, ops and events
	io:        ^thread.Thread,
	stopping:  bool,
	broken:    bool, // the core went away
	overflow:  bool, // the UI fell too far behind: treated as a lost core
	wake:      Client_Wake,
	wake_data: rawptr,
	links:     [CLIENT_MAX_LINKS]Client_Link,
	ops:       ipc.Byte_Ring,
	events:    ipc.Byte_Ring,
	scratch:   []u8, // UI thread: one event, see client_poll
	io_buf:    []u8, // IO thread: one op
}

// client_connect links to the session dir's core, starting one if none runs,
// and starts the IO thread. wake is called (from the IO thread) when there is
// something for client_poll or a session inbox.
client_connect :: proc(c: ^Client, wake: Client_Wake, wake_data: rawptr) -> bool {
	c^ = {wake = wake, wake_data = wake_data}
	c.ops.buf = make([]u8, CLIENT_OPS)
	c.events.buf = make([]u8, CLIENT_EVENTS)
	c.scratch = make([]u8, ipc.STREAM_MAX_PAYLOAD)
	c.io_buf = make([]u8, ipc.STREAM_MAX_PAYLOAD)
	return _link_up(c)
}

// client_reconnect re-links after Core_Lost (the holder restarts a crashed
// core): every shown session is attached again and its Terminal is repainted
// by the new core. A session still being created is lost.
client_reconnect :: proc(c: ^Client) -> bool {
	_io_stop(c)
	ipc.client_close(&c.link)
	ipc.ring_clear(&c.ops)
	ipc.ring_clear(&c.events)
	sync.atomic_store(&c.overflow, false)
	if !_link_up(c) do return false
	for &l in c.links {
		switch {
		case l.cancelled:
			l = {gen = l.gen}
		case l.state == .Attached:
			l.state, l.channel, l.ticket = .Pending, 0, 0
			size := proto.Size_Msg{cols = u16(l.sess.term.cols), rows = u16(l.sess.term.rows)}
			_send_attach(c, &l, {id = l.id, size = size, observe = l.observe})
		case l.state == .Pending:
			l.sess.info.alive = false // its CREATE died with the old core
		}
	}
	return true
}

@(private = "file")
_link_up :: proc(c: ^Client) -> bool {
	if proto.session_open(&c.link, .Viewer).kind != .None do return false
	sync.atomic_store(&c.stopping, false)
	sync.atomic_store(&c.broken, false)
	c.io = thread.create_and_start_with_data(c, _io_main)
	return c.io != nil
}

@(private = "file")
_io_stop :: proc(c: ^Client) {
	if c.io == nil do return
	sync.atomic_store(&c.stopping, true)
	ipc.client_interrupt(&c.link)
	thread.join(c.io)
	thread.destroy(c.io)
	c.io = nil
}

// client_disconnect delivers what is still queued (a KILL from the last
// release, say) within CLIENT_FLUSH_MS, then closes the link.
client_disconnect :: proc(c: ^Client) {
	_io_stop(c)
	_io_settle(c, time.tick_now()._nsec + CLIENT_FLUSH_MS * 1_000_000)
	ipc.client_close(&c.link)
	for &l in c.links do if l.sess != nil do session.session_destroy(l.sess)
	delete(c.ops.buf)
	delete(c.events.buf)
	delete(c.scratch)
	delete(c.io_buf)
	c^ = {}
}

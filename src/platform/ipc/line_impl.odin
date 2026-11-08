package platform_ipc

// Server{.Line} (spec 7.6): one line in, one answer out, then close, on the
// wire of the control socket. Slots live in a fixed table (max_peers, plus
// _LINE_SPARE to answer "err busy" when every one is taken). A finished line
// is queued for the owner (server_next); the owner's reply goes back to the
// slot under the mutex, since with server_open_thread the IO runs on a
// thread of its own. Every answer is written, then the write side is shut
// and what the client still sends is drained until it closes, so the
// answer never dies in a reset. IO: line_io.odin.

import "base:runtime"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

@(private)
_LINE_SPARE :: 2
@(private)
_LINE_REPLY_MAX :: 64 * 1024
@(private)
_LINE_REPLY_MS :: 3000 // the owner answers a queued line within this
@(private)
_LINE_IO_MS :: 2000 // writing the answer and draining the rest

@(private)
_Line_State :: enum u8 {
	Free,
	Reading,
	Queued,   // handed to the owner
	Replied,  // the owner answered from another thread; the IO thread starts writing
	Writing,
	Draining, // answer out, write side shut: read and drop until EOF
}

@(private)
_Line_Slot :: struct {
	ln:      ^_Line,
	fd:      posix.FD,
	src:     u32,
	gen:     u16,
	state:   _Line_State,
	taken:   bool, // server_next handed it out
	in_buf:  []u8,
	in_len:  int,
	out:     []u8,
	out_len: int,
	out_off: int,
}

@(private)
_Line :: struct {
	set:       ^_Poll,
	own_set:   Poll_Set, // server_open_thread only
	io:        ^thread.Thread,
	stopping:  bool, // atomic
	listener:  _Listener,
	slots:     []_Line_Slot,
	max_peers: int,
	hello_ms:  int,
	mutex:     sync.Mutex,
	queue:     []Peer,
	q_head:    int,
	q_len:     int,
	broken:    bool, // the listener broke: Server_Down once the queue is empty
	reported:  bool,
	on_wake:   proc "contextless" (data: rawptr),
	wake_data: rawptr,
	allocator: runtime.Allocator,
}

@(private)
_line_new :: proc(path: string, set: ^_Poll, opts: Server_Opts) -> (ln: ^_Line, err: Error) {
	ln = new(_Line)
	ln^ = {set = set, max_peers = opts.max_peers, hello_ms = opts.hello_ms, allocator = context.allocator}
	ln.slots = make([]_Line_Slot, opts.max_peers + _LINE_SPARE)
	ln.queue = make([]Peer, len(ln.slots))
	for &sl in ln.slots {
		sl.ln, sl.fd = ln, -1
		sl.in_buf = make([]u8, opts.max_payload)
		sl.out = make([]u8, _LINE_REPLY_MAX)
	}
	if set == nil {
		if err = poll_set_init(&ln.own_set, len(ln.slots) + 1); err.kind != .None {
			_line_free(ln)
			return nil, err
		}
		ln.set = _poll(&ln.own_set)
	}
	if err = _listener_open(&ln.listener, ln.set, path, _line_accept, _line_broken, ln); err.kind != .None {
		_line_free(ln)
		return nil, err
	}
	return ln, {}
}

// _line_run_thread moves the IO to a thread that owns ln.own_set.
@(private)
_line_run_thread :: proc(ln: ^_Line, on_wake: proc "contextless" (data: rawptr), data: rawptr) {
	ln.on_wake, ln.wake_data = on_wake, data
	ln.io = thread.create_and_start_with_poly_data(ln, proc(ln: ^_Line) {
		for !sync.atomic_load(&ln.stopping) {
			poll_set_wait(&ln.own_set, -1)
			_ = poll_set_woken(&ln.own_set)
			_line_start_replies(ln)
		}
	}, context)
}

@(private)
_line_free :: proc(ln: ^_Line) {
	context.allocator = ln.allocator
	if ln.io != nil {
		sync.atomic_store(&ln.stopping, true)
		poll_set_poke(&ln.own_set)
		thread.join(ln.io)
		thread.destroy(ln.io)
	}
	_listener_close(&ln.listener)
	for &sl in ln.slots {
		if sl.state != .Free do _line_close(&sl)
		delete(sl.in_buf)
		delete(sl.out)
	}
	poll_set_destroy(&ln.own_set)
	delete(ln.slots)
	delete(ln.queue)
	free(ln)
}

@(private)
_line_due :: proc(ms: int) -> i64 { return time.tick_now()._nsec + i64(ms) * 1_000_000 }

// _line_next (owner): the next queued line, once.
@(private)
_line_next :: proc(ln: ^_Line, srv: rawptr) -> (Server_Event, bool) {
	sync.mutex_lock(&ln.mutex)
	defer sync.mutex_unlock(&ln.mutex)
	for ln.q_len > 0 {
		p := ln.queue[ln.q_head]
		ln.q_head, ln.q_len = (ln.q_head + 1) % len(ln.queue), ln.q_len - 1
		sl := &ln.slots[p.slot]
		if sl.gen != p.gen || sl.state != .Queued || sl.taken do continue // timed out meanwhile
		sl.taken = true
		return Request{peer = p, _body = sl.in_buf[:sl.in_len], _srv = srv}, true
	}
	if ln.broken && !ln.reported {
		ln.reported = true
		return Server_Down{{kind = .Listener_Broken, reason = "the server can no longer accept"}}, true
	}
	return nil, false
}

// _line_reply (owner): the answer goes out as is; a line that already timed
// out (or was answered) takes nothing.
@(private)
_line_reply :: proc(ln: ^_Line, req: Request, parts: ..[]u8) {
	sync.mutex_lock(&ln.mutex)
	defer sync.mutex_unlock(&ln.mutex)
	if int(req.peer.slot) >= len(ln.slots) do return
	sl := &ln.slots[req.peer.slot]
	if sl.gen != req.peer.gen || sl.state != .Queued do return
	n := 0
	for p in parts do n += len(p)
	sl.out_off, sl.out_len = 0, 0
	if n > len(sl.out) do sl.out_len = copy(sl.out, "err too_large\n")
	else do for p in parts do sl.out_len += copy(sl.out[sl.out_len:], p)
	if ln.io == nil {
		_line_writing(sl)
		return
	}
	sl.state = .Replied
	poll_set_poke(&ln.own_set)
}

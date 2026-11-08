package feature_session_core_tests

// An in-process core driven from the test thread: session 1 adopted the way a
// holder WELCOME does (80×24, no holder), viewers as ipc.Clients on its
// session Server in a private dir. No loop thread: each step is explicit
// (rig_pump runs one non-blocking round), so orderings are exact.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import core ".."
import terminal "../../../core/terminal"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

RIG_VIEWERS :: 2

Rig :: struct {
	c:       ^core.Core,
	s:       ^core.Core_Session,
	peers:   [RIG_VIEWERS]ipc.Client,
	n:       int,
	dir_buf: [64]u8,
	dir:     string,
	ready:   [2]posix.FD, // a pipe holding one byte: a watch fd that is always readable
}

@(private = "file")
_rig_seq: int

rig_make :: proc(r: ^Rig) -> bool {
	_rig_seq += 1
	r.dir = fmt.bprintf(r.dir_buf[:], "/tmp/trig-%d-%d", posix.getpid(), _rig_seq)
	os.set_env(proto.SESSION_DIR_ENV, r.dir)
	if posix.pipe(&r.ready) != .OK do return false
	b := u8(1)
	posix.write(r.ready[1], &b, 1)
	r.c = core.core_new()
	if ipc.poll_set_init(&r.c.set, core.CORE_MAX_POLL).kind != .None || core.core_listen(r.c).kind != .None do return false
	core.core_session_adopt(r.c, -1, {id = 1, size = {cols = 80, rows = 24}})
	r.s = core.core_session_find(r.c, 1)
	return r.s != nil
}

// rig_pump runs one core round without waiting.
rig_pump :: proc(r: ^Rig) {
	ipc.poll_set_wait(&r.c.set, time.tick_now()._nsec)
	core.core_viewer_events(r.c)
}

// rig_attach links one more viewer and attaches it to session 1; its index.
// The client opens on a thread of its own: its HELLO needs the core's rounds.
rig_attach :: proc(r: ^Rig, history: u32 = 0) -> int {
	if r.n == RIG_VIEWERS do return -1
	i := r.n
	r.n += 1
	Open :: struct { c: ^ipc.Client, err: ipc.Error, done: bool }
	o := Open{c = &r.peers[i]}
	th := thread.create_and_start_with_poly_data(&o, proc(o: ^Open) {
		o.err = proto.session_open(o.c, .Viewer, false)
		sync.atomic_store(&o.done, true)
	})
	for !sync.atomic_load(&o.done) do rig_pump(r)
	thread.join(th)
	thread.destroy(th)
	if o.err.kind != .None do return -1
	b: [64]u8
	w := ipc.wire_writer(b[:])
	proto.enc_attach(&w, {id = 1, size = {cols = 80, rows = 24}, history = history})
	tk, err := ipc.client_start(&r.peers[i], proto.MSG_ATTACH, ipc.wire_bytes_written(&w))
	for err.kind == .None {
		rig_pump(r)
		ev, perr := ipc.client_poll(&r.peers[i], 50 * time.Millisecond)
		if la, ok := ev.(ipc.Late_Answer); ok && la.ticket == tk do return i if la.err.kind == .None else -1
		if perr.kind != .None && perr.kind != .Timeout do return -1
	}
	return -1
}

rig_destroy :: proc(r: ^Rig) {
	for i in 0 ..< r.n do ipc.client_close(&r.peers[i])
	core.core_destroy(r.c)
	for fd in r.ready do posix.close(fd)
	cbuf: [64]u8
	copy(cbuf[:len(cbuf) - 1], r.dir)
	posix.rmdir(cstring(raw_data(cbuf[:])))
}

// rig_deliver hands viewer i everything the core queued for it, feeding the
// DATA into `into` when given and granting credit as it goes; the DATA bytes.
// rig_pump writes what fits into the socket before the viewer reads, and a
// socket holds a whole DATA frame (ipc sizes it to the credit window), so a
// round that brings no frame means the core has nothing more. The always
// readable watch makes client_poll return at once when the socket is empty.
rig_deliver :: proc(r: ^Rig, i: int, into: ^terminal.Terminal = nil) -> int {
	total := 0
	for {
		rig_pump(r)
		got := 0
		for {
			ev, err := ipc.client_poll(&r.peers[i], time.Second, r.ready[0])
			if err.kind != .None || ev == nil do break
			d, is_data := ev.(ipc.Stream_Data)
			if !is_data do continue
			got += len(d.bytes)
			if into != nil do terminal.terminal_feed_bytes(into, d.bytes)
			ipc.client_stream_ack(&r.peers[i], d.channel, len(d.bytes))
		}
		total += got
		if got == 0 do return total
	}
}

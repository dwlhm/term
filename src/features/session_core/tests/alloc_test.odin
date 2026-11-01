package feature_session_core_tests

// Invariant 1: once a session and its viewer exist, relaying program output
// (relay, Terminal, answered queries, viewer DATA + CREDIT, row EVENTs) does
// not allocate.

import "core:mem"
import "core:sys/posix"
import "core:testing"
import core ".."
import ipc "../../../platform/ipc"
import session "../../session"

@(private = "file")
CHUNK :: "\x1b[1;32mbuild\x1b[0m step \x1b[38;2;10;20;30mrgb\x1b[0m ünï 漢字 \x1b[6n\r\n"

@(private = "file")
Rig :: struct {
	c:    ^core.Core,
	s:    ^core.Core_Session,
	peer: ipc.Stream_Conn,
}

@(private = "file")
rig_make :: proc(r: ^Rig) -> bool {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, .IP, &fds) != .OK do return false
	r.c = core.core_new()
	v := &r.c.viewers[0]
	v^ = {used = true, hello = true, role = .Viewer}
	ok := ipc.stream_conn_init(&v.conn, fds[0], core.CORE_VIEWER_CTL) && ipc.stream_conn_init(&r.peer, fds[1], 2 << 20)
	r.s = &r.c.sessions[0]
	r.s^ = {used = true, id = 1, holder = -1}
	r.s.sess = session.session_create({cols = 80, rows = 24}, {})
	_, attached := core.core_attach(r.c, r.s, 0, {id = 1, size = {cols = 80, rows = 24}})
	return ok && attached
}

// rig_turn relays one chunk and lets the peer read it and grant credit.
@(private = "file")
rig_turn :: proc(r: ^Rig) -> int {
	core.core_session_output(r.c, r.s, transmute([]u8)string(CHUNK))
	ipc.stream_flush(&r.c.viewers[0].conn)
	got := 0
	ipc.stream_fill(&r.peer)
	for f in ipc.stream_next(&r.peer) do if f.kind == ipc.STREAM_DATA do got += len(f.payload)
	if got > 0 do ipc.stream_ack(&r.peer, 1, got)
	ipc.stream_flush(&r.peer)
	core.core_viewer_service(r.c, 0, {.IN})
	return got
}

@(test)
test_output_relay_allocates_nothing :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r), "rig")
	defer {
		ipc.stream_conn_destroy(&r.peer)
		core.core_destroy(r.c)
	}
	// Warm up past the history limit so every ring is at its steady size.
	for _ in 0..<12_000 do rig_turn(&r)
	track, temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&track)
	defer mem.tracking_allocator_destroy(&temp_track)
	delivered := 0
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		for _ in 0..<5_000 do delivered += rig_turn(&r)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
	testing.expect(t, delivered > 5_000 * 40, "the viewer received the stream")
	testing.expect(t, r.c.viewers[0].used, "the viewer is still linked")
}

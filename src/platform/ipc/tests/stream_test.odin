package platform_ipc_tests

import "core:mem"
import "core:sys/posix"
import "core:testing"
import ipc "../"

// Sample frame kinds (any non-transport kind does).
@(private = "file")
_K_EVENT :: u8(83)
@(private = "file")
_K_INPUT :: u8(21)
@(private = "file")
_K_OUTPUT :: u8(42)
@(private = "file")
_K_RELEASE :: u8(24)

@(private = "file")
Pair :: struct {
	a, b: ipc.Stream_Conn,
}

@(private = "file")
pair_open :: proc(p: ^Pair, ctl_cap: int = 1 << 20) -> bool {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK do return false
	return ipc.stream_conn_init(&p.a, fds[0], ctl_cap) && ipc.stream_conn_init(&p.b, fds[1], ctl_cap)
}

@(private = "file")
pair_close :: proc(p: ^Pair) {
	ipc.stream_conn_destroy(&p.a)
	ipc.stream_conn_destroy(&p.b)
}

// pump moves bytes a → b until a has nothing writable or b stops reading.
@(private = "file")
pump :: proc(p: ^Pair) {
	for _ in 0..<64 {
		ipc.stream_flush(&p.a)
		ipc.stream_fill(&p.b)
		if !ipc.stream_wants_write(&p.a) do break
	}
}

@(test)
test_stream_frames_roundtrip_in_order :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	ipc.stream_send(&p.a, _K_INPUT, 7, transmute([]u8)string("he"), transmute([]u8)string("llo"))
	ipc.stream_send(&p.a, _K_RELEASE, 9)
	pump(&p)
	f, ok := ipc.stream_next(&p.b)
	testing.expect(t, ok && f.kind == _K_INPUT && f.channel == 7 && string(f.payload) == "hello")
	f, ok = ipc.stream_next(&p.b)
	testing.expect(t, ok && f.kind == _K_RELEASE && f.channel == 9 && len(f.payload) == 0)
	_, ok = ipc.stream_next(&p.b)
	testing.expect(t, !ok)
}

@(test)
test_stream_reassembles_byte_by_byte :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	frame: [ipc.STREAM_HEADER + 3]u8
	ipc.stream_put_header(frame[:], _K_OUTPUT, 3, 3)
	copy(frame[ipc.STREAM_HEADER:], "abc")
	for i in 0..<len(frame) {
		_, ok := ipc.stream_next(&p.b)
		testing.expect(t, !ok, "no frame before the last byte")
		posix.send(p.a.fd, &frame[i], 1, {})
		ipc.stream_fill(&p.b)
	}
	f, ok := ipc.stream_next(&p.b)
	testing.expect(t, ok && string(f.payload) == "abc")
}

@(test)
test_stream_rejects_oversize_header :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	hdr: [ipc.STREAM_HEADER]u8
	ipc.stream_put_header(hdr[:], _K_OUTPUT, 1, ipc.STREAM_MAX_PAYLOAD + 1)
	posix.send(p.a.fd, &hdr[0], len(hdr), {})
	ipc.stream_fill(&p.b)
	_, ok := ipc.stream_next(&p.b)
	testing.expect(t, !ok && p.b.err == .Bad_Frame)
}

@(test)
test_stream_credit_limits_data_and_control_still_flows :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	testing.expect(t, ipc.stream_channel_open(&p.a, 5, true))
	big := make([]u8, ipc.STREAM_WINDOW * 2)
	defer delete(big)
	testing.expect(t, ipc.stream_data(&p.a, 5, big))
	ipc.stream_send(&p.a, _K_EVENT, 0)
	pump(&p)
	got, saw_event := 0, false
	for f in ipc.stream_next(&p.b) {
		if f.kind == ipc.STREAM_DATA do got += len(f.payload)
		if f.kind == _K_EVENT do saw_event = true
	}
	testing.expect(t, saw_event, "control is not held up by a stalled stream")
	testing.expect_value(t, got, ipc.STREAM_WINDOW)
	ipc.stream_ack(&p.b, 5, got)
	ipc.stream_flush(&p.b)
	ipc.stream_fill(&p.a)
	for _ in ipc.stream_next(&p.a) {}
	pump(&p)
	for f in ipc.stream_next(&p.b) do if f.kind == ipc.STREAM_DATA do got += len(f.payload)
	testing.expect_value(t, got, len(big))
}

@(test)
test_stream_slow_reader_overflow_asks_for_repaint :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	ipc.stream_channel_open(&p.a, 1, true)
	chunk := make([]u8, 1 << 20)
	defer delete(chunk)
	overflowed := false
	for _ in 0..<5 do if !ipc.stream_data(&p.a, 1, chunk) do overflowed = true
	ch := ipc.stream_channel(&p.a, 1)
	testing.expect(t, overflowed && ch.needs_repaint && ch.pending.len < len(chunk) * 4)
}

@(test)
test_stream_finish_closes_after_pending :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	ipc.stream_channel_open(&p.a, 2, false)
	ipc.stream_data(&p.a, 2, transmute([]u8)string("bye"))
	ipc.stream_channel_finish(&p.a, 2)
	pump(&p)
	f1, _ := ipc.stream_next(&p.b)
	f2, ok := ipc.stream_next(&p.b)
	testing.expect(t, f1.kind == ipc.STREAM_DATA && string(f1.payload) == "bye")
	testing.expect(t, ok && f2.kind == ipc.STREAM_CLOSE && f2.channel == 2)
	testing.expect(t, ipc.stream_channel(&p.a, 2) == nil)
}

@(test)
test_stream_peer_close_reports_closed :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer ipc.stream_conn_destroy(&p.b)
	ipc.stream_conn_destroy(&p.a)
	testing.expect_value(t, ipc.stream_fill(&p.b), ipc.Stream_Error.Closed)
}

@(test)
test_stream_control_overflow :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p, 0))
	defer pair_close(&p)
	big := make([]u8, ipc.STREAM_MAX_PAYLOAD)
	defer delete(big)
	testing.expect(t, ipc.stream_send(&p.a, _K_OUTPUT, 1, big))
	testing.expect(t, !ipc.stream_send(&p.a, _K_OUTPUT, 1, big))
	testing.expect_value(t, p.a.err, ipc.Stream_Error.Overflow)
}

@(test)
test_stream_send_receive_do_not_allocate :: proc(t: ^testing.T) {
	p: Pair
	testing.expect(t, pair_open(&p))
	defer pair_close(&p)
	ipc.stream_channel_open(&p.a, 4, true)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	payload := [64]u8{}
	for _ in 0..<100 {
		ipc.stream_send(&p.a, _K_INPUT, 4, payload[:])
		ipc.stream_data(&p.a, 4, payload[:])
		pump(&p)
		for f in ipc.stream_next(&p.b) do if f.kind == ipc.STREAM_DATA do ipc.stream_ack(&p.b, 4, len(f.payload))
		ipc.stream_flush(&p.b)
		ipc.stream_fill(&p.a)
		for _ in ipc.stream_next(&p.a) {}
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

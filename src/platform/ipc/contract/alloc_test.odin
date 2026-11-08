package platform_ipc_contract

// P36: once everything is open (server, client, one credited stream), 10 000
// client_call round trips and 10 000 stream frames each way allocate nothing,
// on either side and in either allocator.

import "core:mem"
import "core:testing"
import "core:time"
import ipc "../"

TEST_INPUT :: u8(30) // client → server stream frames; not a channel 0 kind

ALLOC_ROUNDS :: 10_000

// _stream_echo: JOB opens a credited stream to its peer and answers with the
// channel; stream input comes back on that channel; PING is echoed.
@(private = "file")
_stream_echo :: proc(o: ^Owner, ev: ipc.Server_Event) {
	#partial switch e in ev {
	case ipc.Request:
		if e.kind != TEST_JOB {
			echo(o, ev)
			return
		}
		ch, ok := ipc.server_stream_open(&o.srv, e.peer, true)
		if ok do reply_u32(&o.srv, e, ch)
		else do ipc.fail(&o.srv, e, 21, "no stream")
	case ipc.Stream_Input:
		ipc.server_stream_data(&o.srv, e.peer, e.channel, e.body)
	}
}

@(test)
test_P36_no_allocation_after_open :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = context.allocator
	o := Owner{handle = _stream_echo}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	zero := u32le_bytes(0)
	a, err := ipc.client_call(&c, TEST_JOB, zero[:])
	if !expect_ok(t, err, "JOB (open a stream)") do return
	channel, _ := answer_u32(a)
	before := track.total_allocation_count
	for i in 0 ..< ALLOC_ROUNDS do if !ping(t, &c, u32(i)) do return
	for i in 0 ..< ALLOC_ROUNDS do if !_stream_round(t, &c, channel, u32(i)) do return
	testing.expectf(t, track.total_allocation_count == before, "%d allocations after open", track.total_allocation_count - before)
}

// _stream_round sends one frame on channel and waits for its echo.
@(private = "file")
_stream_round :: proc(t: ^testing.T, c: ^ipc.Client, channel: u32, v: u32) -> bool {
	b := u32le_bytes(v)
	if !expect_ok(t, ipc.client_stream_send(c, channel, TEST_INPUT, b[:]), "client_stream_send") do return false
	for {
		ev, err := ipc.client_poll(c, time.Second)
		if !expect_ok(t, err, "client_poll") do return false
		data, is_data := ev.(ipc.Stream_Data)
		if !is_data || data.channel != channel do continue
		ipc.client_stream_ack(c, channel, len(data.bytes))
		return testing.expect(t, string(data.bytes) == string(b[:]), "the stream echo differs")
	}
}

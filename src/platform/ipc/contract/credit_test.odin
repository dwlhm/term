package platform_ipc_contract

// P40 (found in M3): stream DATA that waits for credit goes out as soon as
// the reader grants it, also when the server has nothing else to send. A
// CREDIT frame is applied while server_next reads the peer's input; nothing
// else may be needed to move the stream on.

import "core:testing"
import "core:time"
import ipc "../"

@(private = "file")
_BURST :: 2 * ipc.STREAM_WINDOW

// _burst: JOB opens a credited stream and queues _BURST bytes on it at once.
@(private = "file")
_burst :: proc(o: ^Owner, ev: ipc.Server_Event) {
	e, is_req := ev.(ipc.Request)
	if !is_req || e.kind != TEST_JOB {
		echo(o, ev)
		return
	}
	ch, ok := ipc.server_stream_open(&o.srv, e.peer, true)
	if !ok {
		ipc.fail(&o.srv, e, 21, "no stream")
		return
	}
	reply_u32(&o.srv, e, ch)
	data := make([]u8, _BURST, context.temp_allocator)
	ipc.server_stream_data(&o.srv, e.peer, ch, data)
}

@(test)
test_P40_credit_releases_waiting_data_on_an_idle_server :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o := Owner{handle = _burst}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	zero := u32le_bytes(0)
	a, err := ipc.client_call(&c, TEST_JOB, zero[:])
	if !expect_ok(t, err, "JOB (open a stream)") do return
	channel, _ := answer_u32(a)
	got := _read_until(&c, channel, ipc.STREAM_WINDOW, 3 * time.Second)
	if !testing.expectf(t, got == ipc.STREAM_WINDOW, "the first window brought %d bytes", got) do return
	ipc.client_stream_ack(&c, channel, got) // the server has nothing else to do now
	start := time.tick_now()
	got = _read_until(&c, channel, _BURST - ipc.STREAM_WINDOW, 3 * time.Second)
	testing.expectf(t, got == _BURST - ipc.STREAM_WINDOW, "after the credit only %d more bytes came", got)
	testing.expectf(t, ms_since(start) < 1000, "the rest took %.0f ms", ms_since(start))
}

// _read_until reads (without granting credit) until want bytes came or timeout.
@(private = "file")
_read_until :: proc(c: ^ipc.Client, channel: u32, want: int, timeout: time.Duration) -> (got: int) {
	deadline := time.tick_add(time.tick_now(), timeout)
	for got < want {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return
		ev, err := ipc.client_poll(c, left)
		if err.kind != .None do return
		if d, is_data := ev.(ipc.Stream_Data); is_data && d.channel == channel do got += len(d.bytes)
	}
	return
}

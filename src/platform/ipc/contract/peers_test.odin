package platform_ipc_contract

// P19, P21, P22: peers that hold resources. A peer that stops reading, never
// says HELLO or arrives when every slot is taken costs only itself.

import "core:sync"
import "core:testing"
import "core:time"
import ipc "../"

@(private = "file")
_Flood :: struct {
	stuck: ipc.Peer, // the first peer to join; it never reads
	have:  bool,
	sent:  int,
	left:  bool, // atomic: the stuck peer was dropped
}

@(private = "file")
_notice_body: [64 * 1024]u8

FLOOD_MAX :: 4096 // notices of 64 KiB: 256 MiB, far past any sane queue

// _flood_round notifies the stuck peer until the server drops it.
@(private = "file")
_flood_round :: proc(o: ^Owner) {
	f := (^_Flood)(o.data)
	o.due_ns = -1
	if !f.have || sync.atomic_load(&f.left) || f.sent >= FLOOD_MAX do return
	for _ in 0 ..< 16 do ipc.notify(&o.srv, f.stuck, TEST_CHANGED, _notice_body[:])
	f.sent += 16
	o.due_ns = now_ns() + 1_000_000
}

@(private = "file")
_flood_event :: proc(o: ^Owner, ev: ipc.Server_Event) {
	f := (^_Flood)(o.data)
	#partial switch e in ev {
	case ipc.Peer_Joined: if !f.have do f.stuck, f.have = e.peer, true
	case ipc.Peer_Left:   if f.have && e.peer == f.stuck do sync.atomic_store(&f.left, true)
	case ipc.Request:     echo(o, ev)
	}
}

@(test)
test_P19_peer_that_stops_reading_is_dropped :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	flood: _Flood
	o := Owner{data = &flood, handle = _flood_event, round = _flood_round}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	stuck, live: ipc.Client
	if !open_client(t, &stuck, {dir, "s"}) do return
	defer ipc.client_close(&stuck)
	if !open_client(t, &live, {dir, "s"}) do return
	defer ipc.client_close(&live)
	left := wait_until(20_000, proc(f: rawptr) -> bool { return sync.atomic_load(&(^_Flood)(f).left) }, &flood)
	testing.expect(t, left, "the peer that never reads was not dropped")
	ping(t, &live, 3)
}

@(test)
test_P21_connection_without_hello_is_dropped :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o: Owner
	if !owner_open(t, &o, {dir, "s"}, opts = {max_peers = 1, hello_ms = 300}) do return
	defer owner_close(&o)
	fd := raw_dial({dir, "s"})
	if !testing.expect(t, fd >= 0, "cannot connect") do return
	start := time.tick_now()
	closed := raw_closed(fd, 2000)
	ms := ms_since(start)
	testing.expect(t, closed, "a silent connection was never dropped")
	testing.expectf(t, ms >= 300 && ms <= 800, "dropped after %.0f ms, want 300..800", ms)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return // the slot is free again
	defer ipc.client_close(&c)
	ping(t, &c, 4)
}

@(test)
test_P22_one_peer_too_many_gets_busy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o: Owner
	if !owner_open(t, &o, {dir, "s"}, opts = {max_peers = 2, busy_reason = "full up"}) do return
	defer owner_close(&o)
	a, b, c: ipc.Client
	if !open_client(t, &a, {dir, "s"}) do return
	defer ipc.client_close(&a)
	if !open_client(t, &b, {dir, "s"}) do return
	defer ipc.client_close(&b)
	err := ipc.client_open(&c, {dir, "s"}, test_protocol(), {role = TEST_ROLE_CLIENT})
	defer ipc.client_close(&c)
	expect_kind(t, err, .Busy, "third client_open")
	testing.expect_value(t, err.reason, "full up")
}

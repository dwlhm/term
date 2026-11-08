package platform_ipc_contract

// P8–P12: client_call against a live Server. Answers carry no req, FAIL
// becomes a typed Error, deadlines hold, a vanished server ends a wait at
// once, and notices reach on_event without losing the answer.

import "core:sync"
import "core:testing"
import "core:time"
import ipc "../"

@(test)
test_P8_call_gets_its_answer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o: Owner
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	b := u32le_bytes(42)
	a, err := ipc.client_call(&c, TEST_PING, b[:])
	if !expect_ok(t, err, "PING") do return
	testing.expect_value(t, a.kind, TEST_PONG)
	testing.expect_value(t, len(a.body), 4) // the u32 we sent, without req
	v, _ := answer_u32(a)
	testing.expect_value(t, v, 42)
}

@(test)
test_P9_application_fail_code_reaches_the_client :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o := Owner{handle = proc(o: ^Owner, ev: ipc.Server_Event) {
		if req, ok := ev.(ipc.Request); ok do ipc.fail(&o.srv, req, 20, "held by x")
	}}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	b := u32le_bytes(1)
	_, err := ipc.client_call(&c, TEST_PING, b[:])
	expect_kind(t, err, .Failed, "PING")
	testing.expect_value(t, err.code, 20)
	testing.expect_value(t, err.reason, "held by x")
}

// hold keeps every request open and never answers.
hold :: proc(o: ^Owner, ev: ipc.Server_Event) {}

@(test)
test_P10_unanswered_call_times_out_at_5s :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o := Owner{handle = hold}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	b := u32le_bytes(1)
	start := time.tick_now()
	_, err := ipc.client_call(&c, TEST_PING, b[:])
	ms := ms_since(start)
	expect_kind(t, err, .Timeout, "PING")
	testing.expectf(t, ms >= 4500 && ms <= 5500, "timed out after %.0f ms, want 5000 ± 10%%", ms)
}

@(private = "file")
_closed_at: i64 // atomic: when the owner closed its server

@(test)
test_P11_server_gone_ends_a_forever_wait :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o := Owner{handle = proc(o: ^Owner, ev: ipc.Server_Event) {
		if _, ok := ev.(ipc.Request); !ok do return
		sync.atomic_store(&_closed_at, now_ns())
		ipc.server_close(&o.srv)
	}}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	b := u32le_bytes(1)
	_, err := ipc.client_call(&c, TEST_PING, b[:], {timeout = ipc.WAIT_FOREVER})
	ms := f64(now_ns() - sync.atomic_load(&_closed_at)) / 1e6
	expect_kind(t, err, .Closed, "PING")
	testing.expectf(t, ms <= 50, ".Closed came %.1f ms after the server closed", ms)
}

@(private = "file")
_Notices :: struct {
	count:   int,
	kind:    u8,
	body_ok: bool, // the body is only valid inside on_event
}

@(test)
test_P12_notice_before_the_answer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o := Owner{handle = proc(o: ^Owner, ev: ipc.Server_Event) {
		if req, ok := ev.(ipc.Request); ok {
			ipc.notify(&o.srv, ipc.Notify_All{}, TEST_CHANGED, transmute([]u8)string("changed"))
			reply_u32(&o.srv, req, 7)
		}
	}}
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	c: ipc.Client
	if !open_client(t, &c, {dir, "s"}) do return
	defer ipc.client_close(&c)
	seen: _Notices
	on_event :: proc(data: rawptr, ev: ipc.Client_Event) -> ipc.Event_Action {
		n := (^_Notices)(data)
		if e, ok := ev.(ipc.Notice); ok do n.count, n.kind, n.body_ok = n.count + 1, e.kind, string(e.body) == "changed"
		return .Continue
	}
	b := u32le_bytes(7)
	a, err := ipc.client_call(&c, TEST_PING, b[:], {on_event = on_event, data = &seen})
	if !expect_ok(t, err, "PING") do return
	testing.expect_value(t, a.kind, TEST_PONG)
	testing.expect_value(t, seen.count, 1)
	testing.expect_value(t, seen.kind, TEST_CHANGED)
	testing.expect(t, seen.body_ok, "the notice body did not arrive intact")
}

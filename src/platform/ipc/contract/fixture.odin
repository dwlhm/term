package platform_ipc_contract

// Contract tests of the IPC package, written before the package (spec section
// 10). They use a protocol of their own, not term's messages, so passing them
// also shows the package works outside term. `make test-ipc-contract` runs them
// and lists the IDs still red; once every test of an ID passes, they join
// IPC_GREEN_TESTS in the Makefile, so `make test` runs them too.

import "core:testing"
import ipc "../"

TEST_ROLE_CLIENT :: u8(1)
TEST_VERSION :: ipc.Version{0, 1, 0}

// A small catalog: one plain request, one with progress, one notice. Every
// request body is one u32; PONG echoes it, JOB_DONE carries the step count.
TEST_PING     :: u8(20) // → TEST_PONG
TEST_PONG     :: u8(21)
TEST_JOB      :: u8(22) // → TEST_JOB_DONE, with TEST_JOB_STEP progress
TEST_JOB_DONE :: u8(23)
TEST_JOB_STEP :: u8(24)
TEST_CHANGED  :: u8(25) // notice

test_catalog := [?]ipc.Msg_Spec{
	{request = TEST_PING, answer = TEST_PONG},
	{request = TEST_JOB, answer = TEST_JOB_DONE, progress = TEST_JOB_STEP},
	{request = TEST_CHANGED, notice = true},
}

test_protocol :: proc() -> ipc.Protocol {
	return {name = "ipc contract", version = TEST_VERSION, roles = {int(TEST_ROLE_CLIENT)}, catalog = test_catalog[:]}
}

// Messages that the package rejects in test builds (spec 7.2).
ASSERT_RESERVED_FAIL :: "ipc: FAIL_VERSION is the handshake's"
ASSERT_SECOND_REPLY  :: "ipc: request already answered"

dec_u32 :: proc(r: ^ipc.Wire_Reader) -> u32 { return ipc.wr_u32(r) }

answer_u32 :: proc(a: ipc.Answer) -> (v: u32, ok: bool) {
	r := ipc.wire_reader(a.body)
	v = ipc.wr_u32(&r)
	return v, ipc.wr_done(&r)
}

// open_client opens c on at as TEST_ROLE_CLIENT.
open_client :: proc(t: ^testing.T, c: ^ipc.Client, at: ipc.Endpoint, proto: Maybe(ipc.Protocol) = nil, loc := #caller_location) -> bool {
	return expect_ok(t, ipc.client_open(c, at, proto.? or_else test_protocol(), {role = TEST_ROLE_CLIENT}), "client_open", loc)
}

// ping calls PING(v) and checks that PONG echoes v.
ping :: proc(t: ^testing.T, c: ^ipc.Client, v: u32, opts := ipc.Call_Opts{}, loc := #caller_location) -> bool {
	b := u32le_bytes(v)
	a, err := ipc.client_call(c, TEST_PING, b[:], opts)
	if !expect_ok(t, err, "PING", loc) do return false
	got, ok := answer_u32(a)
	testing.expectf(t, a.kind == TEST_PONG && ok && got == v, "PING %d answered kind %d body %v", v, a.kind, a.body, loc = loc)
	return a.kind == TEST_PONG && ok && got == v
}

// reply_u32 answers req with one u32 body.
reply_u32 :: proc(s: ^ipc.Server, req: ipc.Request, v: u32) {
	b := u32le_bytes(v)
	ipc.reply(s, req, b[:])
}

// echo answers PING with its own value and ignores everything else.
echo :: proc(o: ^Owner, ev: ipc.Server_Event) {
	req, ok := ev.(ipc.Request)
	if !ok || req.kind != TEST_PING do return
	v: u32
	if ipc.request_decode(&req, &v, dec_u32) do reply_u32(&o.srv, req, v)
}

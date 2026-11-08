package feature_session_core_tests

// P34: a worker whose NEXT times out just as it sends ANSWER (the runner
// serve race of IPC spec G2). Over one ipc.Client on the session link 0.1.0,
// ANSWER gets its own OK and NEXT's FAIL Timeout arrives as a Late_Answer
// for NEXT's ticket. Red until M3, so it only builds with
// -define:IPC_CONTRACT=true, which `make test-ipc-contract` passes; `make
// test` never runs it.

import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

IPC_CONTRACT :: #config(IPC_CONTRACT, false)

when IPC_CONTRACT {

@(private = "file")
_Late :: struct {
	ticket: ipc.Ticket,
	seen:   bool,
	err:    ipc.Error,
}

@(private = "file")
_late :: proc(data: rawptr, ev: ipc.Client_Event) -> ipc.Event_Action {
	l := (^_Late)(data)
	if e, ok := ev.(ipc.Late_Answer); ok && e.ticket == l.ticket do l.seen, l.err = true, e.err
	return .Continue
}

@(private = "file")
_next :: proc(c: ^ipc.Client, sid: u32, timeout_ms: u32) -> (ipc.Ticket, ipc.Error) {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, sid)
	ipc.ww_u32(&w, timeout_ms)
	return ipc.client_start(c, proto.MSG_NEXT, ipc.wire_bytes_written(&w))
}

// _take waits for the request that the NEXT with ticket tk took.
@(private = "file")
_take :: proc(c: ^ipc.Client, tk: ipc.Ticket) -> (req: proto.Next_Result, ok: bool) {
	ev, err := ipc.client_poll(c, 3 * time.Second)
	la, is_late := ev.(ipc.Late_Answer)
	if err.kind != .None || !is_late || la.ticket != tk || la.answer.kind != proto.MSG_REQUEST do return
	r := ipc.wire_reader(la.answer.body)
	req = proto.dec_next_result(&r)
	return req, r.ok
}

@(test)
test_P34_next_timing_out_during_answer_is_a_late_answer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30")) // the worker's session
	c: ipc.Client
	err := ipc.client_open(&c, {tiers.dir, "core.sock"}, proto.session(), {role = u8(proto.Stream_Role.Cli)})
	if testing.expectf(t, err.kind == .None, "client_open: %v %q", err.kind, err.reason) do _answer_as_next_times_out(t, &c, v, w)
	ipc.client_close(&c)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(private = "file")
_answer_as_next_times_out :: proc(t: ^testing.T, c: ^ipc.Client, v: ^View, w: u32) {
	first, err := _next(c, w, 0)
	if !testing.expectf(t, err.kind == .None, "NEXT: %v", err.kind) do return
	for i := 0; i < 100; i += 1 {
		obs, _, _ := cli_observe(w)
		if obs.row.request.listening > 0 do break
		view_pump(v, 5)
	}
	sc: ipc.Stream_Conn
	defer ipc.stream_conn_destroy(&sc)
	res, _ := tell_send(&sc, {to = w, body = "job"})
	if !testing.expect(t, res.phase == .Accepted, "the waiting worker did not accept the request") do return
	req, took := _take(c, first)
	if !testing.expect(t, took, "the first NEXT's REQUEST did not come as its Late_Answer") do return
	second: ipc.Ticket
	second, err = _next(c, w, 200)
	if !testing.expectf(t, err.kind == .None, "second NEXT: %v", err.kind) do return
	time.sleep(200 * time.Millisecond) // the second NEXT times out about now
	b: [128]u8
	aw := ipc.wire_writer(b[:])
	proto.enc_answer(&aw, {by = w, id = req.id, text = "done"})
	late := _Late{ticket = second}
	a: ipc.Answer
	a, err = ipc.client_call(c, proto.MSG_ANSWER, ipc.wire_bytes_written(&aw), {on_event = _late, data = &late})
	testing.expect(t, err.kind == .None && a.kind == proto.MSG_OK, "ANSWER did not get its own OK")
	for i := 0; i < 10 && !late.seen; i += 1 {
		ev, _ := ipc.client_poll(c, 100 * time.Millisecond)
		_late(&late, ev)
	}
	testing.expect(t, late.seen, "NEXT's FAIL Timeout never came as its Late_Answer")
	testing.expectf(t, late.err.kind == .Failed && late.err.code == ipc.FAIL_TIMEOUT, "NEXT ended with %v code %d", late.err.kind, late.err.code)
}

} // when IPC_CONTRACT

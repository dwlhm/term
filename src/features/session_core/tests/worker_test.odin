package feature_session_core_tests

// Workers through a real core: a connection waiting in `next` for a session
// takes requests to it, reports progress and answers; slots, rejection,
// results read later, timeouts, a worker that goes away, and a child request
// to a shell that ends with its parent.

import "core:strings"
import "core:testing"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

// worker_next opens a worker connection for sid and sends MSG_NEXT.
@(private = "file")
worker_next :: proc(conn: ^Cli, sid: u32, timeout_ms: u32 = 0) -> bool {
	if !cli_conn(conn) do return false
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, sid); ipc.ww_u32(&w, timeout_ms)
	cli_send(conn, proto.MSG_NEXT, ipc.wire_bytes_written(&w))
	return true
}

// worker_take waits for the request a `next` took (fail: the FAIL code).
@(private = "file")
worker_take :: proc(conn: ^Cli, ms := 3000) -> (req: proto.Next_Result, fail: proto.Fail_Code) {
	for {
		f, got := cli_frame(conn, ms)
		if !got do return {}, .Busy
		switch f.kind {
		case proto.MSG_FAIL:
			r := ipc.wire_reader(f.payload)
			_ = ipc.wr_u32(&r)
			return {}, proto.Fail_Code(ipc.wr_u8(&r))
		case proto.MSG_REQUEST:
			r := ipc.wire_reader(f.payload)
			req = proto.dec_next_result(&r)
			req.body = strings.clone(req.body, context.temp_allocator)
			return req, {}
		}
	}
}

@(private = "file")
worker_say :: proc(by: u32, id: u64, text: string, final: bool, failed := false) -> proto.Fail_Code {
	conn: Cli
	if !cli_conn(&conn) do return .Busy
	defer cli_close(&conn)
	b: [512]u8
	w := ipc.wire_writer(b[:])
	proto.enc_answer(&w, {by = by, id = id, failed = failed, text = text})
	cli_send(&conn, proto.MSG_ANSWER if final else proto.MSG_PROGRESS, ipc.wire_bytes_written(&w))
	for {
		f, got := cli_frame(&conn, 3000)
		if !got do return .Busy
		if f.kind == proto.MSG_OK do return {}
		if f.kind == proto.MSG_FAIL {
			r := ipc.wire_reader(f.payload)
			_ = ipc.wr_u32(&r)
			return proto.Fail_Code(ipc.wr_u8(&r))
		}
	}
}

@(private = "file")
listening :: proc(id: u32) -> u32 {
	obs, _, _ := cli_observe(id)
	return obs.row.request.listening
}

@(test)
test_worker_takes_reports_and_answers :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30")) // the worker's session: any program
	wc: Cli
	testing.expect(t, worker_next(&wc, w), "next")
	for i := 0; i < 100 && listening(w) == 0; i += 1 do view_pump(v, 5)
	testing.expect_value(t, listening(w), 1)

	sc: Cli
	res, _ := tell_send(&sc, {to = w, body = "review\nsrc/foo.odin"})
	testing.expect(t, res.phase == .Accepted, "accepted by the waiting worker")
	req, fail := worker_take(&wc)
	testing.expect(t, fail == {} && req.id == res.id && req.body == "review\nsrc/foo.odin", "the worker got it whole")
	other: Cli
	busy, _ := tell_send(&other, {to = w, body = "x"})
	cli_close(&other)
	testing.expect_value(t, busy.reject, proto.Tell_Reject.Busy)

	testing.expect_value(t, worker_say(w + 1000, req.id, "x", true), proto.Fail_Code.Bad_Request) // not its request
	testing.expect_value(t, worker_say(w, req.id, "half way", false), proto.Fail_Code{})
	prog, _ := tell_next(&sc, 3000)
	testing.expect(t, prog.phase == .Progress && prog.progress == "half way", "the sender hears progress")
	testing.expect_value(t, worker_say(w, req.id, "foo looks fine", true), proto.Fail_Code{})
	fin, _ := tell_next(&sc, 3000)
	testing.expect(t, fin.phase == .Finished && fin.status == .Done && fin.text == "foo looks fine", "the answer")
	testing.expect_value(t, worker_say(w, req.id, "again", true), proto.Fail_Code.Not_Found) // taken by its sender
	cli_close(&wc)
	cli_close(&sc)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// A session still starting: the request waits for whichever is ready first.
// One past its start that neither listens nor shows a prompt rejects it.
@(test)
test_worker_start_window_timeouts_and_departure :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30")) // young, no prompt, no worker yet
	c, wc: Cli
	r0, _ := tell_send(&c, {to = w, body = "early"})
	testing.expect(t, r0.phase == .Accepted, "held: the session is still starting")
	worker_next(&wc, w)
	req, fail := worker_take(&wc)
	testing.expect(t, fail == {} && req.id == r0.id && req.body == "early", "the first worker takes it")
	worker_say(w, req.id, "ok", true)
	fin, _ := tell_next(&c, 3000)
	testing.expect(t, fin.text == "ok", "answered")
	cli_close(&c)
	cli_close(&wc)

	settled := view_attached(v, view_sh(v, `printf '\033]133;C\007\033]133;D;0\007'; sleep 30`)) // past its start, no prompt
	for i := 0; i < 200; i += 1 {
		obs, _, _ := cli_observe(settled)
		if obs.cmd_seq > 0 do break
		view_pump(v, 5)
	}
	r1, _ := tell_send(&c, {to = settled, body = "x"})
	cli_close(&c)
	testing.expect_value(t, r1.reject, proto.Tell_Reject.Not_Listening)

	worker_next(&wc, settled, 200)
	_, fail = worker_take(&wc)
	testing.expect_value(t, fail, proto.Fail_Code.Timeout)
	cli_close(&wc)

	worker_next(&wc, settled)
	for i := 0; i < 100 && listening(settled) == 0; i += 1 do view_pump(v, 5)
	cli_close(&wc) // the worker went away before any request
	for i := 0; i < 100 && listening(settled) != 0; i += 1 do view_pump(v, 5)
	r2, _ := tell_send(&c, {to = settled, body = "x"})
	cli_close(&c)
	testing.expect_value(t, r2.reject, proto.Tell_Reject.Not_Listening)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// The worker's request uses a shell; cancelling it stops that command too.
@(test)
test_worker_child_request_ends_with_parent :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30"))
	sh := view_attached(v, view_sh(v, TELL_REPL))
	wc, sc, cc: Cli
	worker_next(&wc, w)
	for i := 0; i < 100 && listening(w) == 0; i += 1 do view_pump(v, 5)
	parent, _ := tell_send(&sc, {to = w, body = "build it"})
	req, _ := worker_take(&wc)
	child, _ := tell_send(&cc, {to = sh, from = w, body = "sleep 30"}) // sent while working on #parent
	testing.expect(t, child.phase == .Accepted && req.id == parent.id, "child accepted")
	for i := 0; i < 300; i += 1 {
		obs, _, _ := cli_observe(sh)
		if obs.prompt_state == .Executing do break
		view_pump(v, 5)
	}
	testing.expect(t, tell_cancel(parent.id), "cancel the parent")
	pres, _ := tell_next(&sc, 3000)
	cres, _ := tell_next(&cc, 3000)
	testing.expect(t, pres.status == .Cancelled && cres.status == .Cancelled, "both ended")
	testing.expect_value(t, worker_say(w, req.id, "late", true), proto.Fail_Code.Not_Found) // ended, and its sender took the result
	// SIGINT ends `sleep` (and this plain sh REPL with it): no longer running it.
	stopped := false
	for i := 0; i < 400 && !stopped; i += 1 {
		obs, ok, _ := cli_observe(sh)
		stopped = !ok || obs.row.state == .Exited || (obs.prompt_state == .Input && obs.cmd_exit_code != 0)
		if !stopped do view_pump(v, 5)
	}
	testing.expect(t, stopped, "the child's command was interrupted")
	cli_close(&wc)
	cli_close(&sc)
	cli_close(&cc)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_worker_async_result_read_and_wait :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30"))
	wc: Cli
	worker_next(&wc, w)
	for i := 0; i < 100 && listening(w) == 0; i += 1 do view_pump(v, 5)
	ac: Cli
	if !cli_conn(&ac) do return
	b: [256]u8
	ww := ipc.wire_writer(b[:])
	proto.enc_tell_req(&ww, {to = w, body = "async task"}) // no wait
	cli_send(&ac, proto.MSG_TELL, ipc.wire_bytes_written(&ww))
	acc, _ := tell_next(&ac, 3000)
	cli_close(&ac) // the sender may go: the request stays
	req, _ := worker_take(&wc)
	testing.expect(t, acc.phase == .Accepted && req.id == acc.id, "taken")

	rc: Cli
	cli_conn(&rc)
	ww = ipc.wire_writer(b[:])
	proto.enc_result_req(&ww, {wait = true, ids = {0 = acc.id, 1 = acc.id + 77}, n_ids = 1, timeout_ms = 3000})
	cli_send(&rc, proto.MSG_RESULT, ipc.wire_bytes_written(&ww))
	for i := 0; i < 100; i += 1 do view_pump(v, 2) // the wait is registered before the answer
	worker_say(w, req.id, "done later", true)
	fin, _ := tell_next(&rc, 3000)
	testing.expect(t, fin.phase == .Finished && fin.text == "done later", "result --wait")
	cli_close(&wc)
	cli_close(&rc)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// A worker's `next` for a session that ends is answered, so it does not wait forever.
@(test)
test_worker_next_ends_with_its_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	w := view_attached(v, view_sh(v, "sleep 30"))
	wc: Cli
	worker_next(&wc, w)
	for i := 0; i < 100 && listening(w) == 0; i += 1 do view_pump(v, 5)
	testing.expect(t, cli_kill(w), "kill the worker's session")
	_, fail := worker_take(&wc)
	testing.expect_value(t, fail, proto.Fail_Code.Not_Found)
	cli_close(&wc)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

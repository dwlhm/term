package feature_session_core_tests

// Verification of event-driven watch & wake notifications.

import "core:testing"
import "core:thread"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
cli_watch :: proc(id: u32, events: proto.Watch_Event_Flags, timeout_ms: u32) -> (res: proto.Watch_Result, ok, timed_out: bool) {
	fail: proto.Fail_Code
	res, fail = cli_watch_req({id = id, events = events, timeout_ms = timeout_ms})
	return res, fail == {}, fail == .Timeout
}

// cli_watch_req sends one watch; fail is the FAIL code ({} = answered).
@(private = "file")
cli_watch_req :: proc(req: proto.Watch_Request) -> (res: proto.Watch_Result, fail: proto.Fail_Code) {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return {}, .Bad_Request
	defer ipc.stream_conn_destroy(&conn)
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_watch_req(&w, req)
	ipc.stream_send(&conn, proto.MSG_WATCH, 0, ipc.wire_bytes_written(&w))
	for {
		f, got := client.client_wait_frame(&conn, int(req.timeout_ms + 2000))
		if !got do return {}, .Busy
		switch f.kind {
		case proto.MSG_FAIL:
			r := ipc.wire_reader(f.payload)
			_ = ipc.wr_u32(&r)
			return {}, proto.Fail_Code(ipc.wr_u8(&r))
		case proto.MSG_WATCH_RESULT:
			r := ipc.wire_reader(f.payload)
			res = proto.dec_watch_result(&r)
			return res, {} if r.ok else .Bad_Request
		}
	}
}

@(test)
test_watch_blocking_on_exit :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 0.2")
	id := view_attached(v, s)
	defer {
		view_close(v)
		tiers_stop(tiers)
	}

	t0 := time.now()
	res, ok, timed_out := cli_watch(id, {.Exit}, 3000)
	dur := time.duration_milliseconds(time.since(t0))

	testing.expect(t, ok, "watch succeeded")
	testing.expect(t, !timed_out, "did not time out")
	testing.expect_value(t, res.id, id)
	testing.expect_value(t, res.event, proto.Watch_Event.Exit)
	testing.expect_value(t, res.exit_code, 0)
	testing.expect(t, dur >= 150 && dur < 2500, "woke promptly on exit")
}

@(test)
test_watch_blocking_on_prompt :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	cmd := "/bin/sh -c 'printf \"\\033]133;C\\007\"; /bin/sleep 0.2; printf \"\\033]133;D;0\\007\"; /bin/sleep 1'"
	s := view_sh(v, cmd)
	id := view_attached(v, s)
	defer {
		view_close(v)
		tiers_stop(tiers)
	}

	t0 := time.now()
	res, ok, timed_out := cli_watch(id, {.Prompt}, 3000)
	dur := time.duration_milliseconds(time.since(t0))

	testing.expect(t, ok, "watch prompt succeeded")
	testing.expect(t, !timed_out, "did not time out")
	testing.expect_value(t, res.id, id)
	testing.expect_value(t, res.event, proto.Watch_Event.Prompt)
	testing.expect_value(t, res.exit_code, 0)
	testing.expect(t, dur >= 150 && dur < 2500, "woke promptly on prompt")
}

@(test)
test_watch_timeout :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 5")
	id := view_attached(v, s)
	defer {
		view_close(v)
		tiers_stop(tiers)
	}

	t0 := time.now()
	res, ok, timed_out := cli_watch(id, {.Exit}, 200)
	dur := time.duration_milliseconds(time.since(t0))

	testing.expect(t, !ok, "watch ok false on timeout")
	testing.expect(t, timed_out, "timed out flag set")
	testing.expect(t, dur >= 150 && dur < 1000, "timed out in expected window")
}

// A command that finished before the watch arrived still answers it: the
// caller passes the cmd_seq it saw before typing (`--since`).
@(test)
test_watch_since_answers_finished_command :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, `printf '\033]133;C\007\033]133;D;5\007\033]133;A\007$ \033]133;B\007'; sleep 30`)
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "$"), "prompt drawn")
	res, fail := cli_watch_req({id = id, events = {.Prompt}, timeout_ms = 3000, has_since = true, since = 0})
	testing.expect_value(t, fail, proto.Fail_Code{})
	testing.expect_value(t, res.event, proto.Watch_Event.Prompt)
	testing.expect_value(t, res.exit_code, 5)
	testing.expect_value(t, res.cmd_seq, 1)
	_, fail = cli_watch_req({id = id, events = {.Prompt}, timeout_ms = 200, has_since = true, since = 1})
	testing.expect_value(t, fail, proto.Fail_Code.Timeout)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// A fast command's start, end and next prompt in one chunk leave the prompt
// state unchanged (Input → Input): cmd_seq is what shows it ran.
@(test)
test_watch_fast_command_in_one_chunk :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	script := `printf '\033]133;A\007$ \033]133;B\007'; sleep 0.5; printf '\033]133;C\007\033]133;D;3\007\033]133;A\007$ \033]133;B\007'; sleep 30`
	s := view_sh(v, script)
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "$"), "first prompt drawn")
	res, fail := cli_watch_req({id = id, events = {.Prompt}, timeout_ms = 3000})
	testing.expect_value(t, fail, proto.Fail_Code{})
	testing.expect_value(t, res.exit_code, 3)
	testing.expect_value(t, res.cmd_seq, 1)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_watch_answers_at_once_for_exited_and_removed :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	gone := view_sh(v, "exit 4")
	gone_id := view_attached(v, gone)
	testing.expect(t, view_wait_row(v, gone_id, .Exited) >= 0, "program exited")
	res, fail := cli_watch_req({id = gone_id, events = {.Prompt}, timeout_ms = 3000})
	testing.expect_value(t, fail, proto.Fail_Code{})
	testing.expect_value(t, res.event, proto.Watch_Event.Exit)
	testing.expect_value(t, res.exit_code, 4)

	live := view_attached(v, view_sh(v, "sleep 30"))
	Killer :: struct { id: u32 }
	k := Killer{live}
	th := thread.create_and_start_with_data(&k, proc(d: rawptr) {
		time.sleep(300 * time.Millisecond)
		_ = cli_kill((^Killer)(d).id)
	})
	_, fail = cli_watch_req({id = live, events = {.Prompt}, timeout_ms = 5000})
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, fail, proto.Fail_Code.Not_Found)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

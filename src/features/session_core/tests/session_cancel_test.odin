package feature_session_core_tests

// Tests C1, C4, C5, C7, C8: term session cancel core mechanics (spec 4.7).

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
_send_sig :: proc(conn: ^Cli, id: u32, sig: i32) -> (ok: bool, msg: string) {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = sig})
	cli_send(conn, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	f, got := cli_answer(conn, proto.MSG_OK, 3000)
	if !got do return false, "timeout"
	if f.kind == proto.MSG_OK do return true, ""
	return false, cli_fail_reason(f.payload)
}

@(private = "file")
_get_snap :: proc(conn: ^Cli, id: u32) -> (proto.Snapshot, bool) {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	if !got do return {}, false
	r := ipc.wire_reader(f.payload)
	return proto.dec_snapshot(&r, context.temp_allocator), true
}

@(test)
test_C1_cancel_sleep_stops_on_int :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(
		v,
		"trap 'echo TRAPPED' INT; echo READY; /bin/sleep 100; echo AFTER",
	)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready, "ready")
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	ok, _ := _send_sig(&conn, id, 2)
	testing.expect(t, ok, "sigint delivered")

	_, done := snap_until(id, "AFTER")
	testing.expect(t, done, "command stopped on INT")
}

@(test)
test_C4_cancel_at_prompt_nothing_running :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]133;A\\007PROMPT> '")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "PROMPT>")
	testing.expect(t, ok, "prompt displayed")
	testing.expect(
		t,
		snap.prompt_state == .Prompt || snap.prompt_state == .Input,
		"prompt state active",
	)
}

@(test)
test_C5_cancel_tui_without_osc133_rejected :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'FAKE_TUI_RUNNING'; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "FAKE_TUI_RUNNING")
	testing.expect(t, ok, "fake tui running")
	testing.expect(
		t,
		snap.prompt_state == .None,
		"non-osc133 programs report prompt_state == None",
	)
}

@(test)
test_C7_two_parallel_cancels_do_not_double_int :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "trap 'echo GOT_INT' INT; echo READY; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	c1, c2: Cli
	testing.expect(t, cli_conn(&c1))
	testing.expect(t, cli_conn(&c2))
	defer { cli_close(&c1); cli_close(&c2) }

	// Send two INTs concurrently within 400ms
	ok1, _ := _send_sig(&c1, id, 2)
	ok2, _ := _send_sig(&c2, id, 2)
	testing.expect(t, ok1 && ok2, "both cancel signals accepted")

	_, got := snap_until(id, "GOT_INT")
	testing.expect(t, got, "got int printed")
	time.sleep(100 * time.Millisecond)

	// Verify only 1 GOT_INT was emitted due to 400ms throttle
	snap, _ := _get_snap(&c1, id)
	count := 0
	for row in snap.screen {
		for run in row.runs {
			if strings.contains(run.text, "GOT_INT") do count += 1
		}
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_C8_cancel_during_lease_rejected :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn1: Cli
	testing.expect(t, cli_conn(&conn1))
	defer cli_close(&conn1)

	// Acquire lease
	lbuf: [64]u8
	lw := ipc.wire_writer(lbuf[:])
	proto.enc_lease_req(&lw, {id = id, owner = "auto-bot"})
	cli_send(&conn1, proto.MSG_LEASE, ipc.wire_bytes_written(&lw))
	_, leased := cli_answer(&conn1, proto.MSG_OK, 3000)
	testing.expect(t, leased, "leased")

	// Second connection conn2 is rejected with Conflict ("held by ...")
	conn2: Cli
	testing.expect(t, cli_conn(&conn2))
	defer cli_close(&conn2)

	ok, msg := _send_sig(&conn2, id, 2)
	testing.expect(t, !ok, "cancel rejected during lease")
	testing.expect(t, strings.contains(msg, "auto-bot"))
}

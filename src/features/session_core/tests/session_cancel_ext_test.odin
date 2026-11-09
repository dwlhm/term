package feature_session_core_tests

// Tests C2, C3, C6, C9: term session cancel edge cases (spec 4.7).

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
_send_sig :: proc(conn: ^Cli, id: u32, sig: i32) -> bool {
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = sig})
	cli_send(conn, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	_, got := cli_answer(conn, proto.MSG_OK, 3000)
	return got
}

@(test)
test_C2_cancel_repeats_int_for_trap_int :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Traps first INT, untraps on second
	s := view_sh(
		v,
		"trap 'echo FIRST_INT; trap - INT' INT; " +
		"echo READY; /bin/sleep 100; echo DONE",
	)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// First INT delivered
	testing.expect(t, _send_sig(&conn, id, 2))
	_, first := snap_until(id, "FIRST_INT")
	testing.expect(t, first, "first int trapped")

	// Wait 500ms (cancel interval) then send second INT
	time.sleep(500 * time.Millisecond)
	testing.expect(t, _send_sig(&conn, id, 2))

	// Second INT terminates sleep
	_, done := snap_until(id, "DONE")
	testing.expect(t, done, "second int stopped command")
}

@(test)
test_C3_cancel_deaf_int_no_auto_escalation :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Deaf to INT: trap '' INT
	s := view_sh(v, "trap '' INT; echo READY; /bin/sleep 100")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Send INT: command ignores it
	testing.expect(t, _send_sig(&conn, id, 2))
	time.sleep(300 * time.Millisecond)

	// Session is STILL running, no SIGKILL was escalated
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect(t, !snap.exited, "process not killed by cancel")
}

@(test)
test_C6_cancel_process_exited_during_cancel :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY; /bin/sleep 0.1; exit 42")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready)

	// Wait for process to exit
	time.sleep(250 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)

	testing.expect(t, snap.exited, "session exited detected")
	testing.expect_value(t, snap.exit_code, 42)
}

@(test)
test_C9_cancel_interactive_repl_does_not_return_prompt :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	cmd := "printf '\\033]133;A\\007PROMPT>\\033]133;C\\007'; " +
		"trap 'echo REPL_INT' INT; /bin/sleep 100"
	s := view_sh(v, cmd)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "PROMPT>")
	testing.expect(t, ready)
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	testing.expect(t, _send_sig(&conn, id, 2))
	_, caught := snap_until(id, "REPL_INT")
	testing.expect(t, caught)

	// Verify prompt state has not returned to Prompt
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	snap := proto.dec_snapshot(&r, context.temp_allocator)

	testing.expect(
		t,
		snap.prompt_state != .Prompt,
		"prompt has not returned to shell prompt",
	)
}

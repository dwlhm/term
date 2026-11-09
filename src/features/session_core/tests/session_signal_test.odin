package feature_session_core_tests

// Tests G1, G4–G6: term session signal semantics and process group delivery.

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_G1_signal_int_terminates_foreground_job :: proc(t: ^testing.T) {
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

	// Send SIGINT (2) to foreground job
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = 2})
	cli_send(&conn, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_OK, 3000)
	testing.expect(t, got, "signal accepted")

	// Sleep ended, shell remains alive and prints AFTER
	_, ok := snap_until(id, "AFTER")
	testing.expect(t, ok, "sleep was killed, shell continued execution")
}

@(test)
test_G4_signal_sent_to_entire_foreground_pgrp :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(
		v,
		"trap 'echo TRAPPED' INT; echo READY; " +
		"/bin/sleep 100 | /usr/bin/grep foo; echo PIPE_DONE",
	)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	_, ready := snap_until(id, "READY")
	testing.expect(t, ready, "ready")
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Send SIGINT to pipeline
	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = 2})
	cli_send(&conn, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_OK, 3000)
	testing.expect(t, got)

	_, ok := snap_until(id, "PIPE_DONE")
	testing.expect(t, ok, "entire pipeline was terminated by signal")
}

@(test)
test_G5_signal_to_exited_session_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "exit 0")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(200 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [32]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = 15})
	cli_send(&conn, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Exited)
	testing.expect_value(t, cli_fail_reason(f.payload), "session has exited")
}

@(test)
test_G6_signal_during_lease_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 10")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn1: Cli
	testing.expect(t, cli_conn(&conn1))
	defer cli_close(&conn1)

	// Acquire lease
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_lease_req(&w, {id = id, owner = "flow.lua:test"})
	cli_send(&conn1, proto.MSG_LEASE, ipc.wire_bytes_written(&w))
	_, got_lease := cli_answer(&conn1, proto.MSG_OK, 3000)
	testing.expect(t, got_lease)

	// Second client tries to send signal
	conn2: Cli
	testing.expect(t, cli_conn(&conn2))
	defer cli_close(&conn2)

	w = ipc.wire_writer(buf[:])
	proto.enc_signal_req(&w, {id = id, signal = 2})
	cli_send(&conn2, proto.MSG_SESSION_SIGNAL, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn2, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Busy)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "flow.lua:test"),
	)
}

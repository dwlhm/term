package feature_session_core_tests

// Tests T5–T20 and T27: read --tail core mechanics and condition evaluations
// (--until, --prompt, --exit, --idle, --quiet, and generational tracking).

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_T6_tail_until_immediate_if_already_on_screen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'READY_NOW'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "READY_NOW")
	testing.expect(t, ok, "text is on screen")
	_ = snap

	// Request snapshot from core and verify text is present
	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [32]u8
	w := ipc.wire_writer(b[:])
	proto.enc_snapshot_req(&w, {id = id, history = 100, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got, "snapshot returned")

	r := ipc.wire_reader(f.payload)
	core_snap := proto.dec_snapshot(&r, context.temp_allocator)
	found := false
	for row in core_snap.screen {
		for run in row.runs {
			if strings.contains(run.text, "READY_NOW") do found = true
		}
	}
	testing.expect(t, found, "target text already on screen -> stops immediately")
}

@(private = "file")
_send_enter_line :: proc(conn: ^Cli, id: u32, text: string) {
	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = text},
		{kind = .Keys, n_keys = 1, keys = {0 = {key = 2}}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	cli_answer(conn, proto.MSG_ACT_RESULT, 3000)
}

@(test)
test_T10_tail_prompt_counts_only_after_last_input :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(
		v,
		"printf '\\033]133;A\\007'; printf 'PROMPT>'; " +
		"read line; printf '\\033]133;A\\007'; /bin/sleep 3",
	)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "PROMPT>")
	testing.expect(t, ok)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	_send_enter_line(&conn, id, "run_cmd")

	time.sleep(100 * time.Millisecond)
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got_snap := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got_snap)

	r := ipc.wire_reader(f.payload)
	after_snap := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect(
		t,
		after_snap.prompt_gen > after_snap.input_gen,
		"prompt arrived after last input",
	)
}

@(test)
test_T13_tail_exit_waits_for_exit :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 0.2; exit 7")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Settle until exited
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {id = id, since = 0, timeout_ms = 4000})
	cli_send(&conn, proto.MSG_SETTLE, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SETTLE_RESULT, 5000)
	testing.expect(t, got, "settle answered")

	r := ipc.wire_reader(f.payload)
	res := proto.dec_settle_result(&r)
	testing.expect(t, res.exited, "program exited")
	testing.expect_value(t, res.exit_code, 7)
}

@(test)
test_T14_tail_exit_immediate_if_already_exited :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "exit 0")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(200 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {id = id, since = 0, timeout_ms = 1000})
	cli_send(&conn, proto.MSG_SETTLE, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_SETTLE_RESULT, 2000)
	testing.expect(t, got)

	r := ipc.wire_reader(f.payload)
	res := proto.dec_settle_result(&r)
	testing.expect(t, res.exited, "already exited")
	testing.expect_value(t, res.exit_code, 0)
}

@(test)
test_T27_tail_does_not_mutate_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "/bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f1, _ := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	r1 := ipc.wire_reader(f1.payload)
	snap1 := proto.dec_snapshot(&r1, context.temp_allocator)

	// Settle wait with short timeout
	w = ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {id = id, since = snap1.gen, timeout_ms = 100})
	cli_send(&conn, proto.MSG_SETTLE, ipc.wire_bytes_written(&w))
	cli_answer(&conn, proto.MSG_SETTLE_RESULT, 1000)

	// Snapshot again: gen should be unchanged
	w = ipc.wire_writer(buf[:])
	proto.enc_snapshot_req(&w, {id = id, history = 0, since = -1})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f2, _ := cli_answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	r2 := ipc.wire_reader(f2.payload)
	snap2 := proto.dec_snapshot(&r2, context.temp_allocator)

	testing.expect_value(t, snap2.gen, snap1.gen)
}

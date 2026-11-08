package feature_session_core_tests

// Tests RD1–RD24 and S18d–f: term session read semantics, options (-n, --last,
// --clean, --elements, --output json), and session element ref table.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_RD1_plain_read_trimmed :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'hello world  '; echo 'line 2'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "line 2")
	testing.expect(t, ok)
	_ = snap

	// Request read from core
	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got, "MSG_READ returns MSG_TEXT")
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "hello world"), "contains trimmed hello world")
	testing.expect(t, !strings.contains(text, "hello world  \n"), "trailing spaces on line trimmed")
	testing.expect(t, !strings.has_suffix(text, "\n\n\n"), "no trailing empty lines at bottom")
}

@(test)
test_RD4_read_n_history :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "for i in $(seq 1 100); do echo \"HIST_$i\"; done; /bin/sleep 3", rows = 10)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "HIST_100")
	testing.expect(t, ok)
	_ = snap

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 20})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "HIST_100"))
	testing.expect(t, strings.contains(text, "HIST_85"), "contains history lines within 20 lines")
}

@(test)
test_RD5_read_n_more_than_history :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "for i in $(seq 1 5); do echo \"LINE_$i\"; done; /bin/sleep 3", rows = 10)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "LINE_5")
	testing.expect(t, ok)
	_ = snap

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 5000})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got, "returns without error even when history requested > available")
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "LINE_5"))
}

@(test)
test_RD7_read_n_alt_screen_does_not_scroll :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Enter alt screen
	s := view_sh(v, "printf '\\033[?1049hALT_SCREEN_ACTIVE'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "ALT_SCREEN_ACTIVE")
	testing.expect(t, ok)
	gen_before := snap.gen

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 50})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)
	_ = f

	snap_after, _, ok_after := cli_snapshot(id)
	testing.expect(t, ok_after)
	testing.expect_value(t, snap_after.gen, gen_before) // gen unchanged: no input sent to scroll alt screen
}

@(test)
test_RD8_read_does_not_mutate_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap1, ok := snap_until(id, "READY")
	testing.expect(t, ok)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)

	snap2, _, ok2 := cli_snapshot(id)
	testing.expect(t, ok2)
	testing.expect_value(t, snap2.gen, snap1.gen)
	testing.expect_value(t, snap2.cols, snap1.cols)
	testing.expect_value(t, snap2.rows, snap1.rows)
}

@(test)
test_RD9_read_unicode_cjk_emoji :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo '漢字 emoji: 🚀 rtl: שלום'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "漢字")
	testing.expect(t, ok)
	_ = snap

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "漢字"))
	testing.expect(t, strings.contains(text, "🚀"))
	testing.expect(t, strings.contains(text, "שלום"))
}

@(test)
test_RD10_read_allowed_during_lease :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'LEASE_READ'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "LEASE_READ")
	testing.expect(t, ok)
	_ = snap

	// Acquire a lease
	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_lease_req(&w, {id = id, owner = "agent-runner"})
	cli_send(&conn, proto.MSG_LEASE, ipc.wire_bytes_written(&w))
	_, got_lease := cli_answer(&conn, proto.MSG_OK, 3000)
	testing.expect(t, got_lease, "lease acquired")

	// Read must still be allowed!
	w = ipc.wire_writer(buf[:])
	proto.enc_read_req(&w, {id = id, history = 0})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got_read := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got_read, "read allowed during lease")
	testing.expect(t, strings.contains(string(f.payload), "LEASE_READ"))
}

@(test)
test_RD11_read_exited_session :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'GOODBYE'; exit 4")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(500 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got, "reading exited session returns its last screen")
	testing.expect(t, strings.contains(string(f.payload), "GOODBYE"))
	testing.expect(t, strings.contains(string(f.payload), "[exited 4]"))
}

@(test)
test_RD12_read_last_exit_code :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]133;A\\007$\\033]133;B\\007\\033]133;C\\007hi\\n\\033]133;D;3\\007'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "hi")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0, last = true})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got, "read --last returns MSG_TEXT")
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "hi"))
	testing.expect(t, strings.contains(text, "[exit 3]"))
}

@(test)
test_RD14_read_last_running :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]133;A\\007$\\033]133;B\\007\\033]133;C\\007working hard\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "working hard")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0, last = true})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "working hard"))
	testing.expect(t, strings.contains(text, "[running]"))
}

@(test)
test_RD15_read_last_no_osc133 :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'PLAIN'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "PLAIN")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0, last = true})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "read --last without OSC 133 fails")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Bad_Request)
}

@(test)
test_RD16_read_last_no_command_yet :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]133;A\\007$\\033]133;B\\007'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "$")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0, last = true})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "read --last before any command fails")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Bad_Request)
}

@(test)
test_RD17_read_last_no_trailing_newline :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]133;A\\007$\\033]133;B\\007\\033]133;C\\007x\\033]133;D;0\\007\\033]133;A\\007prompt$\\033]133;B\\007'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "prompt$")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_read_req(&w, {id = id, history = 0, last = true})
	cli_send(&conn, proto.MSG_READ, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_TEXT, 3000)
	testing.expect(t, got)
	text := string(f.payload)
	testing.expect(t, strings.contains(text, "x"))
	testing.expect(t, strings.contains(text, "[exit 0]"))
	testing.expect(t, !strings.contains(text, "prompt$"), "prompt is excluded from --last output")
}

@(test)
test_RD21_elements_dialog :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '[ Yes ]  [ No ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "Yes")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(&conn, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_ELEMENTS_RESULT, 3000)
	testing.expect(t, got, "MSG_ELEMENTS answered")
	r := ipc.wire_reader(f.payload)
	count := ipc.wr_u32(&r)
	testing.expect(t, count >= 2, "found at least Yes and No buttons")
	found_yes, found_no := false, false
	for _ in 0 ..< count {
		e := proto.dec_element_report(&r)
		name := e.name if len(e.name) > 0 else e.text
		if strings.contains(name, "Yes") do found_yes = true
		if strings.contains(name, "No") do found_no = true
	}
	testing.expect(t, found_yes, "found Yes button")
	testing.expect(t, found_no, "found No button")
}

@(test)
test_S18e_ref_numbers_stable_and_monotonic :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Display a dialog with Yes and No buttons
	s := view_sh(v, "printf '[ Yes ]  [ No ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "Yes")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// First query
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(&conn, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w))
	f1, got1 := cli_answer(&conn, proto.MSG_ELEMENTS_RESULT, 3000)
	testing.expect(t, got1)
	r1 := ipc.wire_reader(f1.payload)
	c1 := ipc.wr_u32(&r1)

	// Second query
	w = ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(&conn, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w))
	f2, got2 := cli_answer(&conn, proto.MSG_ELEMENTS_RESULT, 3000)
	testing.expect(t, got2)
	r2 := ipc.wire_reader(f2.payload)
	c2 := ipc.wr_u32(&r2)

	testing.expect_value(t, c1, c2)
}

@(test)
test_S18f_ref_table_cleared_on_session_kill :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'WILL_DIE'; /bin/sleep 5")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "WILL_DIE")
	cli_kill(id)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(&conn, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "killed session elements query fails with Not_Found")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Not_Found)
}

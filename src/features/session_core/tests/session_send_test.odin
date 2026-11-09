package feature_session_core_tests

// Tests S1–S31 and S18a–d: term session send semantics, atomic batch ACT,
// target resolution (@eN, text, pos), mouse modes, and lease protection.

import "core:strings"
import "core:testing"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(private = "file")
key_item :: proc(key: u8, mods: u8 = 0) -> proto.Act_Batch_Item {
	item: proto.Act_Batch_Item
	item.kind = .Keys
	item.n_keys = 1
	item.keys[0] = {key = key, mods = mods}
	return item
}

@(test)
test_S1_send_text_and_key :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "read line; echo \"GOT:$line\"; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Send "hello world" + Enter
	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = "hello world"},
		key_item(2), // Enter (Key.Enter = 2)
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got, "MSG_ACT returns MSG_ACT_RESULT")
	_ = f

	snap, ok := snap_until(id, "GOT:hello world")
	testing.expect(t, ok, "program received input in order")
	_ = snap
}

@(test)
test_S7_send_paste_with_2004 :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?2004h'; cat; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "")
	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, paste = true, text = "bracketed paste"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got)

	snap, ok := snap_until(id, "bracketed paste")
	testing.expect(t, ok)
	_ = snap
}

@(test)
test_S9_send_paste_strips_embedded_escape :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?2004h'; cat; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, paste = true, text = "safe\x1b[201~paste"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got)

	snap, ok := snap_until(id, "safepaste")
	testing.expect(t, ok, "embedded ESC[201~ stripped")
	_ = snap
}

@(test)
test_S11_send_unicode_cjk_emoji :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "read line; echo \"RECV:$line\"; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = "日本語 🚀 שלום\n"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got)

	_, ok := snap_until(id, "RECV:日本語 🚀 שלום")
	testing.expect(t, ok, "unicode UTF-8 received intact")
}

@(test)
test_S14_send_click_without_mouse_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'NO_MOUSE'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "NO_MOUSE")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Pos, row = 1, col = 1}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "click without mouse mode fails")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Unsupported)
	reason := cli_fail_reason(f.payload)
	testing.expect(t, strings.contains(reason, "does not take the mouse"))
}

@(test)
test_S15_send_click_outside_screen_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000h'; /bin/sleep 3", cols = 80, rows = 24)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(100 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Pos, row = 999, col = 1}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got, "out of bounds click fails")
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Bad_Request)
	testing.expect(t, strings.contains(cli_fail_reason(f.payload), "outside the"))
}

@(test)
test_S16_send_click_text_target :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000h[ Yes ]  [ No ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "Yes")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Text, text = "Yes"}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got, "click by unique text succeeds")
}

@(test)
test_S17_send_click_missing_text_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000h[ No ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "No")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Text, text = "Yes"}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Unsupported)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "no \"Yes\" on the screen"),
	)
}

@(test)
test_S18_send_click_ambiguous_text_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000h[ OK ]\\n[ OK ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "OK")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Text, text = "OK"}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Unsupported)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "matches for \"OK\""),
	)
}

@(test)
test_S18a_send_click_ref_shifts :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000h[ Yes ]\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "Yes")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Inquire elements to register @e1 for "Yes"
	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, id)
	cli_send(&conn, proto.MSG_ELEMENTS, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_ELEMENTS_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	_ = ipc.wr_u32(&r)
	rep := proto.dec_element_report(&r)
	ref := rep.ref

	// Click @eN
	w = ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Ref, ref = ref}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got_act := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got_act, "click by ref succeeds")
}

@(test)
test_S18d_send_unregistered_ref_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1000hREADY\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "READY")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Click, target = {kind = .Ref, ref = 99}},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Bad_Request)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "read --elements first"),
	)
}

@(test)
test_S24_send_drag_without_motion_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	// Mouse enabled (?1000) but NOT mouse motion (?1002)
	s := view_sh(v, "printf '\\033[?1000hREADY\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "READY")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{
			kind = .Drag,
			target = {kind = .Pos, row = 1, col = 1},
			to_target = {kind = .Pos, row = 2, col = 2},
		},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Unsupported)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "does not take mouse motion"),
	)
}

@(test)
test_S25_send_raw_escapes :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "read -r line; echo \"RAW:$line\"; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Raw, text = "rawdata\r"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	_, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got)

	_, ok := snap_until(id, "RAW:rawdata")
	testing.expect(t, ok, "raw bytes delivered unmodified")
}

@(test)
test_S27_send_exited_session_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'BYE'; exit 0")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	time.sleep(500 * time.Millisecond)

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = "after exit"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Exited)
}

@(test)
test_S28_send_during_lease_fails :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'LEASE_TEST'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "LEASE_TEST")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	// Acquire lease
	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_lease_req(&w, {id = id, owner = "flow.lua:test"})
	cli_send(&conn, proto.MSG_LEASE, ipc.wire_bytes_written(&w))
	_, got_lease := cli_answer(&conn, proto.MSG_OK, 3000)
	testing.expect(t, got_lease)

	// Sending from a different client must fail with exit 5 / Busy!
	conn2: Cli
	testing.expect(t, cli_conn(&conn2))
	defer cli_close(&conn2)

	w = ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = "blocked"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn2, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn2, proto.MSG_FAIL, 3000)
	testing.expect(t, got)
	testing.expect_value(t, cli_fail_code(f.payload), proto.Fail_Code.Busy)
	testing.expect(
		t,
		strings.contains(cli_fail_reason(f.payload), "flow.lua:test"),
	)
}

@(test)
test_S30_send_returns_gen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo 'GEN_TEST'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap_until(id, "GEN_TEST")

	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)

	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	items := []proto.Act_Batch_Item{
		{kind = .Text, text = "g"},
	}
	proto.enc_act_batch(&w, id, items)
	cli_send(&conn, proto.MSG_ACT, ipc.wire_bytes_written(&w))
	f, got := cli_answer(&conn, proto.MSG_ACT_RESULT, 3000)
	testing.expect(t, got)
	r := ipc.wire_reader(f.payload)
	ret_id := ipc.wr_u32(&r)
	ret_gen := ipc.wr_u64(&r)
	testing.expect_value(t, ret_id, id)
	testing.expect(t, ret_gen > 0, "gen is returned")
}

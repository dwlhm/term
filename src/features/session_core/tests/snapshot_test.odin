package feature_session_core_tests

// MSG_SNAPSHOT and MSG_SETTLE against real programs in the tiers: style runs,
// links, wide text, modes, history since a line, and every way a settle wait
// ends (settled, already settled, exited, timed out, removed).

import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

cli_snapshot :: proc(id: u32, history: u32 = 0, since: i64 = -1) -> (snap: proto.Snapshot, code: proto.Fail_Code, ok: bool) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	b: [16]u8
	w := ipc.wire_writer(b[:])
	proto.enc_snapshot_req(&w, {id = id, history = history, since = since})
	cli_send(&conn, proto.MSG_SNAPSHOT, ipc.wire_bytes_written(&w))
	f, got := _answer(&conn, proto.MSG_SNAPSHOT_RESULT, 4000)
	if !got do return
	r := ipc.wire_reader(f.payload)
	if f.kind == proto.MSG_FAIL do return {}, _fail_code(&r), false
	// The payload belongs to the connection, which closes here.
	r = ipc.wire_reader(slice.clone(f.payload, context.temp_allocator))
	snap = proto.dec_snapshot(&r, context.temp_allocator)
	return snap, {}, ipc.wr_done(&r)
}

cli_settle :: proc(req: proto.Settle_Request) -> (res: proto.Settle_Result, code: proto.Fail_Code, ok: bool) {
	conn: Cli
	if !cli_conn(&conn) do return
	defer cli_close(&conn)
	b: [24]u8
	w := ipc.wire_writer(b[:])
	proto.enc_settle_req(&w, req)
	cli_send(&conn, proto.MSG_SETTLE, ipc.wire_bytes_written(&w))
	f, got := _answer(&conn, proto.MSG_SETTLE_RESULT, int(req.timeout_ms) + 4000)
	if !got do return
	r := ipc.wire_reader(f.payload)
	if f.kind == proto.MSG_FAIL do return {}, _fail_code(&r), false
	res = proto.dec_settle_result(&r)
	return res, {}, ipc.wr_done(&r)
}

@(private = "file")
_answer :: proc(conn: ^Cli, want: u8, ms: int) -> (f: Cli_Frame, ok: bool) {
	for {
		f = cli_frame(conn, ms) or_return
		if f.kind == want || f.kind == proto.MSG_FAIL do return f, true
	}
}

@(private = "file")
_fail_code :: proc(r: ^ipc.Wire_Reader) -> proto.Fail_Code {
	_ = ipc.wr_u32(r)
	return proto.Fail_Code(ipc.wr_u8(r))
}

// snap_until polls snapshots until one shows want (tests only: callers use SETTLE).
snap_until :: proc(id: u32, want: string, history: u32 = 0, since: i64 = -1) -> (snap: proto.Snapshot, ok: bool) {
	for _ in 0 ..< 200 {
		s, _, got := cli_snapshot(id, history, since)
		if got && strings.contains(_snap_text(s.screen), want) do return s, true
		time.sleep(20 * time.Millisecond)
	}
	return
}

@(private = "file")
_snap_text :: proc(rows: []proto.Snap_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for row in rows {
		for run in row.runs do strings.write_string(&b, run.text)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
_find_run :: proc(rows: []proto.Snap_Row, text: string) -> (run: proto.Snap_Run, ok: bool) {
	for row in rows do for r in row.runs do if strings.contains(r.text, text) do return r, true
	return
}

@(test)
test_snapshot_runs_links_wide_and_title :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]2;SNAP TITLE\\007plain \\033[1;31mRED\\033[0m \\033]8;;https://x.test/a\\033\\\\LINK\\033]8;;\\033\\\\ 漢字!\\n'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "LINK")
	testing.expect(t, ok, "the snapshot shows the output")
	testing.expect_value(t, snap.id, id)
	testing.expect(t, snap.gen > 0, "output moved the generation")
	testing.expect_value(t, snap.cols, u16(80))
	testing.expect_value(t, snap.title, "SNAP TITLE")
	red, has_red := _find_run(snap.screen, "RED")
	testing.expect(t, has_red && red.text == "RED", "RED is its own run")
	testing.expect_value(t, red.style.fg, u8(1))
	testing.expect_value(t, red.style.style & 1, u8(1)) // bold
	link, has_link := _find_run(snap.screen, "LINK")
	testing.expect(t, has_link && link.style.link != 0, "the link run carries its OSC 8 id")
	testing.expect(t, len(snap.links) == 1 && snap.links[0].id == link.style.link, "the link table holds it")
	testing.expect_value(t, snap.links[0].uri, "https://x.test/a")
	wide, has_wide := _find_run(snap.screen, "漢字")
	testing.expect(t, has_wide, "wide text is kept")
	testing.expect_value(t, int(wide.cells), strings.rune_count(wide.text) + 2) // 漢字 take 2 cells each
}

@(test)
test_snapshot_modes_and_alt_screen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1049h\\033[?1h\\033[?2004h\\033[?1002h\\033[?1006h\\033[>1u\\033[3;5HALT_MODES'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "ALT_MODES")
	testing.expect(t, ok)
	testing.expect(t, snap.alt_screen && snap.app_cursor && snap.bracketed_paste, "screen modes")
	testing.expect_value(t, snap.mouse_mode, u8(3))   // ?1002
	testing.expect_value(t, snap.mouse_format, u8(1)) // ?1006
	testing.expect_value(t, snap.kitty_flags, u8(1))
	testing.expect_value(t, snap.cursor_row, u16(2))
	testing.expect_value(t, snap.cursor_col, u16(13))
	testing.expect_value(t, len(snap.history), 0) // the alternate screen has no scrollback
}

@(test)
test_snapshot_history_since_a_line :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "i=1; while [ $i -le 60 ]; do echo L$i; i=$((i+1)); done; /bin/sleep 1; echo MORE1; echo MORE2; echo MORE3; /bin/sleep 3", rows = 10)
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	first, ok := snap_until(id, "L60")
	testing.expect(t, ok)
	few, _, _ := cli_snapshot(id, history = 5)
	testing.expect_value(t, len(few.history), 5)
	testing.expect(t, few.history_truncated, "more history matched than was asked for")
	testing.expect_value(t, few.history[4].line, few.top_line - 1)

	later, more := snap_until(id, "MORE3", history = 100, since = first.top_line)
	testing.expect(t, more)
	testing.expect(t, !later.history_truncated)
	testing.expect_value(t, i64(len(later.history)), later.top_line - first.top_line)
	if len(later.history) > 0 do testing.expect_value(t, later.history[0].line, first.top_line)
}

@(test)
test_settle_waits_for_quiet_output :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "echo READY; /bin/sleep 0.4; echo LATER; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	snap, ok := snap_until(id, "READY")
	testing.expect(t, ok)
	start := time.tick_now()
	res, _, settled := cli_settle({id = id, since = snap.gen, quiet_ms = 100, timeout_ms = 3000})
	testing.expect(t, settled, "the screen settles after LATER")
	testing.expect(t, res.gen > snap.gen && !res.exited)
	testing.expect(t, time.tick_since(start) >= 300 * time.Millisecond, "it waited for the next output")
	after, _, _ := cli_snapshot(id)
	testing.expect(t, strings.contains(_snap_text(after.screen), "LATER"))

	// Already past since and quiet: answered at once.
	start = time.tick_now()
	_, _, again := cli_settle({id = id, since = snap.gen, quiet_ms = 50, timeout_ms = 3000})
	testing.expect(t, again && time.tick_since(start) < 300 * time.Millisecond, "an old generation answers at once")
}

@(test)
test_settle_ends_on_exit_timeout_and_removal :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	busy := view_attached(v, view_sh(v, "while :; do echo tick; /bin/sleep 0.05; done"))
	short := view_attached(v, view_sh(v, "echo BYE; /bin/sleep 0.3; exit 7"))
	idle := view_attached(v, view_sh(v, "/bin/sleep 5"))
	defer { view_close(v); tiers_stop(tiers) }

	_, code, ok := cli_settle({id = busy, since = 0, quiet_ms = 500, timeout_ms = 600})
	testing.expect(t, !ok && code == .Timeout, "a screen that never goes quiet times out")

	res, _, exited := cli_settle({id = short, since = max(u64), quiet_ms = 100, timeout_ms = 5000})
	testing.expect(t, exited && res.exited, "an exit ends the wait")
	testing.expect_value(t, res.exit_code, i32(7))

	go_kill :: proc(id: rawptr) {
		time.sleep(300 * time.Millisecond)
		cli_kill(u32(uintptr(id)))
	}
	th := thread.create_and_start_with_data(rawptr(uintptr(idle)), go_kill)
	_, code, ok = cli_settle({id = idle, since = max(u64), quiet_ms = 100, timeout_ms = 5000})
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !ok && code == .Not_Found, "a removed session fails the wait")

	_, code, ok = cli_settle({id = 999_999, quiet_ms = 1, timeout_ms = 100})
	testing.expect(t, !ok && code == .Not_Found)
}

@(test)
test_snapshot_rejects_malformed_requests :: proc(t: ^testing.T) {
	tiers := tiers_start()
	defer tiers_stop(tiers)
	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)
	cli_send(&conn, proto.MSG_SNAPSHOT, []u8{1, 2, 3})
	f, got := _answer(&conn, proto.MSG_SNAPSHOT_RESULT, 3000)
	testing.expect(t, got && f.kind == proto.MSG_FAIL)
	r := ipc.wire_reader(f.payload)
	testing.expect_value(t, _fail_code(&r), proto.Fail_Code.Bad_Request)
	_, code, ok := cli_snapshot(424_242)
	testing.expect(t, !ok && code == .Not_Found)
}

@(test)
test_snapshot_generational_tracking :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033]7501;state=working:msg=work\\007'; /bin/sleep 0.2; printf '\\033]133;A\\007'; /bin/sleep 3")
	id := view_attached(v, s)
	defer { view_close(v); tiers_stop(tiers) }

	// Wait until program status and prompt have registered
	time.sleep(500 * time.Millisecond)
	snap, _, ok := cli_snapshot(id)
	testing.expect(t, ok)
	testing.expect(t, snap.status_gen > 0, "status_gen tracked OSC 7501")
	testing.expect(t, snap.prompt_gen > 0, "prompt_gen tracked OSC 133")

	// Send input to the session via MSG_SEND
	conn: Cli
	testing.expect(t, cli_conn(&conn))
	defer cli_close(&conn)
	buf: [128]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_send_req(&w, {id = id, bytes = transmute([]u8)string("hi")})
	cli_send(&conn, proto.MSG_SEND, ipc.wire_bytes_written(&w))
	_, got := _answer(&conn, proto.MSG_OK, 3000)
	testing.expect(t, got, "send accepted")

	snap_after, _, ok2 := cli_snapshot(id)
	testing.expect(t, ok2)
	testing.expect(t, snap_after.input_gen > 0, "input_gen tracked MSG_SEND")
	testing.expect(t, snap_after.input_gen >= snap.gen, "input_gen updated to at least previous screen gen")
}

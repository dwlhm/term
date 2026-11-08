package feature_session_core_tests

// A program on a loaded machine answers each wheel notch a beat late. The core
// must wait for that reply instead of reading a stale page (and calling it the
// top), and must measure how far the view really moved, so the restore lands on
// the page the read started on.

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import core ".."
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_read_restores_a_slow_program :: proc(t: ^testing.T) {
	tiers := tiers_start()
	script_buf: [64]u8
	script := fmt.bprintf(script_buf[:], "/tmp/tsc-stitch-slow-%d.py", posix.getpid())
	err := os.write_entire_file(script, transmute([]u8)string(STITCH_FIXTURE))
	testing.expect(t, err == os.General_Error.None, "fixture written")

	v := view_open()
	s := view_spawn(v, {"/usr/bin/env", "python3", "-I", script, "25"}, 80, 24)
	id := view_attached(v, s)
	testing.expect(t, id != 0, "attached")
	testing.expect(t, view_wait_screen(v, s, "L300", 8000), "the fixture drew its bottom page")

	conn: ipc.Stream_Conn
	testing.expect(t, cli_conn(&conn), "cli link")
	ch, ok := cli_attach_channel(&conn, id)
	testing.expect(t, ok, "attached on a channel")
	if paint, got := wait_data(&conn, ch); got do delete(paint)

	// This program answers every notch a beat late. The core must wait for the
	// reply (not read a stale page and call it the top) and must measure how far
	// the view really moved, so its restore lands on the start page.
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.ww_u32(&w, 30)
	ipc.stream_send(&conn, proto.MSG_READ, 0, b[:])
	ipc.stream_send(&conn, proto.MSG_V_INPUT, ch, transmute([]u8)string("k"))

	text, _, _, answered := wait_text(&conn, ch)
	if answered do defer delete(text)
	testing.expect(t, answered, "the core answered the read")
	testing.expect(t, !contains(string(text), core.CORE_READ_RESTORE_NOTE), "no failed restore is reported")
	nums := l_numbers(string(text))
	testing.expect_value(t, len(nums), 53) // 30 history lines + the 23 visible body rows
	if len(nums) == 53 {
		testing.expect_value(t, nums[0], 248)
		bad := 0
		for n, i in nums do if n != 248 + i do bad += 1
		testing.expect_value(t, bad, 0)
	}
	if repaint, got := wait_screen(&conn, ch, "L300"); got {
		defer delete(repaint)
		testing.expect(t, contains(string(repaint), "L278"), "the slow program is back on its first page")
	} else {
		testing.expect(t, false, "one repaint after the slow restore")
	}
	if typed, got := wait_screen(&conn, ch, "KEY k"); got {
		defer delete(typed)
		testing.expect(t, true, "the held input was delivered after the restore")
	} else {
		testing.expect(t, false, "the held input reached the slow program")
	}

	ipc.stream_conn_destroy(&conn)
	view_close(v)
	os.remove(script)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

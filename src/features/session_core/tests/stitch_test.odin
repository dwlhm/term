package feature_session_core_tests

// Reading a full-screen program's history through all three tiers: the core
// scrolls the program with wheel notches, holds the viewer's input while it
// runs, keeps live frames back and answers once.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import client "../../session_client"
import ipc "../../../platform/ipc"
import core ".."

@(private)
wait_data :: proc(conn: ^ipc.Stream_Conn, ch: u32) -> ([]u8, bool) {
	for {
		f, got := client.client_wait_frame(conn, 4000)
		if !got do return nil, false
		if f.kind != ipc.STREAM_DATA || f.channel != ch do continue
		out := make([]u8, len(f.payload))
		copy(out, f.payload)
		return out, true
	}
}

// wait_text waits for MSG_TEXT and counts the live frames and FAILs before it.
@(private)
wait_text :: proc(conn: ^ipc.Stream_Conn, ch: u32) -> (text: []u8, live: int, fails: int, ok: bool) {
	for {
		f, got := client.client_wait_frame(conn, 8000)
		if !got do return
		if f.kind == ipc.MSG_TEXT {
			text = make([]u8, len(f.payload))
			copy(text, f.payload)
			return text, live, fails, true
		}
		if f.kind == ipc.STREAM_DATA && f.channel == ch do live += 1
		if f.kind == ipc.MSG_FAIL do fails += 1
	}
}

@(private)
cli_attach_channel :: proc(conn: ^ipc.Stream_Conn, id: u32) -> (u32, bool) {
	b: [64]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, 7)
	ipc.enc_attach(&w, {id = id, size = {cols = 80, rows = 24}})
	ipc.stream_send(conn, ipc.MSG_ATTACH, 0, ipc.wire_bytes_written(&w))
	for {
		f, got := client.client_wait_frame(conn, 3000)
		if !got do return 0, false
		if f.kind != ipc.MSG_ATTACHED do continue
		r := ipc.wire_reader(f.payload)
		_, got_id, ch := ipc.wr_u32(&r), ipc.wr_u32(&r), ipc.wr_u32(&r)
		return ch, got_id == id
	}
}

@(private = "file")
cli_read :: proc(conn: ^ipc.Stream_Conn, id: u32, history: u32) -> ([]u8, bool) {
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.ww_u32(&w, history)
	ipc.stream_send(conn, ipc.MSG_READ, 0, b[:])
	text, _, _, ok := wait_text(conn, 0)
	return text, ok
}

// l_numbers lists the "L<nnn>" lines of a text in order.
@(private)
l_numbers :: proc(text: string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for line in strings.split(text, "\n", context.temp_allocator) {
		if len(line) < 4 || line[0] != 'L' do continue
		if n, ok := strconv.parse_int(line[1:4]); ok && len(line) == 4 do append(&out, n)
	}
	return out[:]
}

// wait_screen waits for a data frame that shows `needle`: the viewer state
// proves the step, so the test never sleeps on a guess.
@(private)
wait_screen :: proc(conn: ^ipc.Stream_Conn, ch: u32, needle: string, ms := 4000) -> (frame: []u8, ok: bool) {
	deadline := time.tick_now()._nsec + i64(ms) * 1_000_000
	for time.tick_now()._nsec < deadline {
		left := int((deadline - time.tick_now()._nsec) / 1_000_000) + 1
		f, got := client.client_wait_frame(conn, left)
		if !got do return nil, false
		if f.kind != ipc.STREAM_DATA || f.channel != ch do continue
		if !contains(string(f.payload), needle) do continue
		out := make([]u8, len(f.payload))
		copy(out, f.payload)
		return out, true
	}
	return nil, false
}

@(test)
test_read_stitches_full_screen_history :: proc(t: ^testing.T) {
	tiers := tiers_start()
	script_buf: [64]u8
	script := fmt.bprintf(script_buf[:], "/tmp/tsc-stitch-%d.py", posix.getpid())
	err := os.write_entire_file(script, transmute([]u8)string(STITCH_FIXTURE))
	testing.expect(t, err == os.General_Error.None, "fixture written")

	v := view_open()
	s := view_spawn(v, {"/usr/bin/env", "python3", "-I", script}, 80, 24)
	id := view_attached(v, s)
	testing.expect(t, id != 0, "attached")
	testing.expect(t, view_wait_screen(v, s, "L300", 8000), "the fixture drew its bottom page")

	conn: ipc.Stream_Conn
	testing.expect(t, cli_conn(&conn), "cli link")
	ch, ok := cli_attach_channel(&conn, id)
	testing.expect(t, ok, "attached on a channel")
	if paint, got := wait_data(&conn, ch); got {
		defer delete(paint)
		testing.expect(t, contains(string(paint), "L300"), "first paint shows the screen")
	} else {
		testing.expect(t, false, "first paint")
	}

	// Ask for 200 lines of history, then type: the input must be held.
	b: [8]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.ww_u32(&w, 200)
	ipc.stream_send(&conn, ipc.MSG_READ, 0, b[:])
	ipc.stream_send(&conn, ipc.MSG_READ, 0, b[:]) // a second read is refused, not queued
	ipc.stream_send(&conn, ipc.MSG_V_INPUT, ch, transmute([]u8)string("k"))

	text, live, fails, answered := wait_text(&conn, ch)
	if answered do defer delete(text)
	testing.expect(t, answered, "the core answered the read")
	testing.expect_value(t, fails, 1) // the concurrent read was told busy
	testing.expect_value(t, live, 0) // no live frames while the stitch runs
	nums := l_numbers(string(text))
	testing.expect_value(t, len(nums), 223) // 200 history lines + the 23 visible body rows
	if len(nums) == 223 {
		testing.expect_value(t, nums[0], 78) // 200 lines above the bottom screen
		testing.expect_value(t, nums[len(nums) - 1], 300)
		bad := 0
		for n, i in nums do if n != 78 + i do bad += 1
		testing.expect_value(t, bad, 0) // every line once, in order
	}
	testing.expect(t, contains(string(text), "LIST 300"), "the screen the read started on ends the text")
	testing.expect(t, !contains(string(text), core.CORE_READ_RESTORE_NOTE), "the answer does not claim a failed restore")

	// The repaint comes only after the verified restore: it must be the page the
	// read started on, not the scrolled one the scan stopped on.
	if repaint, got := wait_screen(&conn, ch, "L300"); got {
		defer delete(repaint)
		testing.expect(t, contains(string(repaint), "L278"), "the repaint starts on the page the read found")
	} else {
		testing.expect(t, false, "one repaint after the stitch")
	}
	// The held input was delivered after that restore; its redraw is the proof.
	if typed, got := wait_screen(&conn, ch, "KEY k"); got {
		defer delete(typed)
		testing.expect(t, true, "the held input was delivered")
	} else {
		testing.expect(t, false, "the held input reached the program")
	}

	ipc.stream_conn_destroy(&conn)
	view_close(v)
	os.remove(script)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_read_alt_screen_without_mouse_is_marked :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf '\\033[?1049h\\033[2J'; printf 'ALT-A\\nALT-B\\n'; sleep 30")
	id := view_attached(v, s)
	testing.expect(t, id != 0, "attached")
	testing.expect(t, view_wait_screen(v, s, "ALT-B", 4000), "alt screen drawn")

	conn: ipc.Stream_Conn
	testing.expect(t, cli_conn(&conn), "cli link")
	text, ok := cli_read(&conn, id, 10)
	if ok do defer delete(text)
	testing.expect(t, ok, "the core answered")
	testing.expect(t, contains(string(text), "ALT-B"), "the visible screen is the answer")
	testing.expect(t, contains(string(text), "does not report mouse input"), "and it says why")
	ipc.stream_conn_destroy(&conn)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

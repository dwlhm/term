package feature_session_proto_tests

// Snapshot codec: a streamed snapshot decodes to what was written, and hostile
// counts or truncated payloads fail without allocating for them.

import "core:testing"
import proto "../"
import ipc "../../../platform/ipc"

@(private = "file")
_write_snapshot :: proc(buf: []u8) -> []u8 {
	w := ipc.wire_writer(buf)
	proto.enc_snapshot_head(&w, {id = 7, gen = 42, cols = 80, rows = 2, top_line = 100, title = "T", process = "sh", prompt_state = .Input, status_state = 2, status_msg = "busy"})
	ipc.ww_u32(&w, 1)
	proto.enc_snap_row(&w, 99, true, false, {{cells = 3, text = "old"}})
	ipc.ww_u32(&w, 2)
	style := proto.Snap_Style{fg = 1, has_bg_rgb = true, bg_rgb = {1, 2, 3}, style = 1, underline = 3, link = 5}
	proto.enc_snap_row(&w, 100, false, true, {{cells = 2, text = "ab"}, {cells = 4, style = style, text = "漢字"}})
	proto.enc_snap_row(&w, 101, false, false, nil)
	ipc.ww_u32(&w, 1)
	proto.enc_snap_link(&w, {5, "https://x.test"})
	return ipc.wire_bytes_written(&w)
}

@(test)
test_snapshot_roundtrip :: proc(t: ^testing.T) {
	buf: [1024]u8
	r := ipc.wire_reader(_write_snapshot(buf[:]))
	m := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect(t, ipc.wr_done(&r))
	testing.expect(t, m.id == 7 && m.gen == 42 && m.top_line == 100 && m.prompt_state == .Input)
	testing.expect(t, m.title == "T" && m.process == "sh" && m.status_state == 2 && m.status_msg == "busy")
	testing.expect(t, len(m.history) == 1 && m.history[0].line == 99 && m.history[0].wrap)
	testing.expect_value(t, m.history[0].runs[0].text, "old")
	testing.expect(t, len(m.screen) == 2 && m.screen[0].prompt && len(m.screen[1].runs) == 0)
	run := m.screen[0].runs[1]
	testing.expect(t, run.cells == 4 && run.text == "漢字")
	testing.expect(t, run.style.bg_rgb == {1, 2, 3} && run.style.has_bg_rgb && run.style.underline == 3 && run.style.link == 5)
	testing.expect(t, len(m.links) == 1 && m.links[0].id == 5 && m.links[0].uri == "https://x.test")
}

@(test)
test_snapshot_rejects_hostile_counts :: proc(t: ^testing.T) {
	buf: [1024]u8
	payload := _write_snapshot(buf[:])
	// Every truncation fails cleanly.
	for n in 0 ..< len(payload) {
		r := ipc.wire_reader(payload[:n])
		_ = proto.dec_snapshot(&r, context.temp_allocator)
		testing.expect(t, !ipc.wr_done(&r))
	}
	// A history count of 2^32-1 rows in a short payload never allocates them.
	w := ipc.wire_writer(buf[:])
	proto.enc_snapshot_head(&w, {})
	ipc.ww_u32(&w, max(u32))
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	m := proto.dec_snapshot(&r, context.temp_allocator)
	testing.expect(t, !r.ok && len(m.history) == 0)
}

@(test)
test_settle_roundtrip :: proc(t: ^testing.T) {
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	proto.enc_settle_req(&w, {id = 3, since = 9, quiet_ms = 50, timeout_ms = 1000})
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	req := proto.dec_settle_req(&r)
	testing.expect(t, ipc.wr_done(&r) && req == {id = 3, since = 9, quiet_ms = 50, timeout_ms = 1000})
	w = ipc.wire_writer(buf[:])
	proto.enc_settle_result(&w, {id = 3, gen = 11, exited = true, exit_code = -1})
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	res := proto.dec_settle_result(&r)
	testing.expect(t, ipc.wr_done(&r) && res == {id = 3, gen = 11, exited = true, exit_code = -1})
}

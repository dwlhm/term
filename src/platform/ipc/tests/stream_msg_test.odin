package platform_ipc_tests

import "core:testing"
import ipc "../"

@(test)
test_msg_spawn_roundtrip :: proc(t: ^testing.T) {
	m: ipc.Spawn_Msg
	m.argv[0], m.argv[1], m.argc = "/bin/zsh", "-l", 2
	m.env[0], m.envc = "TERM=xterm-256color", 1
	m.cwd, m.cols, m.rows, m.xpixel, m.ypixel = "/tmp", 80, 24, 800, 480
	buf: [1024]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_spawn(&w, &m)
	testing.expect(t, w.ok)
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	got: ipc.Spawn_Msg
	ipc.dec_spawn(&r, &got)
	testing.expect(t, ipc.wr_done(&r))
	testing.expect(t, got.argc == 2 && got.argv[1] == "-l" && got.env[0] == "TERM=xterm-256color")
	testing.expect(t, got.cwd == "/tmp" && got.size == m.size)
}

@(test)
test_msg_decoders_reject_truncated_and_hostile :: proc(t: ^testing.T) {
	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_row(&w, {id = 3, state = .Busy, process = "vim", cwd = "/x", title = "t", status = "s"})
	full := ipc.wire_bytes_written(&w)
	for cut in 0..<len(full) {
		r := ipc.wire_reader(full[:cut])
		_ = ipc.dec_row(&r)
		testing.expect(t, !ipc.wr_done(&r), "a truncated row never decodes")
	}
	// A string length far past the payload must not be trusted.
	hostile := [8]u8{0xff, 0xff, 0xff, 0x7f, 'a', 'b', 'c', 'd'}
	r := ipc.wire_reader(hostile[:])
	testing.expect(t, ipc.wr_str(&r) == "" && !r.ok)
	// argc outside the bounds is rejected before any string is read.
	ww := ipc.wire_writer(buf[:])
	ipc.ww_u32(&ww, ipc.STREAM_MAX_ARGV + 1)
	rr := ipc.wire_reader(ipc.wire_bytes_written(&ww))
	sp: ipc.Spawn_Msg
	ipc.dec_spawn(&rr, &sp)
	testing.expect(t, !rr.ok)
}

@(test)
test_msg_hello_check :: proc(t: ^testing.T) {
	buf: [128]u8
	encode :: proc(buf: []u8, m: ipc.Hello_Msg) -> []u8 {
		w := ipc.wire_writer(buf)
		ipc.enc_hello(&w, m)
		return ipc.wire_bytes_written(&w)
	}
	ok_msg := encode(buf[:], {version = ipc.STREAM_PROTO_VERSION, role = .Viewer, build = "b1"})
	m, _, ok := ipc.stream_hello_check(ok_msg, {.Viewer, .Cli})
	testing.expect(t, ok && m.build == "b1")
	_, code, ok2 := ipc.stream_hello_check(encode(buf[:], {version = 99, role = .Viewer}), {.Viewer})
	testing.expect(t, !ok2 && code == .Version)
	_, code, ok2 = ipc.stream_hello_check(encode(buf[:], {version = ipc.STREAM_PROTO_VERSION, role = .Holder}), {.Viewer})
	testing.expect(t, !ok2 && code == .Bad_Request)
}

@(test)
test_msg_held_roundtrip :: proc(t: ^testing.T) {
	orig := ipc.Held_Session{
		id           = 42,
		pid          = 12345,
		started_unix = 1700000000,
		size         = {cols = 80, rows = 24, xpixel = 640, ypixel = 480},
		exited       = true,
		exit         = {code = 0, signal = 0, signaled = false},
	}
	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_held(&w, orig)
	testing.expect(t, w.ok, "enc_held ok")
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	got := ipc.dec_held(&r)
	testing.expect(t, ipc.wr_done(&r), "dec_held wr_done")
	testing.expect(t, got.id == orig.id, "id matches")
	testing.expect(t, got.pid == orig.pid, "pid matches")
	testing.expect(t, got.started_unix == orig.started_unix, "started_unix matches")
	testing.expect(t, got.size == orig.size, "size matches")
	testing.expect(t, got.exited == orig.exited, "exited matches")
	testing.expect(t, got.exit == orig.exit, "exit matches")
}

package feature_session_core_tests

// A core that goes away and comes back, and viewers that break protocol.

import "core:sys/posix"
import "core:testing"
import "core:time"
import client "../../session_client"
import session "../../session"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_core_restart_restores_screen :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "printf 'before-restart'; read x; printf 'after:%s' \"$x\"; sleep 30")
	id := view_attached(v, s)
	testing.expect(t, view_wait_screen(v, s, "before-restart"), "output before the restart")
	tiers_core_restart_stop(tiers)
	testing.expect(t, view_wait(v, .Core_Lost) >= 0, "viewer notices the core is gone")
	tiers_core_start(tiers)
	testing.expect(t, client.client_reconnect(&v.c), "reconnect")
	testing.expect(t, view_attached(v, s) == id, "the same session is attached again")
	testing.expect(t, view_wait_screen(v, s, "before-restart"), "repaint keeps the screen")
	session.session_write_string(s, "x\n")
	testing.expect(t, view_wait_screen(v, s, "after:x"), "input and output flow again")

	w := view_open()
	sw := client.client_attach(&w.c, {id = id, size = {cols = 80, rows = 24}})
	testing.expect(t, view_attached(w, sw) == id, "a new viewer attaches")
	testing.expect(t, view_wait_screen(w, sw, "before-restart"), "a new viewer sees the restored screen")
	ids: [8]u32
	testing.expect_value(t, len(cli_list_ids(ids[:])), 1)
	view_close(w)
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

@(test)
test_core_restart_preserves_elapsed :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "sleep 30")
	id := view_attached(v, s)
	testing.expect(t, id > 0, "session attached")

	time.sleep(1200 * time.Millisecond)

	tiers_core_restart_stop(tiers)
	testing.expect(t, view_wait(v, .Core_Lost) >= 0, "viewer notices the core is gone")
	tiers_core_start(tiers)

	rows: [8]proto.Session_Row
	got_rows := cli_wait_rows(rows[:])
	testing.expect_value(t, len(got_rows), 1)
	if len(got_rows) == 1 {
		testing.expect_value(t, got_rows[0].id, id)
		testing.expect(t, got_rows[0].elapsed_s >= 1, "elapsed_s survives restart and is >= 1")
	}

	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

// hostile_link connects by hand; with hello it says HELLO (0.1.0, Viewer) first.
@(private = "file")
hostile_link :: proc(hello: bool) -> (fd: posix.FD, ok: bool) {
	buf, sbuf: [128]u8
	dir, _ := proto.session_dir(buf[:])
	sock, _ := proto.session_path(sbuf[:], dir, proto.CORE_SOCKET)
	if fd = _raw_connect(sock); fd < 0 do return -1, false
	if !hello do return fd, true
	hb: [9 + 64]u8
	w := ipc.wire_writer(hb[9:])
	proto.enc_hello(&w, {version = 0x000100, role = .Viewer, build = "hostile"})
	_raw_header(hb[:], proto.MSG_HELLO, 0, u32(w.n))
	posix.send(fd, raw_data(hb[:]), uint(9 + w.n), {.NOSIGNAL})
	return fd, true
}

@(private = "file")
_raw_connect :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	addr := posix.sockaddr_un{sun_family = .UNIX}
	copy(([^]u8)(&addr.sun_path[0])[:len(addr.sun_path) - 1], path)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(private = "file")
_raw_header :: proc(dst: []u8, kind: u8, channel, length: u32) {
	dst[0] = kind
	for i in 0 ..< 4 do dst[1 + i], dst[5 + i] = u8(channel >> uint(8 * i)), u8(length >> uint(8 * i))
}

@(private = "file")
_raw_parse_header :: proc(src: []u8) -> (kind: u8, channel: u32, length: int, ok: bool) {
	if len(src) < 9 do return
	channel = u32(src[1]) | u32(src[2]) << 8 | u32(src[3]) << 16 | u32(src[4]) << 24
	len32 := u32(src[5]) | u32(src[6]) << 8 | u32(src[7]) << 16 | u32(src[8]) << 24
	return src[0], channel, int(len32), true
}

// hostile_read collects what the core sends for up to 5 s; closed = it hung up.
@(private = "file")
hostile_read :: proc(fd: posix.FD, out: []u8, until_closed: bool) -> (n: int, closed: bool) {
	// A drop under load may take the core a while to notice; the assertion is
	// that it closes the socket, not that it is fast.
	deadline := time.tick_now()._nsec + 5_000_000_000
	for time.tick_now()._nsec < deadline {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 50) <= 0 {
			if !until_closed && n > 0 do return n, false
			continue
		}
		room := len(out) - n
		got := posix.recv(fd, raw_data(out[n:]), uint(room), {})
		if got == 0 || (got < 0 && posix.errno() != .EAGAIN) do return n, true
		if got > 0 do n += int(got)
	}
	return n, false
}

// hostile_dropped sends bytes on a fresh link and reports whether the core closed it.
@(private = "file")
hostile_dropped :: proc(hello: bool, bytes: []u8) -> bool {
	fd, ok := hostile_link(hello)
	if !ok do return false
	defer posix.close(fd)
	posix.send(fd, raw_data(bytes), uint(len(bytes)), {.NOSIGNAL})
	junk: [8192]u8
	_, closed := hostile_read(fd, junk[:], true)
	return closed
}

// hostile_refused: an unknown request kind (req 9) is answered FAIL
// Bad_Request with its req, and the link stays (IPC spec P17).
@(private = "file")
hostile_refused :: proc() -> bool {
	fd, ok := hostile_link(true)
	if !ok do return false
	defer posix.close(fd)
	frame: [9 + 4]u8
	_raw_header(frame[:], 200, 0, 4)
	frame[9] = 9
	posix.send(fd, raw_data(frame[:]), len(frame), {.NOSIGNAL})
	in_buf: [8192]u8
	n, closed := hostile_read(fd, in_buf[:], false)
	for off := 0; off + 9 <= n; {
		kind, _, length, valid := _raw_parse_header(in_buf[off:n])
		if !valid || off + 9 + length > n do break
		r := ipc.wire_reader(in_buf[off + 9:][:length])
		if kind == proto.MSG_FAIL do return !closed && ipc.wr_u32(&r) == 9 && proto.Fail_Code(ipc.wr_u8(&r)) == .Bad_Request
		off += 9 + length
	}
	return false
}

@(test)
test_hostile_viewers_dropped :: proc(t: ^testing.T) {
	tiers := tiers_start()
	v := view_open()
	s := view_sh(v, "stty -echo; while read x; do printf 'echo:%s\\n' \"$x\"; done")
	testing.expect(t, view_attached(v, s) != 0, "a good viewer")
	oversize: [9]u8
	_raw_header(oversize[:], proto.MSG_LIST, 0, 0)
	oversize[5], oversize[6], oversize[7], oversize[8] = 0xff, 0xff, 0xff, 0x7f
	bad_credit: [9 + 1]u8
	_raw_header(bad_credit[:], 1, 1, 1) // 1 = CREDIT
	testing.expect(t, hostile_dropped(false, transmute([]u8)string("GET / HTTP/1.1\r\n\r\n")), "garbage before HELLO")
	testing.expect(t, hostile_dropped(true, oversize[:]), "oversize frame")
	testing.expect(t, hostile_refused(), "an unknown request kind is answered Bad_Request, not dropped")
	testing.expect(t, hostile_dropped(true, bad_credit[:]), "malformed CREDIT")
	session.session_write_string(s, "still-here\n")
	testing.expect(t, view_wait_screen(v, s, "echo:still-here"), "the good viewer is unaffected")
	view_close(v)
	testing.expect(t, tiers_stop(tiers), "tiers end")
}

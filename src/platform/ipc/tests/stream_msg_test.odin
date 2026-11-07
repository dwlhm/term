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

@(test)
test_msg_observe_roundtrip :: proc(t: ^testing.T) {
	orig := ipc.Observe_Result{
		row = {
			id        = 7,
			state     = .Busy,
			active    = true,
			attached  = false,
			pid       = 9876,
			elapsed_s = 42,
			exit_code = 0,
			quiet_s   = 7,
			request   = {serving = 2, serving_id = 9, awaiting = 4, listening = 1},
			process   = "zsh",
			cwd       = "/home/dev",
			title     = "Terminal",
			status    = "working",
		},
		cols          = 120,
		rows          = 30,
		is_alt        = true,
		prompt_state  = .Executing,
		has_cmd_exit  = true,
		cmd_exit_code = 0,
		cmd_seq       = 17,
		text          = "Hello terminal world\nSecond line",
	}
	buf: [1024]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_observe_result(&w, orig)
	testing.expect(t, w.ok, "enc_observe_result ok")
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	got := ipc.dec_observe_result(&r)
	testing.expect(t, ipc.wr_done(&r), "dec_observe_result wr_done")
	testing.expect(t, got.row.id == orig.row.id, "id matches")
	testing.expect(t, got.row.state == orig.row.state, "state matches")
	testing.expect(t, got.row.request == orig.row.request && got.row.quiet_s == 7, "request and quiet_s match")
	testing.expect(t, got.row.process == orig.row.process, "process matches")
	testing.expect(t, got.cols == orig.cols && got.rows == orig.rows, "dimensions match")
	testing.expect(t, got.is_alt == orig.is_alt, "is_alt matches")
	testing.expect(t, got.prompt_state == orig.prompt_state, "prompt_state matches")
	testing.expect(t, got.has_cmd_exit == orig.has_cmd_exit && got.cmd_exit_code == orig.cmd_exit_code, "cmd_exit matches")
	testing.expect(t, got.cmd_seq == orig.cmd_seq, "cmd_seq matches")
	testing.expect(t, got.text == orig.text, "text matches")
}

@(test)
test_msg_tell_roundtrip :: proc(t: ^testing.T) {
	buf: [256]u8
	w := ipc.wire_writer(buf[:])
	req := ipc.Tell_Request{to = 4, from = 2, timeout_ms = 9000, parent = 3, wait = true, shell = true, body = "review src/foo.odin"}
	ipc.enc_tell_req(&w, req)
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	got_req := ipc.dec_tell_req(&r)
	testing.expect(t, ipc.wr_done(&r) && got_req == req, "tell request round-trips")

	res := ipc.Tell_Result{id = 7, phase = .Finished, reject = .Busy, status = .Failed, exit_code = 2, from = 2, to = 4, progress = "half", text = "boom"}
	w = ipc.wire_writer(buf[:])
	ipc.enc_tell_result(&w, res)
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	got := ipc.dec_tell_result(&r)
	testing.expect(t, ipc.wr_done(&r) && got == res, "tell result round-trips")
	bad := ipc.wire_bytes_written(&w)
	bad[8] = 9 // phase out of range
	r = ipc.wire_reader(bad)
	_ = ipc.dec_tell_result(&r)
	testing.expect(t, !r.ok, "bad phase rejected")

	nx := ipc.Next_Result{id = 7, from = 2, parent = 5, body = "task"}
	w = ipc.wire_writer(buf[:])
	ipc.enc_next_result(&w, nx)
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	testing.expect(t, ipc.dec_next_result(&r) == nx && ipc.wr_done(&r), "next result round-trips")

	an := ipc.Answer_Msg{by = 4, id = 7, failed = true, text = "no"}
	w = ipc.wire_writer(buf[:])
	ipc.enc_answer(&w, an)
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	testing.expect(t, ipc.dec_answer(&r) == an && ipc.wr_done(&r), "answer round-trips")

	rr := ipc.Result_Request{caller = 1, wait = true, follow = false, timeout_ms = 500, ids = {0 = 7, 1 = 9}, n_ids = 2}
	w = ipc.wire_writer(buf[:])
	ipc.enc_result_req(&w, rr)
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	testing.expect(t, ipc.dec_result_req(&r) == rr && ipc.wr_done(&r), "result request round-trips")
	zero := ipc.Result_Request{n_ids = 0}
	w = ipc.wire_writer(buf[:])
	ipc.enc_result_req(&w, zero)
	r = ipc.wire_reader(ipc.wire_bytes_written(&w))
	_ = ipc.dec_result_req(&r)
	testing.expect(t, !r.ok, "no ids refused")
}

@(test)
test_msg_watch_roundtrip :: proc(t: ^testing.T) {
	req := ipc.Watch_Request{
		id             = 42,
		events         = {.Prompt, .Exit},
		timeout_ms     = 5000,
		has_since      = true,
		since          = 7,
	}
	buf: [64]u8
	w := ipc.wire_writer(buf[:])
	ipc.enc_watch_req(&w, req)
	testing.expect(t, w.ok, "enc_watch_req ok")
	r := ipc.wire_reader(ipc.wire_bytes_written(&w))
	got_req := ipc.dec_watch_req(&r)
	testing.expect(t, ipc.wr_done(&r), "dec_watch_req wr_done")
	testing.expect(t, got_req.id == req.id, "req id matches")
	testing.expect(t, got_req.events == req.events, "req events match")
	testing.expect(t, got_req.timeout_ms == req.timeout_ms, "req timeout_ms matches")
	testing.expect(t, got_req.has_since && got_req.since == req.since, "req since matches")

	res := ipc.Watch_Result{
		id           = 42,
		event        = .Prompt,
		exit_code    = 0,
		prompt_state = .Prompt,
		cmd_seq      = 8,
	}
	w2 := ipc.wire_writer(buf[:])
	ipc.enc_watch_result(&w2, res)
	testing.expect(t, w2.ok, "enc_watch_result ok")
	r2 := ipc.wire_reader(ipc.wire_bytes_written(&w2))
	got_res := ipc.dec_watch_result(&r2)
	testing.expect(t, ipc.wr_done(&r2), "dec_watch_result wr_done")
	testing.expect(t, got_res.id == res.id, "res id matches")
	testing.expect(t, got_res.event == res.event, "res event matches")
	testing.expect(t, got_res.exit_code == res.exit_code, "res exit_code matches")
	testing.expect(t, got_res.prompt_state == res.prompt_state, "res prompt_state matches")
	testing.expect(t, got_res.cmd_seq == res.cmd_seq, "res cmd_seq matches")
}

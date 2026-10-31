package platform_ipc_tests

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "core:c"
import ipc "../"

@(private = "file")
server_counter: int

@(private = "file")
wake_counter: i32

@(private = "file")
wake_cb :: proc "contextless" (user_data: rawptr) {
	intrinsics.atomic_add(&wake_counter, 1)
}

@(private = "file")
unique_sock :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 do tmp = "/tmp"
	server_counter += 1
	return fmt.tprintf("%s/ipcs-%d-%d.sock", tmp, int(posix.getpid()), server_counter)
}

@(private = "file")
Client_Result :: struct {
	buf:   [ipc.IPC_MAX_REPLY]u8,
	reply: string,
	err:   ipc.Ipc_Error,
	done:  bool,
}

@(private = "file")
Client_Arg :: struct {
	path:       string,
	line:       string,
	timeout_ms: int,
	result:     ^Client_Result,
}

@(private = "file")
client_thread :: proc(a: Client_Arg) {
	r, e := ipc.ipc_client_request(a.path, a.line, a.result.buf[:], a.timeout_ms)
	a.result.reply = r
	a.result.err = e
	intrinsics.atomic_store(&a.result.done, true)
}

@(private = "file")
raw_connect :: proc(path: string) -> posix.FD {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	addr: posix.sockaddr_un
	if !ipc.ipc_fill_sockaddr(path, &addr) { posix.close(fd); return -1 }
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK { posix.close(fd); return -1 }
	return fd
}

@(private = "file")
lstat_ok :: proc(path: string) -> bool {
	buf: [256]u8
	if len(path) + 1 > len(buf) do return false
	copy(buf[:], path)
	buf[len(path)] = 0
	cpath := cstring(raw_data(buf[:]))
	st: posix.stat_t
	return posix.lstat(cpath, &st) == .OK
}

@test
test_server_roundtrip_and_wake :: proc(t: ^testing.T) {
	intrinsics.atomic_store(&wake_counter, 0)
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	res := Client_Result{}
	arg := Client_Arg{path = path, line = "ping", timeout_ms = ipc.IPC_CLIENT_TIMEOUT_MS, result = &res}
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	deadline := time.tick_now()._nsec + 2_000_000_000
	for time.tick_now()._nsec < deadline {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) {
			line := ipc.ipc_request_line(&req)
			payload := fmt.tprintf("ok\n%s\n", line)
			ipc.ipc_server_reply(srv, req.ticket, payload)
		}
		time.sleep(1 * time.Millisecond)
		if intrinsics.atomic_load(&res.done) do break
	}
	thread.join(thr)
	thread.destroy(thr)

	testing.expect_value(t, res.err, ipc.Ipc_Error.None)
	testing.expect_value(t, res.reply, "ok\nping\n")
	testing.expect(t, intrinsics.atomic_load(&wake_counter) >= 1, "wake >= 1")
}

@test
test_server_poll_never_blocks :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	start := time.tick_now()
	got := false
	for i in 0 ..< 10000 {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) do got = true
	}
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	testing.expect(t, !got, "no requests")
	testing.expect(t, elapsed < 50, "poll fast")
}

@test
test_server_busy_when_mailbox_full :: proc(t: ^testing.T) {
	intrinsics.atomic_store(&wake_counter, 0)
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	n := ipc.IPC_MAILBOX_CAP + 2
	args := make([]Client_Arg, n, context.temp_allocator)
	results := make([]Client_Result, n, context.temp_allocator)
	threads := make([]^thread.Thread, n, context.temp_allocator)
	for i in 0 ..< n {
		results[i] = Client_Result{}
		args[i] = Client_Arg{path = path, line = fmt.tprintf("c%d", i), timeout_ms = 4000, result = &results[i]}
		threads[i] = thread.create_and_start_with_poly_data(args[i], client_thread)
		testing.expect(t, threads[i] != nil, "thread")
	}

	time.sleep(300 * time.Millisecond)

	deadline := time.tick_now()._nsec + 4_000_000_000
	pending := n
	for time.tick_now()._nsec < deadline && pending > 0 {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) {
			line := ipc.ipc_request_line(&req)
			payload := fmt.tprintf("ok\n%s\n", line)
			ipc.ipc_server_reply(srv, req.ticket, payload)
		}
		time.sleep(1 * time.Millisecond)
		pending = 0
		for i in 0 ..< n {
			if !intrinsics.atomic_load(&results[i].done) do pending += 1
		}
	}
	for i in 0 ..< n {
		if threads[i] != nil {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}

	busy_count := 0
	for i in 0 ..< n {
		if results[i].err == ipc.Ipc_Error.Busy {
			busy_count += 1
			testing.expect_value(t, results[i].reply, "err busy\n")
		} else {
			testing.expect_value(t, results[i].err, ipc.Ipc_Error.None)
			expected := fmt.tprintf("ok\nc%d\n", i)
			testing.expect_value(t, results[i].reply, expected)
		}
	}
	testing.expect(t, busy_count >= 1, "at least one busy")
}

@test
test_server_timeout_when_main_never_replies :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	res := Client_Result{}
	arg := Client_Arg{path = path, line = "x", timeout_ms = 5000, result = &res}
	start := time.tick_now()
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	ticket: u64
	got := false
	poll_deadline := time.tick_now()._nsec + 1_000_000_000
	for time.tick_now()._nsec < poll_deadline && !got {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) {
			ticket = req.ticket
			got = true
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, got, "polled request")

	thread.join(thr)
	thread.destroy(thr)

	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	testing.expect(t, elapsed >= 2500, "not too early")
	testing.expect(t, elapsed <= 4500, "not too late")
	testing.expect_value(t, res.reply, "err timeout\n")

	// late reply should not crash / change nothing
	ipc.ipc_server_reply(srv, ticket, "late\n")
}

@test
test_server_slow_reader_does_not_stall :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	rawfd := raw_connect(path)
	testing.expect(t, rawfd >= 0, "raw connect")
	defer if rawfd >= 0 do posix.close(rawfd)

	res := Client_Result{}
	arg := Client_Arg{path = path, line = "ping", timeout_ms = ipc.IPC_CLIENT_TIMEOUT_MS, result = &res}
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	start := time.tick_now()
	deadline := start._nsec + 500_000_000
	for time.tick_now()._nsec < deadline && !intrinsics.atomic_load(&res.done) {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) {
			line := ipc.ipc_request_line(&req)
			payload := fmt.tprintf("ok\n%s\n", line)
			ipc.ipc_server_reply(srv, req.ticket, payload)
		}
		time.sleep(1 * time.Millisecond)
	}
	thread.join(thr)
	thread.destroy(thr)

	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	testing.expect(t, elapsed <= 500, "within 500ms")
	testing.expect_value(t, res.err, ipc.Ipc_Error.None)
	testing.expect_value(t, res.reply, "ok\nping\n")
}

@test
test_server_oversized_line :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	fd := raw_connect(path)
	testing.expect(t, fd >= 0, "connect")
	if fd < 0 do return
	defer posix.close(fd)

	buf: [ipc.IPC_MAX_LINE]u8
	for i in 0 ..< len(buf) do buf[i] = 'a'
	off := 0
	for off < len(buf) {
		n := posix.send(fd, &buf[off], c.size_t(len(buf) - off), {.NOSIGNAL})
		if n > 0 { off += int(n); continue }
		if n < 0 && posix.errno() == .EINTR do continue
		break
	}

	out: [1024]u8
	received := 0
	deadline := time.tick_now()._nsec + 2_000_000_000
	for received < len(out) && time.tick_now()._nsec < deadline {
		n := posix.recv(fd, &out[received], c.size_t(len(out) - received), {})
		if n > 0 { received += int(n); continue }
		if n == 0 do break
		e := posix.errno()
		if e == .EINTR do continue
		if e == .EAGAIN {
			pfd := posix.pollfd{fd = fd, events = {.IN}}
			posix.poll(&pfd, 1, 100)
			continue
		}
		break
	}
	reply := string(out[:received])
	testing.expect_value(t, reply, "err too_large\n")
}

@test
test_server_stop_flushes_pending_reply :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv)

	res := Client_Result{}
	arg := Client_Arg{path = path, line = "quit", timeout_ms = 4000, result = &res}
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	ticket: u64
	got := false
	poll_deadline := time.tick_now()._nsec + 1_000_000_000
	for time.tick_now()._nsec < poll_deadline && !got {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv, &req) {
			ticket = req.ticket
			got = true
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, got, "polled")
	ipc.ipc_server_reply(srv, ticket, "ok\n")
	ipc.ipc_server_stop(srv)

	thread.join(thr)
	thread.destroy(thr)

	testing.expect_value(t, res.err, ipc.Ipc_Error.None)
	testing.expect_value(t, res.reply, "ok\n")
}

@test
test_server_stop_idempotent_and_unlinks :: proc(t: ^testing.T) {
	srv := new(ipc.Ipc_Server)
	defer free(srv)
	path := unique_sock()
	defer os.remove(path)
	err := ipc.ipc_server_start(srv, path, wake_cb, nil)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return

	start := time.tick_now()
	ipc.ipc_server_stop(srv)
	ipc.ipc_server_stop(srv)
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	testing.expect(t, elapsed < 1500, "stop fast")

	testing.expect(t, !lstat_ok(path), "socket unlinked")

	out: [64]u8
	_, rerr := ipc.ipc_client_request(path, "ping", out[:], 1000)
	testing.expect_value(t, rerr, ipc.Ipc_Error.Not_Running)
}

@test
test_server_already_running :: proc(t: ^testing.T) {
	srv1 := new(ipc.Ipc_Server)
	defer free(srv1)
	srv2 := new(ipc.Ipc_Server)
	defer free(srv2)
	path := unique_sock()
	defer os.remove(path)
	err1 := ipc.ipc_server_start(srv1, path, wake_cb, nil)
	testing.expect_value(t, err1, ipc.Ipc_Error.None)
	if err1 != ipc.Ipc_Error.None do return
	defer ipc.ipc_server_stop(srv1)

	err2 := ipc.ipc_server_start(srv2, path, wake_cb, nil)
	testing.expect_value(t, err2, ipc.Ipc_Error.Already_Running)

	// first still answers
	res := Client_Result{}
	arg := Client_Arg{path = path, line = "ping", timeout_ms = ipc.IPC_CLIENT_TIMEOUT_MS, result = &res}
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return
	deadline := time.tick_now()._nsec + 2_000_000_000
	for time.tick_now()._nsec < deadline && !intrinsics.atomic_load(&res.done) {
		req: ipc.Ipc_Request
		if ipc.ipc_server_poll(srv1, &req) {
			line := ipc.ipc_request_line(&req)
			payload := fmt.tprintf("ok\n%s\n", line)
			ipc.ipc_server_reply(srv1, req.ticket, payload)
		}
		time.sleep(1 * time.Millisecond)
	}
	thread.join(thr)
	thread.destroy(thr)
	testing.expect_value(t, res.err, ipc.Ipc_Error.None)
	testing.expect_value(t, res.reply, "ok\nping\n")
}

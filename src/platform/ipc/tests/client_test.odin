package platform_ipc_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "core:c"
import ipc "../"

@(private = "file")
client_counter: int

@(private = "file")
Server_Ctx :: struct {
	listen_fd: posix.FD,
	mode:      int,
	req_buf:   [ipc.IPC_MAX_LINE]u8,
	req_len:   int,
}

@(private = "file")
server_thread :: proc(ctx: ^Server_Ctx) {
	pfd := posix.pollfd{fd = ctx.listen_fd, events = {.IN}}
	if posix.poll(&pfd, 1, 2000) <= 0 do return
	conn := posix.accept(ctx.listen_fd, nil, nil)
	if conn < 0 do return
	defer posix.close(conn)

	req: [ipc.IPC_MAX_LINE]u8
	rn := 0
	for rn < len(req) {
		r := posix.recv(conn, &req[rn], 1, {})
		if r <= 0 do break
		rn += 1
		if req[rn-1] == '\n' do break
	}
	ctx.req_len = rn
	copy(ctx.req_buf[:], req[:rn])

	switch ctx.mode {
	case 0:
		msg := "ok\nhello\n"
		off := 0
		for off < len(msg) {
			r := posix.send(conn, raw_data(msg[off:]), c.size_t(len(msg)) - c.size_t(off), {})
			if r <= 0 do break
			off += int(r)
		}
	case 1:
		time.sleep(1500 * time.Millisecond)
	case 2:
		data: [2048]u8
		for i in 0 ..< len(data) do data[i] = 'a'
		off := 0
		for off < len(data) {
			r := posix.send(conn, &data[off], c.size_t(len(data) - off), {})
			if r <= 0 do break
			off += int(r)
		}
	case 3:
		msg := "err busy\n"
		off := 0
		for off < len(msg) {
			r := posix.send(conn, raw_data(msg[off:]), c.size_t(len(msg)) - c.size_t(off), {})
			if r <= 0 do break
			off += int(r)
		}
	}
}

@(private = "file")
unique_path :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 do tmp = "/tmp"
	client_counter += 1
	return fmt.tprintf("%s/ipcc-%d-%d.sock", tmp, int(posix.getpid()), client_counter)
}

@test
test_client_roundtrip :: proc(t: ^testing.T) {
	path := unique_path()
	defer os.remove(path)

	fd, _, err := ipc.ipc_bind_listener(path)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer posix.close(fd)

	ctx := Server_Ctx{listen_fd = fd, mode = 0}
	thr := thread.create_and_start_with_poly_data(&ctx, server_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	out: [1024]u8
	reply, rerr := ipc.ipc_client_request(path, "ping", out[:])
	testing.expect_value(t, rerr, ipc.Ipc_Error.None)
	testing.expect_value(t, reply, "ok\nhello\n")

	thread.join(thr)
	thread.destroy(thr)
	testing.expect_value(t, string(ctx.req_buf[:ctx.req_len]), "ping\n")
}

@test
test_client_not_running :: proc(t: ^testing.T) {
	path := unique_path()
	defer os.remove(path)

	out: [64]u8
	_, err := ipc.ipc_client_request(path, "ping", out[:])
	testing.expect_value(t, err, ipc.Ipc_Error.Not_Running)

	fd, _, berr := ipc.ipc_bind_listener(path)
	testing.expect_value(t, berr, ipc.Ipc_Error.None)
	if berr == ipc.Ipc_Error.None && fd >= 0 {
		posix.close(fd)
	}
	_, err2 := ipc.ipc_client_request(path, "ping", out[:])
	testing.expect_value(t, err2, ipc.Ipc_Error.Not_Running)
}

@test
test_client_timeout :: proc(t: ^testing.T) {
	path := unique_path()
	defer os.remove(path)

	fd, _, err := ipc.ipc_bind_listener(path)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer posix.close(fd)

	ctx := Server_Ctx{listen_fd = fd, mode = 1}
	thr := thread.create_and_start_with_poly_data(&ctx, server_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	out: [1024]u8
	start := time.tick_now()
	reply, rerr := ipc.ipc_client_request(path, "ping", out[:], 300)
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	testing.expect_value(t, rerr, ipc.Ipc_Error.Timeout)
	testing.expect(t, elapsed < 1000, "must return within 1000 ms")

	thread.join(thr)
	thread.destroy(thr)
	_ = reply
}

@test
test_client_too_large :: proc(t: ^testing.T) {
	path := unique_path()
	defer os.remove(path)

	fd, _, err := ipc.ipc_bind_listener(path)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer posix.close(fd)

	ctx := Server_Ctx{listen_fd = fd, mode = 2}
	thr := thread.create_and_start_with_poly_data(&ctx, server_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	out: [1024]u8
	_, rerr := ipc.ipc_client_request(path, "ping", out[:])
	testing.expect_value(t, rerr, ipc.Ipc_Error.Too_Large)

	thread.join(thr)
	thread.destroy(thr)
}

@test
test_client_rejects_bad_line :: proc(t: ^testing.T) {
	big := make([]u8, 5000, context.temp_allocator)
	for i in 0 ..< 5000 do big[i] = 'a'
	out: [64]u8
	_, err := ipc.ipc_client_request("/tmp/x.sock", string(big), out[:])
	testing.expect_value(t, err, ipc.Ipc_Error.Too_Large)
	_, err2 := ipc.ipc_client_request("/tmp/x.sock", "a\nb", out[:])
	testing.expect_value(t, err2, ipc.Ipc_Error.Socket_Failed)
}

@test
test_client_busy :: proc(t: ^testing.T) {
	path := unique_path()
	defer os.remove(path)

	fd, _, err := ipc.ipc_bind_listener(path)
	testing.expect_value(t, err, ipc.Ipc_Error.None)
	if err != ipc.Ipc_Error.None do return
	defer posix.close(fd)

	ctx := Server_Ctx{listen_fd = fd, mode = 3}
	thr := thread.create_and_start_with_poly_data(&ctx, server_thread)
	testing.expect(t, thr != nil, "thread")
	if thr == nil do return

	out: [1024]u8
	reply, rerr := ipc.ipc_client_request(path, "ping", out[:])
	testing.expect_value(t, rerr, ipc.Ipc_Error.Busy)
	testing.expect_value(t, reply, "err busy\n")

	thread.join(thr)
	thread.destroy(thr)
}
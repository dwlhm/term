package session_ipc_test

import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(test)
test_transport_server_client_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_test_sock_%d_%d.sock", pid, now)

	server: ipc.Socket_Server
	s_err := ipc.server_init(&server, sock_path)
	testing.expect_value(t, s_err, ipc.Transport_Error.None)
	defer ipc.server_close(&server)

	client: ipc.Socket_Client
	c_err := ipc.client_connect(&client, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer ipc.client_close(&client)

	slot, a_err := ipc.server_accept(&server)
	testing.expect_value(t, a_err, ipc.Transport_Error.None)
	testing.expect(t, slot >= 0, "server slot should be valid")

	hello_frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Hello,
		},
		payload = transmute([]u8)string("term_client_v1"),
	}

	written, send_err := ipc.client_send_frame(&client, hello_frame)
	testing.expect_value(t, send_err, ipc.Transport_Error.None)
	testing.expect(t, written > 0, "client must send bytes")

	recv_frame, consumed, status := ipc.server_recv_frame(&server, slot)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, recv_frame.header.kind, ipc.Message_Kind.Hello)
	testing.expect_value(t, string(recv_frame.payload), "term_client_v1")

	ack_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Ack,
			request_id = 42,
		},
		payload = transmute([]u8)string("ok"),
	}

	aw, as_err := ipc.server_send_frame(&server, slot, ack_frame)
	testing.expect_value(t, as_err, ipc.Transport_Error.None)
	testing.expect(t, aw > 0, "server must send bytes")

	c_recv, c_consumed, c_status := ipc.client_recv_frame(&client)
	testing.expect_value(t, c_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, c_consumed, aw)
	testing.expect_value(t, c_recv.header.kind, ipc.Message_Kind.Ack)
	testing.expect_value(t, c_recv.header.request_id, u64(42))
	testing.expect_value(t, string(c_recv.payload), "ok")

	ipc.client_close(&client)
	ipc.server_close(&server)

	c_path := strings.clone_to_cstring(sock_path, context.temp_allocator)
	st: posix.stat_t
	testing.expect(t, posix.stat(c_path, &st) != .OK, "socket file should be unlinked")

	c_lock := strings.clone_to_cstring(fmt.tprintf("%s.lock", sock_path), context.temp_allocator)
	testing.expect(t, posix.stat(c_lock, &st) != .OK, "lock file should be unlinked")
}

@(test)
test_transport_singleton_lock :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_test_lock_%d_%d.sock", pid, now)

	s1: ipc.Socket_Server
	err1 := ipc.server_init(&s1, sock_path)
	testing.expect_value(t, err1, ipc.Transport_Error.None)

	s2: ipc.Socket_Server
	err2 := ipc.server_init(&s2, sock_path)
	testing.expect_value(t, err2, ipc.Transport_Error.Lock_Failed)

	ipc.server_close(&s1)

	err2_retry := ipc.server_init(&s2, sock_path)
	testing.expect_value(t, err2_retry, ipc.Transport_Error.None)

	ipc.server_close(&s2)
}

@(test)
test_transport_peer_uid_validation :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	res := posix.socketpair(.UNIX, .STREAM, .IP, &fds)
	testing.expect_value(t, res, posix.result.OK)
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	testing.expect(t, ipc.validate_peer_uid(fds[0]), "peer uid on fds[0] should be current uid")
	testing.expect(t, ipc.validate_peer_uid(fds[1]), "peer uid on fds[1] should be current uid")
}

@(test)
test_transport_large_snapshot_frame_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_test_large_%d_%d.sock", pid, now)

	server: ipc.Socket_Server
	s_err := ipc.server_init(&server, sock_path)
	testing.expect_value(t, s_err, ipc.Transport_Error.None)
	defer ipc.server_close(&server)

	client: ipc.Socket_Client
	c_err := ipc.client_connect(&client, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer ipc.client_close(&client)

	slot, a_err := ipc.server_accept(&server)
	testing.expect_value(t, a_err, ipc.Transport_Error.None)
	testing.expect(t, slot >= 0, "server slot should be valid")

	LARGE_SIZE :: 256 * 1024
	payload := make([]u8, LARGE_SIZE, context.temp_allocator)
	for i in 0..<LARGE_SIZE {
		payload[i] = u8((i * 31 + 7) & 0xFF)
	}

	large_frame := ipc.Frame{
		header = {
			major     = ipc.PROTOCOL_MAJOR,
			minor     = ipc.PROTOCOL_MINOR,
			kind      = .Snapshot_Section,
			stream_id = 999,
			sequence  = 1,
		},
		payload = payload,
	}

	w, send_err := ipc.client_send_frame(&client, large_frame)
	testing.expect_value(t, send_err, ipc.Transport_Error.None)
	testing.expect(t, w >= LARGE_SIZE, "written bytes must cover payload")

	recv_f, consumed, status := ipc.server_recv_frame(&server, slot)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, w)
	testing.expect_value(t, recv_f.header.kind, ipc.Message_Kind.Snapshot_Section)
	testing.expect_value(t, recv_f.header.stream_id, u64(999))
	testing.expect_value(t, recv_f.header.sequence, u64(1))
	testing.expect_value(t, len(recv_f.payload), LARGE_SIZE)

	corrupted := false
	for i in 0..<LARGE_SIZE {
		if recv_f.payload[i] != payload[i] {
			corrupted = true
			break
		}
	}
	testing.expect(t, !corrupted, "large payload received corrupted")
}

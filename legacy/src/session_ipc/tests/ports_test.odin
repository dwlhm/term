package session_ipc_test

import "core:fmt"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(test)
test_ports_uds_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_ports_roundtrip_%d_%d.sock", pid, now)

	host_adapter: ipc.UDS_Host_Adapter
	host_port := ipc.uds_host_make_port(&host_adapter)
	testing.expect_value(t, host_port.kind, ipc.Transport_Kind.UDS)

	ok := host_port.listen_endpoint(host_port.user_data, sock_path)
	testing.expect(t, ok, "host port must listen")
	defer host_port.close_endpoint(host_port.user_data)

	client_adapter: ipc.UDS_Client_Adapter
	client_port := ipc.uds_client_make_port(&client_adapter)
	testing.expect_value(t, client_port.kind, ipc.Transport_Kind.UDS)

	c_err := client_port.connect_endpoint(client_port.user_data, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	client_id, accept_ok := host_port.accept_client(host_port.user_data)
	testing.expect(t, accept_ok, "host must accept client")
	testing.expect(t, client_id >= 0, "client_id must be non-negative")

	// 1. Client sends Hello frame to Host via port interface
	hello_frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Hello,
		},
		payload = transmute([]u8)string("term_ports_client_v1"),
	}

	written, send_err := client_port.send_frame(client_port.user_data, hello_frame)
	testing.expect_value(t, send_err, ipc.Transport_Error.None)
	testing.expect(t, written > 0, "client must send bytes")

	recv_frame, consumed, status := host_port.recv_frame(host_port.user_data, client_id)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, recv_frame.header.kind, ipc.Message_Kind.Hello)
	testing.expect_value(t, string(recv_frame.payload), "term_ports_client_v1")

	// 2. Host sends Ack frame back to Client via port interface
	ack_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Ack,
			request_id = 42,
		},
		payload = transmute([]u8)string("ok"),
	}

	aw, as_err := host_port.send_frame(host_port.user_data, client_id, ack_frame)
	testing.expect_value(t, as_err, ipc.Transport_Error.None)
	testing.expect(t, aw > 0, "host must send ack bytes")

	c_recv, c_consumed, c_status := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, c_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, c_consumed, aw)
	testing.expect_value(t, c_recv.header.kind, ipc.Message_Kind.Ack)
	testing.expect_value(t, c_recv.header.request_id, u64(42))
	testing.expect_value(t, string(c_recv.payload), "ok")

	// 3. Host publishes snapshot via publish_snapshot, Client reads via read_snapshot
	snap_payload := []u8{10, 20, 30, 40, 50, 60, 70, 80}
	snap_stream_id := u64(101)
	snap_seq := u64(777)
	snap_w, snap_err := host_port.publish_snapshot(
		host_port.user_data,
		client_id,
		snap_stream_id,
		snap_seq,
		snap_payload,
	)
	testing.expect_value(t, snap_err, ipc.Transport_Error.None)
	testing.expect(t, snap_w > 0, "publish_snapshot must send bytes")

	out_buf: [128]u8
	n, seq, read_ok := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, read_ok, "read_snapshot must succeed")
	testing.expect_value(t, seq, snap_seq)
	testing.expect_value(t, n, len(snap_payload))
	testing.expect(t, slice.equal(out_buf[:n], snap_payload), "snapshot payload must match")

	// Clean up endpoints
	client_port.close_endpoint(client_port.user_data)
	host_port.close_endpoint(host_port.user_data)

	// Verify unlinked files
	c_path := strings.clone_to_cstring(sock_path, context.temp_allocator)
	st: posix.stat_t
	testing.expect(t, posix.stat(c_path, &st) != .OK, "socket file should be unlinked")

	c_lock := strings.clone_to_cstring(fmt.tprintf("%s.lock", sock_path), context.temp_allocator)
	testing.expect(t, posix.stat(c_lock, &st) != .OK, "lock file should be unlinked")
}

@(test)
test_ports_uds_nonblocking_slow_consumer :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	sock_path := fmt.tprintf("/tmp/term_ports_slow_%d_%d.sock", pid, now)

	host_adapter: ipc.UDS_Host_Adapter
	host_port := ipc.uds_host_make_port(&host_adapter)
	ok := host_port.listen_endpoint(host_port.user_data, sock_path)
	testing.expect(t, ok, "host port must listen")
	defer host_port.close_endpoint(host_port.user_data)

	client_adapter: ipc.UDS_Client_Adapter
	client_port := ipc.uds_client_make_port(&client_adapter)
	c_err := client_port.connect_endpoint(client_port.user_data, sock_path)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	client_id, accept_ok := host_port.accept_client(host_port.user_data)
	testing.expect(t, accept_ok, "host must accept client")
	testing.expect(t, client_id >= 0, "client_id must be non-negative")

	// Payload of 256KB: client does not read, socket buffers fill quickly
	CHUNK_SIZE :: 256 * 1024
	payload := make([]u8, CHUNK_SIZE, context.temp_allocator)
	for i in 0..<CHUNK_SIZE {
		payload[i] = u8(i & 0xFF)
	}

	frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Snapshot_Section,
		},
		payload = payload,
	}

	start := time.tick_now()
	hit_buffer_full := false
	for _ in 0..<100 {
		_, send_err := host_port.send_frame(host_port.user_data, client_id, frame)
		if send_err == .Buffer_Full {
			hit_buffer_full = true
			break
		}
		if send_err != .None {
			testing.expect(t, false, "unexpected send error before buffer full")
			break
		}
	}
	elapsed := time.tick_since(start)

	testing.expect(t, hit_buffer_full, "send_frame should return Buffer_Full when buffer saturates")
	testing.expect(t, time.duration_seconds(elapsed) < 2.0, "send_frame must return immediately without 5s blocking")
}

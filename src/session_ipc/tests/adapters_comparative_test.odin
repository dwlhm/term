package session_ipc_test

import "core:fmt"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(test)
test_adapter_shm_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	endpoint := fmt.tprintf("/tmp/term_test_shm_roundtrip_%d_%d.sock", pid, now)

	host_adapter: ipc.SHM_Host_Adapter
	host_port := ipc.shm_host_make_port(&host_adapter)
	testing.expect_value(t, host_port.kind, ipc.Transport_Kind.SHM)

	ok := host_port.listen_endpoint(host_port.user_data, endpoint)
	testing.expect(t, ok, "host shm port must listen")
	defer host_port.close_endpoint(host_port.user_data)

	client_adapter: ipc.SHM_Client_Adapter
	client_port := ipc.shm_client_make_port(&client_adapter)
	testing.expect_value(t, client_port.kind, ipc.Transport_Kind.SHM)

	c_err := client_port.connect_endpoint(client_port.user_data, endpoint)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	client_id, accept_ok := host_port.accept_client(host_port.user_data)
	testing.expect(t, accept_ok, "host must accept client")
	testing.expect(t, client_id >= 0, "client_id must be non-negative")

	// 1. Control frame: Client -> Host
	hello_frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Hello,
		},
		payload = transmute([]u8)string("term_shm_client_v1"),
	}

	written, send_err := client_port.send_frame(client_port.user_data, hello_frame)
	testing.expect_value(t, send_err, ipc.Transport_Error.None)
	testing.expect(t, written > 0, "client must send bytes")

	recv_frame, consumed, status := host_port.recv_frame(host_port.user_data, client_id)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, recv_frame.header.kind, ipc.Message_Kind.Hello)
	testing.expect_value(t, string(recv_frame.payload), "term_shm_client_v1")

	// 2. Control frame: Host -> Client
	ack_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Ack,
			request_id = 12345,
		},
		payload = transmute([]u8)string("ack_from_shm_host"),
	}

	aw, as_err := host_port.send_frame(host_port.user_data, client_id, ack_frame)
	testing.expect_value(t, as_err, ipc.Transport_Error.None)
	testing.expect(t, aw > 0, "host must send ack")

	c_recv, c_consumed, c_status := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, c_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, c_consumed, aw)
	testing.expect_value(t, c_recv.header.kind, ipc.Message_Kind.Ack)
	testing.expect_value(t, c_recv.header.request_id, u64(12345))
	testing.expect_value(t, string(c_recv.payload), "ack_from_shm_host")

	// 3. Snapshot delivery via SHM
	snap_payload := []u8{10, 20, 30, 40, 50, 60, 70, 80, 90, 100}
	snap_stream_id := u64(505)
	snap_seq := u64(9999)
	snap_w, snap_err := host_port.publish_snapshot(
		host_port.user_data,
		client_id,
		snap_stream_id,
		snap_seq,
		snap_payload,
	)
	testing.expect_value(t, snap_err, ipc.Transport_Error.None)
	testing.expect(t, snap_w > 0, "publish_snapshot must succeed")

	out_buf: [128]u8
	n, seq, read_ok := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, read_ok, "read_snapshot must succeed")
	testing.expect_value(t, seq, snap_seq)
	testing.expect_value(t, n, len(snap_payload))
	testing.expect(t, slice.equal(out_buf[:n], snap_payload), "snapshot payload must match exactly")

	// Close endpoints
	client_port.close_endpoint(client_port.user_data)
	host_port.close_endpoint(host_port.user_data)

	// Verify unlinked socket and shared memory files
	c_path := strings.clone_to_cstring(endpoint, context.temp_allocator)
	st: posix.stat_t
	testing.expect(t, posix.stat(c_path, &st) != .OK, "socket file should be unlinked")

	shm_dat := fmt.tprintf("%s.dat", endpoint[:len(endpoint) - 5])
	c_dat := strings.clone_to_cstring(shm_dat, context.temp_allocator)
	testing.expect(t, posix.stat(c_dat, &st) != .OK, "shm dat file should be unlinked")

	pipe_path := fmt.tprintf("%s.pipe", endpoint)
	c_pipe := strings.clone_to_cstring(pipe_path, context.temp_allocator)
	testing.expect(t, posix.stat(c_pipe, &st) != .OK, "pipe file should be unlinked")
}

@(test)
test_adapter_hybrid_roundtrip :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	endpoint := fmt.tprintf("/tmp/term_test_hybrid_roundtrip_%d_%d.sock", pid, now)

	host_adapter: ipc.Hybrid_Host_Adapter
	host_port := ipc.hybrid_host_make_port(&host_adapter)
	testing.expect_value(t, host_port.kind, ipc.Transport_Kind.Hybrid)

	ok := host_port.listen_endpoint(host_port.user_data, endpoint)
	testing.expect(t, ok, "host hybrid port must listen")
	defer host_port.close_endpoint(host_port.user_data)

	client_adapter: ipc.Hybrid_Client_Adapter
	client_port := ipc.hybrid_client_make_port(&client_adapter)
	testing.expect_value(t, client_port.kind, ipc.Transport_Kind.Hybrid)

	c_err := client_port.connect_endpoint(client_port.user_data, endpoint)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	client_id, accept_ok := host_port.accept_client(host_port.user_data)
	testing.expect(t, accept_ok, "host must accept client")
	testing.expect(t, client_id >= 0, "client_id must be non-negative")

	// 1. Control frame travels over UDS: Client -> Host
	hello_frame := ipc.Frame{
		header = {
			major = ipc.PROTOCOL_MAJOR,
			minor = ipc.PROTOCOL_MINOR,
			kind  = .Hello,
		},
		payload = transmute([]u8)string("term_hybrid_client_v1"),
	}

	written, send_err := client_port.send_frame(client_port.user_data, hello_frame)
	testing.expect_value(t, send_err, ipc.Transport_Error.None)
	testing.expect(t, written > 0, "client must send bytes")

	recv_frame, consumed, status := host_port.recv_frame(host_port.user_data, client_id)
	testing.expect_value(t, status, ipc.Codec_Status.Ok)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, recv_frame.header.kind, ipc.Message_Kind.Hello)
	testing.expect_value(t, string(recv_frame.payload), "term_hybrid_client_v1")

	// 2. Control frame travels over UDS: Host -> Client
	ack_frame := ipc.Frame{
		header = {
			major      = ipc.PROTOCOL_MAJOR,
			minor      = ipc.PROTOCOL_MINOR,
			kind       = .Ack,
			request_id = 9876,
		},
		payload = transmute([]u8)string("ack_from_hybrid_host"),
	}

	aw, as_err := host_port.send_frame(host_port.user_data, client_id, ack_frame)
	testing.expect_value(t, as_err, ipc.Transport_Error.None)
	testing.expect(t, aw > 0, "host must send ack")

	c_recv, c_consumed, c_status := client_port.recv_frame(client_port.user_data)
	testing.expect_value(t, c_status, ipc.Codec_Status.Ok)
	testing.expect_value(t, c_consumed, aw)
	testing.expect_value(t, c_recv.header.kind, ipc.Message_Kind.Ack)
	testing.expect_value(t, c_recv.header.request_id, u64(9876))
	testing.expect_value(t, string(c_recv.payload), "ack_from_hybrid_host")

	// 3. Snapshot travels zero-copy over SHM with 40-byte UDS notification frame
	snap_payload := []u8{111, 222, 33, 44, 55, 66}
	snap_stream_id := u64(808)
	snap_seq := u64(4321)
	snap_w, snap_err := host_port.publish_snapshot(
		host_port.user_data,
		client_id,
		snap_stream_id,
		snap_seq,
		snap_payload,
	)
	testing.expect_value(t, snap_err, ipc.Transport_Error.None)
	testing.expect(t, snap_w > 0, "publish_snapshot must succeed")

	out_buf: [128]u8
	n, seq, read_ok := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, read_ok, "read_snapshot must succeed")
	testing.expect_value(t, seq, snap_seq)
	testing.expect_value(t, n, len(snap_payload))
	testing.expect(t, slice.equal(out_buf[:n], snap_payload), "snapshot payload must match exactly")

	// Clean up
	client_port.close_endpoint(client_port.user_data)
	host_port.close_endpoint(host_port.user_data)

	// Verify unlinked socket and shared memory files
	c_path := strings.clone_to_cstring(endpoint, context.temp_allocator)
	st: posix.stat_t
	testing.expect(t, posix.stat(c_path, &st) != .OK, "socket file should be unlinked")

	shm_dat := fmt.tprintf("%s.shm.dat", endpoint[:len(endpoint) - 5])
	c_dat := strings.clone_to_cstring(shm_dat, context.temp_allocator)
	testing.expect(t, posix.stat(c_dat, &st) != .OK, "hybrid shm dat file should be unlinked")
}

@(test)
test_adapter_shm_double_buffer_seqlock :: proc(t: ^testing.T) {
	pid := posix.getpid()
	now := time.to_unix_nanoseconds(time.now())
	endpoint := fmt.tprintf("/tmp/term_test_shm_dblbuf_%d_%d.sock", pid, now)

	host_adapter: ipc.SHM_Host_Adapter
	host_port := ipc.shm_host_make_port(&host_adapter)
	ok := host_port.listen_endpoint(host_port.user_data, endpoint)
	testing.expect(t, ok, "host shm port must listen")
	defer host_port.close_endpoint(host_port.user_data)

	client_adapter: ipc.SHM_Client_Adapter
	client_port := ipc.shm_client_make_port(&client_adapter)
	c_err := client_port.connect_endpoint(client_port.user_data, endpoint)
	testing.expect_value(t, c_err, ipc.Transport_Error.None)
	defer client_port.close_endpoint(client_port.user_data)

	client_id, accept_ok := host_port.accept_client(host_port.user_data)
	testing.expect(t, accept_ok, "host must accept client")

	// Publish snapshot 1 (slot 1)
	p1 := []u8{1, 1, 1, 1}
	_, err1 := host_port.publish_snapshot(host_port.user_data, client_id, 1, 101, p1)
	testing.expect_value(t, err1, ipc.Transport_Error.None)

	out_buf: [64]u8
	n1, s1, ok1 := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, ok1)
	testing.expect_value(t, s1, u64(101))
	testing.expect_value(t, n1, len(p1))
	testing.expect(t, slice.equal(out_buf[:n1], p1))

	// Publish snapshot 2 (slot 0)
	p2 := []u8{2, 2, 2, 2, 2, 2}
	_, err2 := host_port.publish_snapshot(host_port.user_data, client_id, 1, 102, p2)
	testing.expect_value(t, err2, ipc.Transport_Error.None)

	n2, s2, ok2 := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, ok2)
	testing.expect_value(t, s2, u64(102))
	testing.expect_value(t, n2, len(p2))
	testing.expect(t, slice.equal(out_buf[:n2], p2))

	// Publish snapshot 3 (slot 1)
	p3 := []u8{3, 3}
	_, err3 := host_port.publish_snapshot(host_port.user_data, client_id, 1, 103, p3)
	testing.expect_value(t, err3, ipc.Transport_Error.None)

	n3, s3, ok3 := client_port.read_snapshot(client_port.user_data, out_buf[:])
	testing.expect(t, ok3)
	testing.expect_value(t, s3, u64(103))
	testing.expect_value(t, n3, len(p3))
	testing.expect(t, slice.equal(out_buf[:n3], p3))
}

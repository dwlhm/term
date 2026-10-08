package session_ipc

import "core:fmt"

Hybrid_Host_Adapter :: struct {
	uds: UDS_Host_Adapter,
	shm: SHM_Host_Adapter,
}

Hybrid_Client_Adapter :: struct {
	uds: UDS_Client_Adapter,
	shm: SHM_Client_Adapter,
}

hybrid_host_make_port :: proc(a: ^Hybrid_Host_Adapter) -> Host_Transport_Port {
	if a != nil {
		if a.uds.server.listen_fd == 0 && a.uds.server.lock_fd == 0 && len(a.uds.server.socket_path) == 0 {
			a.uds.server.listen_fd = -1
			a.uds.server.lock_fd = -1
		}
		if a.shm.server.listen_fd == 0 && a.shm.server.lock_fd == 0 && len(a.shm.server.socket_path) == 0 {
			a.shm.server.listen_fd = -1
			a.shm.server.lock_fd = -1
		}
		if a.shm.shm_fd == 0 do a.shm.shm_fd = -1
		if a.shm.sig_pipe[0] == 0 && a.shm.sig_pipe[1] == 0 {
			a.shm.sig_pipe[0] = -1
			a.shm.sig_pipe[1] = -1
		}
	}
	return Host_Transport_Port{
		user_data         = rawptr(a),
		kind              = .Hybrid,
		listen_endpoint   = hybrid_host_listen_endpoint,
		accept_client     = hybrid_host_accept_client,
		send_frame        = hybrid_host_send_frame,
		recv_frame        = hybrid_host_recv_frame,
		publish_snapshot  = hybrid_host_publish_snapshot,
		disconnect_client = hybrid_host_disconnect_client,
		close_endpoint    = hybrid_host_close_endpoint,
	}
}

hybrid_client_make_port :: proc(a: ^Hybrid_Client_Adapter) -> Client_Transport_Port {
	if a != nil {
		if a.uds.client.fd == 0 && a.uds.client.read_buf == nil {
			a.uds.client.fd = -1
		}
		if a.shm.client.fd == 0 && a.shm.client.read_buf == nil {
			a.shm.client.fd = -1
		}
		if a.shm.shm_fd == 0 do a.shm.shm_fd = -1
		if a.shm.sig_pipe[0] == 0 && a.shm.sig_pipe[1] == 0 {
			a.shm.sig_pipe[0] = -1
			a.shm.sig_pipe[1] = -1
		}
	}
	return Client_Transport_Port{
		user_data        = rawptr(a),
		kind             = .Hybrid,
		connect_endpoint = hybrid_client_connect_endpoint,
		send_frame       = hybrid_client_send_frame,
		recv_frame       = hybrid_client_recv_frame,
		read_snapshot    = hybrid_client_read_snapshot,
		close_endpoint   = hybrid_client_close_endpoint,
	}
}

hybrid_host_listen_endpoint :: proc(user_data: rawptr, endpoint: string) -> bool {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return false

	if !uds_host_listen_endpoint(rawptr(&a.uds), endpoint) do return false
	shm_endpoint := fmt.tprintf("%s.shm", endpoint)
	if !shm_host_listen_endpoint(rawptr(&a.shm), shm_endpoint) {
		uds_host_close_endpoint(rawptr(&a.uds))
		return false
	}
	return true
}

hybrid_host_accept_client :: proc(user_data: rawptr) -> (client_id: int, ok: bool) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return -1, false
	c_id, a_ok := uds_host_accept_client(rawptr(&a.uds))
	if !a_ok do return -1, false
	_, _ = shm_host_accept_client(rawptr(&a.shm))
	return c_id, true
}

hybrid_host_send_frame :: proc(user_data: rawptr, client_id: int, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return 0, .Socket_Failed
	return uds_host_send_frame(rawptr(&a.uds), client_id, frame)
}

hybrid_host_recv_frame :: proc(user_data: rawptr, client_id: int) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return uds_host_recv_frame(rawptr(&a.uds), client_id)
}

hybrid_host_publish_snapshot :: proc(
	user_data: rawptr,
	client_id: int,
	stream_id: u64,
	seq: u64,
	payload: []u8,
) -> (written: int, err: Transport_Error) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return 0, .Socket_Failed

	// 1. Zero-copy write into shared memory slot
	_, shm_err := shm_host_publish_snapshot(rawptr(&a.shm), client_id, stream_id, seq, payload)
	if shm_err != .None do return 0, shm_err

	// 2. 40-byte notification frame sent over UDS (empty payload -> exactly FRAME_HEADER_BYTES = 40 bytes)
	notify_frame := Frame{
		header = {
			major     = PROTOCOL_MAJOR,
			minor     = PROTOCOL_MINOR,
			kind      = .Snapshot_Section,
			stream_id = stream_id,
			sequence  = seq,
		},
		payload = nil,
	}
	_, uds_err := uds_host_send_frame(rawptr(&a.uds), client_id, notify_frame)
	if uds_err != .None do return 0, uds_err

	return len(payload), .None
}

hybrid_host_disconnect_client :: proc(user_data: rawptr, client_id: int) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return
	uds_host_disconnect_client(rawptr(&a.uds), client_id)
	shm_host_disconnect_client(rawptr(&a.shm), client_id)
}

hybrid_host_close_endpoint :: proc(user_data: rawptr) {
	a := (^Hybrid_Host_Adapter)(user_data)
	if a == nil do return
	uds_host_close_endpoint(rawptr(&a.uds))
	shm_host_close_endpoint(rawptr(&a.shm))
}

hybrid_client_connect_endpoint :: proc(user_data: rawptr, endpoint: string) -> Transport_Error {
	a := (^Hybrid_Client_Adapter)(user_data)
	if a == nil do return .Connect_Failed
	u_err := uds_client_connect_endpoint(rawptr(&a.uds), endpoint)
	if u_err != .None do return u_err
	shm_endpoint := fmt.tprintf("%s.shm", endpoint)
	s_err := shm_client_connect_endpoint(rawptr(&a.shm), shm_endpoint)
	if s_err != .None {
		uds_client_close_endpoint(rawptr(&a.uds))
		return s_err
	}
	return .None
}

hybrid_client_send_frame :: proc(user_data: rawptr, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^Hybrid_Client_Adapter)(user_data)
	if a == nil do return 0, .Disconnected
	return uds_client_send_frame(rawptr(&a.uds), frame)
}

hybrid_client_recv_frame :: proc(user_data: rawptr) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^Hybrid_Client_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return uds_client_recv_frame(rawptr(&a.uds))
}

hybrid_client_read_snapshot :: proc(user_data: rawptr, out_buf: []u8) -> (n: int, seq: u64, ok: bool) {
	a := (^Hybrid_Client_Adapter)(user_data)
	if a == nil do return 0, 0, false

	// Receive 40-byte notification frame from UDS
	frame, _, status := uds_client_recv_frame(rawptr(&a.uds))
	if status != .Ok do return 0, 0, false
	if frame.header.kind != .Snapshot_Section && frame.header.kind != .Snapshot_Begin && frame.header.kind != .Snapshot_End {
		return 0, 0, false
	}

	// Read snapshot directly from SHM memory
	shm_n, _, shm_ok := shm_client_read_snapshot_memory(&a.shm, out_buf)
	if !shm_ok do return 0, 0, false

	return shm_n, frame.header.sequence, true
}

hybrid_client_close_endpoint :: proc(user_data: rawptr) {
	a := (^Hybrid_Client_Adapter)(user_data)
	if a == nil do return
	uds_client_close_endpoint(rawptr(&a.uds))
	shm_client_close_endpoint(rawptr(&a.shm))
}

package session_ipc

UDS_Host_Adapter :: struct {
	server: Socket_Server,
}

uds_host_make_port :: proc(a: ^UDS_Host_Adapter) -> Host_Transport_Port {
	if a != nil && a.server.listen_fd == 0 && a.server.lock_fd == 0 && len(a.server.socket_path) == 0 {
		a.server.listen_fd = -1
		a.server.lock_fd = -1
	}
	return Host_Transport_Port{
		user_data         = rawptr(a),
		kind              = .UDS,
		listen_endpoint   = uds_host_listen_endpoint,
		accept_client     = uds_host_accept_client,
		send_frame        = uds_host_send_frame,
		recv_frame        = uds_host_recv_frame,
		publish_snapshot  = uds_host_publish_snapshot,
		disconnect_client = uds_host_disconnect_client,
		close_endpoint    = uds_host_close_endpoint,
	}
}

uds_host_listen_endpoint :: proc(user_data: rawptr, endpoint: string) -> bool {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return false
	err := server_init(&a.server, endpoint)
	return err == .None
}

uds_host_accept_client :: proc(user_data: rawptr) -> (client_id: int, ok: bool) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return -1, false
	slot, err := server_accept(&a.server)
	if err != .None || slot < 0 do return -1, false
	return slot, true
}

uds_host_send_frame :: proc(user_data: rawptr, client_id: int, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return 0, .Socket_Failed
	return server_send_frame(&a.server, client_id, frame)
}

uds_host_recv_frame :: proc(user_data: rawptr, client_id: int) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return server_recv_frame(&a.server, client_id)
}

uds_host_publish_snapshot :: proc(
	user_data: rawptr,
	client_id: int,
	stream_id: u64,
	seq: u64,
	payload: []u8,
) -> (written: int, err: Transport_Error) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return 0, .Socket_Failed
	frame := Frame{
		header = {
			major     = PROTOCOL_MAJOR,
			minor     = PROTOCOL_MINOR,
			kind      = .Snapshot_Section,
			stream_id = stream_id,
			sequence  = seq,
		},
		payload = payload,
	}
	return server_send_frame(&a.server, client_id, frame)
}

uds_host_disconnect_client :: proc(user_data: rawptr, client_id: int) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return
	server_disconnect_client(&a.server, client_id)
}

uds_host_close_endpoint :: proc(user_data: rawptr) {
	a := (^UDS_Host_Adapter)(user_data)
	if a == nil do return
	server_close(&a.server)
}

UDS_Client_Adapter :: struct {
	client: Socket_Client,
}

uds_client_make_port :: proc(a: ^UDS_Client_Adapter) -> Client_Transport_Port {
	if a != nil && a.client.fd == 0 && a.client.read_buf == nil {
		a.client.fd = -1
	}
	return Client_Transport_Port{
		user_data        = rawptr(a),
		kind             = .UDS,
		connect_endpoint = uds_client_connect_endpoint,
		send_frame       = uds_client_send_frame,
		recv_frame       = uds_client_recv_frame,
		read_snapshot    = uds_client_read_snapshot,
		close_endpoint   = uds_client_close_endpoint,
	}
}

uds_client_connect_endpoint :: proc(user_data: rawptr, endpoint: string) -> Transport_Error {
	a := (^UDS_Client_Adapter)(user_data)
	if a == nil do return .Connect_Failed
	return client_connect(&a.client, endpoint)
}

uds_client_send_frame :: proc(user_data: rawptr, frame: Frame) -> (written: int, err: Transport_Error) {
	a := (^UDS_Client_Adapter)(user_data)
	if a == nil do return 0, .Disconnected
	return client_send_frame(&a.client, frame)
}

uds_client_recv_frame :: proc(user_data: rawptr) -> (frame: Frame, consumed: int, status: Codec_Status) {
	a := (^UDS_Client_Adapter)(user_data)
	if a == nil do return {}, 0, .Incomplete
	return client_recv_frame(&a.client)
}

uds_client_read_snapshot :: proc(user_data: rawptr, out_buf: []u8) -> (n: int, seq: u64, ok: bool) {
	a := (^UDS_Client_Adapter)(user_data)
	if a == nil do return 0, 0, false
	frame, _, status := client_recv_frame(&a.client)
	if status != .Ok do return 0, 0, false
	if frame.header.kind != .Snapshot_Section && frame.header.kind != .Snapshot_Begin && frame.header.kind != .Snapshot_End {
		return 0, 0, false
	}
	if len(out_buf) < len(frame.payload) do return 0, 0, false
	copy(out_buf, frame.payload)
	return len(frame.payload), frame.header.sequence, true
}

uds_client_close_endpoint :: proc(user_data: rawptr) {
	a := (^UDS_Client_Adapter)(user_data)
	if a == nil do return
	client_close(&a.client)
}

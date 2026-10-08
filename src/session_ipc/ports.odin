package session_ipc

Transport_Kind :: enum u8 {
	UDS    = 1,
	SHM    = 2,
	Hybrid = 3,
}

Host_Transport_Port :: struct {
	user_data:         rawptr,
	kind:              Transport_Kind,
	listen_endpoint:   proc(user_data: rawptr, endpoint: string) -> bool,
	accept_client:     proc(user_data: rawptr) -> (client_id: int, ok: bool),
	send_frame:        proc(user_data: rawptr, client_id: int, frame: Frame) -> (written: int, err: Transport_Error),
	recv_frame:        proc(user_data: rawptr, client_id: int) -> (frame: Frame, consumed: int, status: Codec_Status),
	publish_snapshot:  proc(user_data: rawptr, client_id: int, stream_id: u64, seq: u64, payload: []u8) -> (written: int, err: Transport_Error),
	disconnect_client: proc(user_data: rawptr, client_id: int),
	close_endpoint:    proc(user_data: rawptr),
}

Client_Transport_Port :: struct {
	user_data:        rawptr,
	kind:             Transport_Kind,
	connect_endpoint: proc(user_data: rawptr, endpoint: string) -> Transport_Error,
	send_frame:       proc(user_data: rawptr, frame: Frame) -> (written: int, err: Transport_Error),
	recv_frame:       proc(user_data: rawptr) -> (frame: Frame, consumed: int, status: Codec_Status),
	read_snapshot:    proc(user_data: rawptr, out_buf: []u8) -> (n: int, seq: u64, ok: bool),
	close_endpoint:   proc(user_data: rawptr),
}

package feature_session_proto

// Bodies of the channel 0 requests that have no struct of their own
// elsewhere (msg.odin, msg_auto.odin, msg_broker.odin). The core reads each
// with ipc.request_decode and the matching dec_* of codec_req.odin.

Empty_Request :: struct {} // LIST

// Create_Request: raw is the Spawn_Msg as sent, forwarded to the holder.
Create_Request :: struct {
	spec: Spawn_Msg,
	raw:  []u8,
}

Observe_Request :: struct {
	id, lines: u32,
}

Read_Request :: struct {
	id, history: u32, // history: scrollback lines (a full-screen program's are stitched)
}

Send_Request :: struct {
	id:    u32,
	bytes: []u8, // the rest of the body: raw bytes for the program
}

Signal_Request :: struct {
	id:     u32,
	signal: i32,
}

Size_Request :: struct {
	id:   u32,
	size: Size_Msg,
}

Next_Request :: struct {
	sid:        u32, // the worker's session
	timeout_ms: u32, // 0 = until a request comes
}

Endpoint_Request :: struct {
	name:  string,
	owned: bool, // it ends with the connection that made it
}

Lease_Request :: struct {
	id:    u32,
	owner: string,
}

// Lease_Flag_Request: LEASE_RELEASE (on = flush the held input) and
// LEASE_MODE (on = pass a person's input through).
Lease_Flag_Request :: struct {
	id: u32,
	on: bool,
}

Act_Request :: struct {
	id:     u32,
	kind:   Act_Kind,
	n_keys: int,
	keys:   [ACT_KEYS_MAX]Act_Key,
	paste:  bool,
	text:   string,
	mouse:  Act_Mouse,
}

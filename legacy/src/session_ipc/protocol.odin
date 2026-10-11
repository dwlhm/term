package session_ipc

import "core:encoding/endian"

// Frame compatibility is independent of terminal snapshot compatibility. A new
// major requires a new handshake; minor versions may add negotiated messages.
// Unknown kinds and nonzero reserved flags are rejected, never ignored. Numeric
// kinds are permanent wire IDs and must not be reordered or reused.
FRAME_MAGIC :: "TERM"
PROTOCOL_MAJOR :: u16(1)
PROTOCOL_MINOR :: u16(0)
FRAME_HEADER_BYTES :: 40
MAX_FRAME_BYTES :: 1024 * 1024
MAX_PAYLOAD_BYTES :: MAX_FRAME_BYTES - FRAME_HEADER_BYTES
SUPPORTED_FLAGS :: u16(0)

Message_Kind :: enum u16 {
	Hello = 1,
	List_Metadata = 2,
	Create = 3,
	Attach_Reserve = 4,
	Attach_Commit = 5,
	Detach = 6,
	Input = 7,
	Resize = 8,
	Topology_Command = 9,
	Close_Prepare = 10,
	Close_Commit = 11,
	Ack = 12,
	Error = 13,
	Snapshot_Begin = 14,
	Snapshot_Section = 15,
	Snapshot_End = 16,
	Resync = 17,
	Clipboard_Request = 18,
	Clipboard_Reply = 19,
	Metadata = 20,
	Credit = 21,
}

Codec_Status :: enum {
	Ok,
	Incomplete,
	Malformed,
	Unsupported_Version,
	Unsupported_Kind,
	Unsupported_Flags,
	Limit_Exceeded,
	Destination_Too_Small,
}

Frame_Header :: struct {
	major: u16,
	minor: u16,
	kind: Message_Kind,
	flags: u16,
	request_id: u64,
	stream_id: u64,
	sequence: u64,
}

Frame :: struct {
	header: Frame_Header,
	// Borrowed from the decode input; caller retains that backing until consumed.
	payload: []u8,
}

frame_header_status :: proc(header: Frame_Header) -> Codec_Status {
	if header.major != PROTOCOL_MAJOR do return .Unsupported_Version
	if u16(header.kind) < u16(Message_Kind.Hello) || u16(header.kind) > u16(Message_Kind.Credit) do return .Unsupported_Kind
	if header.flags & ~SUPPORTED_FLAGS != 0 do return .Unsupported_Flags
	return .Ok
}

// No allocation or state mutation. Failure consumes zero bytes. Same-major
// newer minor frames are allowed only when kind and flags are already known.
decode_frame :: proc(data: []u8) -> (frame: Frame, consumed: int, status: Codec_Status) {
	if len(data) < FRAME_HEADER_BYTES do return {}, 0, .Incomplete
	if string(data[:4]) != FRAME_MAGIC do return {}, 0, .Malformed
	header := Frame_Header{
		major = endian.unchecked_get_u16le(data[4:6]),
		minor = endian.unchecked_get_u16le(data[6:8]),
		kind = Message_Kind(endian.unchecked_get_u16le(data[8:10])),
		flags = endian.unchecked_get_u16le(data[10:12]),
		request_id = endian.unchecked_get_u64le(data[16:24]),
		stream_id = endian.unchecked_get_u64le(data[24:32]),
		sequence = endian.unchecked_get_u64le(data[32:40]),
	}
	if validation := frame_header_status(header); validation != .Ok do return {}, 0, validation
	payload_bytes := endian.unchecked_get_u32le(data[12:16])
	// Check the wire-sized unsigned count before conversion/addition, including
	// on 32-bit targets. Never allocate based on an unvalidated peer length.
	if payload_bytes > u32(MAX_PAYLOAD_BYTES) do return {}, 0, .Limit_Exceeded
	frame_bytes := FRAME_HEADER_BYTES + int(payload_bytes)
	if len(data) < frame_bytes do return {}, 0, .Incomplete
	return Frame{header, data[FRAME_HEADER_BYTES:frame_bytes]}, frame_bytes, .Ok
}

// Validation completes before the first write. Payload is copied before the
// header so callers can also encode payload already staged in the destination.
encode_frame :: proc(dst: []u8, frame: Frame) -> (written: int, status: Codec_Status) {
	if validation := frame_header_status(frame.header); validation != .Ok do return 0, validation
	if len(frame.payload) > MAX_PAYLOAD_BYTES do return 0, .Limit_Exceeded
	frame_bytes := FRAME_HEADER_BYTES + len(frame.payload)
	if len(dst) < frame_bytes do return 0, .Destination_Too_Small
	copy(dst[FRAME_HEADER_BYTES:frame_bytes], frame.payload)
	copy(dst[:4], FRAME_MAGIC)
	endian.unchecked_put_u16le(dst[4:6], frame.header.major)
	endian.unchecked_put_u16le(dst[6:8], frame.header.minor)
	endian.unchecked_put_u16le(dst[8:10], u16(frame.header.kind))
	endian.unchecked_put_u16le(dst[10:12], frame.header.flags)
	endian.unchecked_put_u32le(dst[12:16], u32(len(frame.payload)))
	endian.unchecked_put_u64le(dst[16:24], frame.header.request_id)
	endian.unchecked_put_u64le(dst[24:32], frame.header.stream_id)
	endian.unchecked_put_u64le(dst[32:40], frame.header.sequence)
	return frame_bytes, .Ok
}

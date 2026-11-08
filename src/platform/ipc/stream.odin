package platform_ipc

// Framed duplex stream: the one wire shared by holder ↔ core and core ↔ viewer.
//
// Frame: [kind u8][channel u32 LE][len u32 LE][payload]. The length is checked
// against STREAM_MAX_PAYLOAD before any byte of the payload is buffered.
// Holder link: channel = session id. Viewer link: channel 0 = control, every
// attach gets its own channel whose DATA is limited by credit (CREDIT frames
// from the receiver). Control frames always go out before stream data; a
// stream that stops being read never blocks control or other streams.
//
// Invariants:
// 1. Fixed memory: every buffer is allocated by stream_conn_init or
//    stream_channel_open and freed by stream_conn_destroy / channel close.
//    Sending and receiving never allocate.
// 2. Never blocks: the fd is O_NONBLOCK; stream_fill / stream_flush stop at
//    EAGAIN and the caller polls (stream_wants_write → POLLOUT).
// 3. Untrusted input: a header with len > STREAM_MAX_PAYLOAD or an unknown
//    channel's CREDIT is a protocol error (.Bad_Frame), never an allocation.

STREAM_HEADER        :: 9
STREAM_MAX_PAYLOAD   :: 1 << 20
STREAM_DATA_CHUNK    :: 64 * 1024
STREAM_WINDOW        :: 256 * 1024 // credit a stream starts with
STREAM_MAX_PENDING   :: 4 << 20    // queued for a slow viewer before it gets a repaint instead
STREAM_MAX_CHANNELS  :: 64
STREAM_PROTO_VERSION :: 2

// Kinds shared by every link. Link-specific messages live in stream_msg.odin.
STREAM_DATA   :: u8(0) // stream payload bytes
STREAM_CREDIT :: u8(1) // u32 LE: the receiver consumed this many bytes
STREAM_CLOSE  :: u8(2) // the channel is over (payload: reason text, may be empty)

Stream_Error :: enum u8 {
	None,
	Closed,       // peer closed (EOF) or we closed
	Bad_Frame,    // oversize length or malformed frame
	Overflow,     // control queue full: the peer stopped reading
	Socket_Failed,
}

Stream_Frame :: struct {
	kind:    u8,
	channel: u32,
	payload: []u8, // view into the conn's input buffer, valid until the next stream_next/stream_fill
}

// Byte_Ring is a fixed-capacity FIFO of bytes; pushes are all-or-nothing.
Byte_Ring :: struct {
	buf:  []u8,
	head: int, // read position
	len:  int,
}

ring_push :: proc(r: ^Byte_Ring, parts: ..[]u8) -> bool {
	total := 0
	for p in parts do total += len(p)
	if total > len(r.buf) - r.len do return false
	for p in parts {
		tail := (r.head + r.len) % len(r.buf)
		first := min(len(p), len(r.buf) - tail)
		copy(r.buf[tail:tail + first], p[:first])
		copy(r.buf[:len(p) - first], p[first:])
		r.len += len(p)
	}
	return true
}

// ring_front is the contiguous readable run starting at head.
ring_front :: proc(r: ^Byte_Ring) -> []u8 {
	if r.len == 0 do return nil
	return r.buf[r.head:r.head + min(r.len, len(r.buf) - r.head)]
}

ring_consume :: proc(r: ^Byte_Ring, n: int) {
	k := min(n, r.len)
	r.len -= k
	r.head = 0 if r.len == 0 else (r.head + k) % len(r.buf)
}

ring_clear :: proc(r: ^Byte_Ring) { r.head, r.len = 0, 0 }

// ring_pop copies up to len(out) bytes out of the ring.
ring_pop :: proc(r: ^Byte_Ring, out: []u8) -> int {
	n := 0
	for n < len(out) && r.len > 0 {
		run := ring_front(r)
		k := copy(out[n:], run)
		ring_consume(r, k)
		n += k
	}
	return n
}

stream_put_header :: proc(dst: []u8, kind: u8, channel: u32, length: int) {
	dst[0] = kind
	_put_u32(dst[1:], channel)
	_put_u32(dst[5:], u32(length))
}

stream_parse_header :: proc(src: []u8, max_payload := STREAM_MAX_PAYLOAD) -> (kind: u8, channel: u32, length: int, ok: bool) {
	if len(src) < STREAM_HEADER do return
	length = int(_get_u32(src[5:]))
	if length > max_payload do return
	return src[0], _get_u32(src[1:]), length, true
}

@(private)
_put_u32 :: proc(dst: []u8, v: u32) {
	dst[0], dst[1], dst[2], dst[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(private)
_get_u32 :: proc(src: []u8) -> u32 {
	return u32(src[0]) | u32(src[1]) << 8 | u32(src[2]) << 16 | u32(src[3]) << 24
}

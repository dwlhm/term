package platform_ipc

// Receiving side of a Stream_Conn: non-blocking fill + frame iteration.
// CREDIT frames are applied here and never reach the caller.

import "core:c"
import "core:sys/posix"

// stream_fill reads what the socket has. .Closed on EOF; the frames already
// buffered can still be taken with stream_next.
stream_fill :: proc(s: ^Stream_Conn) -> Stream_Error {
	_compact(s)
	for s.err == .None && s.in_len < len(s.in_buf) {
		dst := s.in_buf[s.in_len:]
		n := posix.recv(s.fd, raw_data(dst), c.size_t(len(dst)), {})
		if n > 0 {
			s.in_len += int(n)
			continue
		}
		e := posix.errno()
		if n < 0 && e == .EINTR do continue
		if n < 0 && e == .EAGAIN do break
		s.err = .Closed if n == 0 || e == .ECONNRESET else .Socket_Failed
	}
	return s.err
}

// stream_next returns the next complete frame, if any. The payload view stays
// valid until the next stream_next or stream_fill call.
stream_next :: proc(s: ^Stream_Conn) -> (frame: Stream_Frame, ok: bool) {
	for {
		avail := s.in_buf[s.in_used:s.in_len]
		if len(avail) < STREAM_HEADER do return
		kind, channel, length, valid := stream_parse_header(avail)
		if !valid {
			s.err = .Bad_Frame
			return
		}
		if len(avail) < STREAM_HEADER + length do return
		payload := avail[STREAM_HEADER:STREAM_HEADER + length]
		s.in_used += STREAM_HEADER + length
		if kind != STREAM_CREDIT do return {kind, channel, payload}, true
		if !_apply_credit(s, channel, payload) {
			s.err = .Bad_Frame
			return
		}
	}
}

// stream_ack tells the peer this many DATA bytes of channel were consumed.
stream_ack :: proc(s: ^Stream_Conn, channel: u32, n: int) -> bool {
	b: [4]u8
	_put_u32(b[:], u32(n))
	return stream_send(s, STREAM_CREDIT, channel, b[:])
}

@(private = "file")
_apply_credit :: proc(s: ^Stream_Conn, channel: u32, payload: []u8) -> bool {
	if len(payload) != 4 do return false
	ch := stream_channel(s, channel)
	if ch == nil do return true // a channel we closed meanwhile: harmless
	ch.credit = min(ch.credit + int(_get_u32(payload)), STREAM_MAX_PENDING + STREAM_WINDOW)
	return true
}

@(private = "file")
_compact :: proc(s: ^Stream_Conn) {
	if s.in_used == 0 do return
	rest := s.in_len - s.in_used
	copy(s.in_buf[:rest], s.in_buf[s.in_used:s.in_len])
	s.in_len, s.in_used = rest, 0
}

package platform_ipc

// One framed connection: input reassembly, a control queue of whole frames,
// and credit-limited data channels. Contract: see stream.odin.

import "base:runtime"
import "core:c"
import "core:sys/posix"

Stream_Channel :: struct {
	id:            u32,
	used:          bool,
	credited:      bool, // DATA limited by credit (viewer streams); false = control-queue speed
	credit:        int,
	pending:       Byte_Ring,
	ending:        bool, // CLOSE once pending is out
	needs_repaint: bool, // pending overflowed and was dropped; the owner sends a repaint
}

Stream_Conn :: struct {
	open:      bool,     // init took fd; the zero value is closed and owns no fd
	fd:        posix.FD, // meaningful only while open
	in_buf:    []u8, // STREAM_HEADER + the largest payload it takes in (STREAM_MAX_PAYLOAD by default)
	in_len:    int,
	in_used:   int, // bytes of in_buf consumed by the last stream_next
	ctl:       Byte_Ring,
	out:       [STREAM_HEADER + STREAM_DATA_CHUNK]u8, // one DATA frame being written
	out_len:   int,
	out_off:   int,
	chans:     [STREAM_MAX_CHANNELS]Stream_Channel,
	turn:      int,
	err:       Stream_Error,
	allocator: runtime.Allocator,
}

// stream_conn_init takes ownership of fd (made O_NONBLOCK|FD_CLOEXEC), also
// when it fails: fd is closed then and s stays zero.
// ctl_cap bounds queued control frames (the holder link uses it as its backlog).
stream_conn_init :: proc(s: ^Stream_Conn, fd: posix.FD, ctl_cap: int, allocator := context.allocator) -> bool {
	s^ = {}
	stream_conn_reserve(s, ctl_cap, allocator)
	if stream_conn_attach(s, fd) do return true
	_conn_free(s)
	return false
}

// stream_conn_reserve allocates the buffers of a conn that has no fd yet, so
// an owner that swaps peers (a Link) attaches and detaches without ever
// allocating again. max_payload bounds incoming frames. s must be zero.
stream_conn_reserve :: proc(s: ^Stream_Conn, ctl_cap: int, allocator := context.allocator, max_payload := STREAM_MAX_PAYLOAD) {
	s.allocator = allocator
	s.in_buf = make([]u8, STREAM_HEADER + max_payload, allocator)
	s.ctl.buf = make([]u8, max(ctl_cap, STREAM_HEADER + STREAM_MAX_PAYLOAD), allocator)
}

// stream_conn_attach gives a reserved, detached conn its fd (made
// O_NONBLOCK|FD_CLOEXEC) and the bytes already read from it, if any; on
// failure fd is closed and s stays detached.
stream_conn_attach :: proc(s: ^Stream_Conn, fd: posix.FD, read_ahead: []u8 = nil) -> bool {
	if s.open || len(read_ahead) > len(s.in_buf) || !_set_nonblocking_cloexec(fd) {
		posix.close(fd)
		return false
	}
	s.open, s.fd = true, fd
	s.in_len = copy(s.in_buf, read_ahead)
	return true
}

// stream_conn_detach closes the fd and forgets everything queued or half
// read, keeping the buffers for the next stream_conn_attach.
stream_conn_detach :: proc(s: ^Stream_Conn) {
	if s.open do posix.close(s.fd)
	for &ch in s.chans do if ch.used do delete(ch.pending.buf, s.allocator)
	s.chans = {}
	s.open, s.fd, s.in_len, s.in_used, s.out_len, s.out_off, s.turn, s.err = false, 0, 0, 0, 0, 0, 0, .None
	ring_clear(&s.ctl)
}

// stream_conn_destroy closes the fd only when s owns one; safe on a zero
// value and when called again.
stream_conn_destroy :: proc(s: ^Stream_Conn) {
	if s.open do posix.close(s.fd)
	_conn_free(s)
}

// stream_conn_release frees the buffers and hands the open fd back without
// closing it (-1 when s owns none); s is zero afterwards.
stream_conn_release :: proc(s: ^Stream_Conn) -> posix.FD {
	fd := s.fd if s.open else -1
	_conn_free(s)
	return fd
}

@(private = "file")
_conn_free :: proc(s: ^Stream_Conn) {
	for &ch in s.chans do if ch.used do delete(ch.pending.buf, s.allocator)
	delete(s.in_buf, s.allocator)
	delete(s.ctl.buf, s.allocator)
	s^ = {}
}

// stream_send queues one whole control frame. false = control queue full
// (.Overflow is recorded: the caller drops the peer or applies backpressure).
stream_send :: proc(s: ^Stream_Conn, kind: u8, channel: u32, parts: ..[]u8) -> bool {
	total := 0
	for p in parts do total += len(p)
	if total > STREAM_MAX_PAYLOAD do return false
	hdr: [STREAM_HEADER]u8
	stream_put_header(hdr[:], kind, channel, total)
	if len(s.ctl.buf) - s.ctl.len < STREAM_HEADER + total {
		s.err = .Overflow
		return false
	}
	ring_push(&s.ctl, hdr[:])
	for p in parts do ring_push(&s.ctl, p)
	return true
}

stream_queued :: proc(s: ^Stream_Conn) -> int {
	n := s.ctl.len + (s.out_len - s.out_off)
	for &ch in s.chans do if ch.used do n += ch.pending.len
	return n
}

stream_channel :: proc(s: ^Stream_Conn, id: u32) -> ^Stream_Channel {
	for &ch in s.chans do if ch.used && ch.id == id do return &ch
	return nil
}

// stream_channel_open allocates the channel's pending queue (STREAM_MAX_PENDING).
stream_channel_open :: proc(s: ^Stream_Conn, id: u32, credited: bool) -> bool {
	if stream_channel(s, id) != nil do return false
	for &ch in s.chans {
		if ch.used do continue
		ch = {id = id, used = true, credited = credited, credit = STREAM_WINDOW}
		ch.pending.buf = make([]u8, STREAM_MAX_PENDING, s.allocator)
		return true
	}
	return false
}

// stream_channel_close drops what is queued and tells the peer now.
stream_channel_close :: proc(s: ^Stream_Conn, id: u32, reason: string = "") {
	if ch := stream_channel(s, id); ch != nil {
		delete(ch.pending.buf, s.allocator)
		ch^ = {}
	}
	stream_send(s, STREAM_CLOSE, id, transmute([]u8)reason)
}

// stream_channel_finish closes once queued data is out (a program's last output).
stream_channel_finish :: proc(s: ^Stream_Conn, id: u32) {
	if ch := stream_channel(s, id); ch != nil do ch.ending = true
	else do stream_send(s, STREAM_CLOSE, id)
}

// stream_data queues DATA. false = the reader is too far behind: its backlog
// is dropped and needs_repaint is set; the owner replaces it with a repaint.
stream_data :: proc(s: ^Stream_Conn, id: u32, bytes: []u8) -> bool {
	ch := stream_channel(s, id)
	if ch == nil do return true
	if !ring_push(&ch.pending, bytes) {
		ring_clear(&ch.pending)
		ch.needs_repaint = true
		return false
	}
	return true
}

stream_wants_write :: proc(s: ^Stream_Conn) -> bool {
	if s.out_off < s.out_len || s.ctl.len > 0 do return true
	for &ch in s.chans {
		if ch.used && ch.pending.len > 0 && (!ch.credited || ch.credit > 0) do return true
		if ch.used && ch.ending do return true
	}
	return false
}

// stream_flush writes until the socket would block or nothing is left.
stream_flush :: proc(s: ^Stream_Conn) -> Stream_Error {
	for s.err == .None {
		if s.out_off < s.out_len {
			if !_write_some(s, s.out[s.out_off:s.out_len], &s.out_off) do break
			continue
		}
		if s.ctl.len > 0 {
			n := 0
			if !_write_some(s, ring_front(&s.ctl), &n) do break
			ring_consume(&s.ctl, n)
			continue
		}
		if !_next_data_frame(s) do break
	}
	return s.err if s.err != .Overflow else .None
}

@(private = "file")
_write_some :: proc(s: ^Stream_Conn, data: []u8, advanced: ^int) -> bool {
	for {
		n := posix.send(s.fd, raw_data(data), c.size_t(len(data)), {.NOSIGNAL})
		if n > 0 {
			advanced^ += int(n)
			return true
		}
		e := posix.errno()
		if n < 0 && e == .EINTR do continue
		if n < 0 && e == .EAGAIN do return false
		s.err = .Closed if e == .EPIPE || e == .ECONNRESET else .Socket_Failed
		return false
	}
}

// _next_data_frame builds the next DATA (or deferred CLOSE) frame into s.out,
// round-robin over channels, each within its own credit.
@(private = "file")
_next_data_frame :: proc(s: ^Stream_Conn) -> bool {
	for step in 0..<STREAM_MAX_CHANNELS {
		i := (s.turn + 1 + step) % STREAM_MAX_CHANNELS
		ch := &s.chans[i]
		if !ch.used do continue
		if ch.pending.len == 0 && ch.ending {
			id := ch.id
			delete(ch.pending.buf, s.allocator)
			ch^ = {}
			stream_send(s, STREAM_CLOSE, id)
			s.turn = i
			return true
		}
		budget := ch.credit if ch.credited else STREAM_DATA_CHUNK
		n := min(ch.pending.len, budget, STREAM_DATA_CHUNK)
		if n <= 0 do continue
		stream_put_header(s.out[:], STREAM_DATA, ch.id, n)
		ring_pop(&ch.pending, s.out[STREAM_HEADER:STREAM_HEADER + n])
		if ch.credited do ch.credit -= n
		s.out_len, s.out_off, s.turn = STREAM_HEADER + n, 0, i
		return true
	}
	return false
}

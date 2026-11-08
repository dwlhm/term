package platform_ipc

// Calls on a Client. Every channel 0 frame names its req, so an answer goes
// to the request that asked: the call's own (kind from the catalog, FAIL as
// Error{.Failed}, anything else as .Bad_Reply), a client_start ticket
// (Late_Answer / Progress), or req 0 for a notice. Frames on other channels
// are stream data. Event and answer bodies are views valid until the next
// client_* call.

import "core:sync"
import "core:sys/posix"
import "core:time"

@(private)
_client_send :: proc(k: ^_Client, kind: u8, body: []u8) -> (req: u32, err: Error) {
	if k.conn.err != .None do return 0, {kind = .Closed, reason = "the connection is closed"}
	k.next_req = max(k.next_req + 1, 1)
	rb: [4]u8
	_put_u32(rb[:], k.next_req)
	if !stream_send(&k.conn, kind, 0, rb[:], body) {
		k.conn.err = .None // a full queue is backpressure here, not a dead link
		return 0, {kind = .Busy, reason = "the send queue is full"}
	}
	stream_flush(&k.conn)
	return k.next_req, {}
}

// _Outcome of one frame for a waiting call.
@(private)
_Outcome :: struct {
	ev:     Client_Event, // something for on_event / client_poll
	mine:   bool,         // the call's own final answer: answer or err
	answer: Answer,
	err:    Error,
}

@(private)
_classify :: proc(k: ^_Client, f: Stream_Frame, own: u32, own_kind: u8) -> (o: _Outcome) {
	if f.channel != 0 {
		if f.kind == STREAM_DATA do o.ev = Stream_Data{f.channel, f.payload}
		if f.kind == STREAM_CLOSE do o.ev = Stream_End{f.channel, string(f.payload)}
		return
	}
	if len(f.payload) < 4 do return
	r := wire_reader(f.payload)
	req := wr_u32(&r)
	if req == 0 {
		if _is_notice(k.proto, f.kind) do o.ev = Notice{f.kind, f.payload[4:]}
		return
	}
	if req == own {
		final, answer, err, prog := _answer_of(k, f, own_kind)
		if final do return {mine = true, answer = answer, err = err}
		if prog do o.ev = Progress{Ticket(req), f.kind, f.payload[4:]}
		return
	}
	for &t in k.tickets {
		if !t.used || t.req != req do continue
		final, answer, err, prog := _answer_of(k, f, t.kind)
		if final {
			t = {}
			o.ev = Late_Answer{Ticket(req), answer, err}
		} else if prog {
			o.ev = Progress{Ticket(req), f.kind, f.payload[4:]}
		}
		return
	}
	return
}

// _answer_of reads a frame for a request of kind request.
@(private = "file")
_answer_of :: proc(k: ^_Client, f: Stream_Frame, request: u8) -> (final: bool, answer: Answer, err: Error, prog: bool) {
	row, _ := _row(k.proto, request)
	switch {
	case f.kind == row.answer:
		return true, {f.kind, f.payload[4:]}, {}, false
	case f.kind == k.proto.fail_kind:
		_, code, reason := _fail_decode(f.payload)
		return true, {}, {kind = .Failed, code = code, reason = reason}, false
	case row.progress != 0 && f.kind == row.progress:
		return false, {}, {}, true
	}
	return true, {}, {kind = .Bad_Reply, reason = "the answer's kind is not in the catalog for this request"}, false
}

@(private)
_call_due :: proc(timeout: time.Duration) -> i64 {
	if timeout == WAIT_FOREVER do return -1
	return time.tick_now()._nsec + i64(timeout if timeout > 0 else CALL_DEFAULT)
}

// _client_await waits for req's final answer, handing other events to opts.on_event.
@(private)
_client_await :: proc(k: ^_Client, req: u32, kind: u8, opts: Call_Opts) -> (Answer, Error) {
	due := _call_due(opts.timeout)
	for {
		for f in stream_next(&k.conn) {
			o := _classify(k, f, req, kind)
			if o.mine do return o.answer, o.err
			if o.ev != nil && opts.on_event != nil && opts.on_event(opts.data, o.ev) == .Stop {
				return {}, {kind = .Interrupted, reason = "stopped by on_event"}
			}
		}
		if k.conn.err != .None do return {}, {kind = .Closed, reason = "the connection closed"}
		if sync.atomic_exchange(&k.interrupted, false) do return {}, {kind = .Interrupted, reason = "interrupted"}
		switch _client_wait(k, due, opts.watch) {
		case .Timeout:      return {}, {kind = .Timeout, reason = "no answer in time"}
		case .Watch:        if opts.on_watch != nil do opts.on_watch(opts.data)
		case .Ready, .Woken:
		}
	}
}

// _client_next_event: the next event for client_poll.
@(private)
_client_next_event :: proc(k: ^_Client, timeout: time.Duration, watch: posix.FD, on_watch: proc(data: rawptr), data: rawptr) -> (Client_Event, Error) {
	due := _call_due(timeout)
	for {
		for f in stream_next(&k.conn) {
			if o := _classify(k, f, 0, 0); o.ev != nil do return o.ev, {}
		}
		if k.conn.err != .None do return nil, {kind = .Closed, reason = "the connection closed"}
		if sync.atomic_exchange(&k.interrupted, false) do return nil, {kind = .Interrupted, reason = "interrupted"}
		switch _client_wait(k, due, watch) {
		case .Timeout:      return nil, {kind = .Timeout, reason = "nothing in time"}
		case .Watch:
			if on_watch != nil do on_watch(data)
			return nil, {}
		case .Ready, .Woken:
		}
	}
}

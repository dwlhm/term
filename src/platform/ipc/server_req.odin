package platform_ipc

// Requests on a Server: every channel 0 frame starts with u32 req. The
// package answers by itself what the owner must never see: req 0 or a req
// already open → FAIL_BAD_REQUEST, an unknown kind → FAIL_BAD_REQUEST, the
// (max_open+1)th open request → FAIL_BUSY. Each request gets exactly one
// final answer; a second one is ignored (and asserts in test builds), and
// one for a peer that left does nothing.

@(private)
_ASSERT_SECOND_REPLY :: "ipc: request already answered"
@(private)
_ASSERT_RESERVED_FAIL :: "ipc: FAIL_VERSION is the handshake's"
@(private)
_ASSERT_NOT_NOTICE :: "ipc: kind is not a notice in the catalog"
@(private)
_ASSERT_NO_PROGRESS :: "ipc: request has no progress kind"

@(private)
_MAX_PARTS :: 15 // body parts per reply/notify, besides the req

@(private)
_row :: proc(p: Protocol, request: u8) -> (Msg_Spec, bool) {
	for row in p.catalog do if row.request == request && !row.notice do return row, true
	return {}, false
}

@(private)
_is_notice :: proc(p: Protocol, kind: u8) -> bool {
	for row in p.catalog do if row.notice && row.request == kind do return true
	return false
}

// _peer_frame turns one frame into what server_next yields (yield = false:
// the package answered it itself).
@(private)
_peer_frame :: proc(k: ^_Server, slot: ^_Peer_Slot, f: Stream_Frame) -> (ev: Server_Event, yield: bool) {
	peer := _peer_handle(slot)
	if f.channel != 0 do return Stream_Input{peer, f.channel, f.kind, f.payload}, true
	if len(f.payload) < 4 {
		_send_fail(slot, 0, FAIL_BAD_REQUEST, "a request starts with u32 req")
		return
	}
	r := wire_reader(f.payload)
	req := wr_u32(&r)
	free_slot := -1
	for o, i in slot.open {
		if o.used && o.req == req {
			_send_fail(slot, req, FAIL_BAD_REQUEST, "this req is already open")
			return
		}
		if !o.used && free_slot < 0 do free_slot = i
	}
	_, known := _row(k.proto, f.kind)
	switch {
	case req == 0:      _send_fail(slot, 0, FAIL_BAD_REQUEST, "req 0 is for notices")
	case !known:        _send_fail(slot, req, FAIL_BAD_REQUEST, "unknown request kind")
	case free_slot < 0: _send_fail(slot, req, FAIL_BUSY, "too many open requests")
	case:
		slot.open[free_slot] = {req, f.kind, true}
		return Request{peer = peer, kind = f.kind, _req = req, _body = f.payload[4:], _srv = k}, true
	}
	return
}

// _send_fail queues FAIL(req, code, reason) without asking whether the code is reserved.
@(private)
_send_fail :: proc(slot: ^_Peer_Slot, req: u32, code: u8, reason: string) {
	fb: [512]u8
	_send(slot, slot.srv.proto.fail_kind, req, _fail_body(fb[:], req, code, reason)[4:])
}

// _send queues one channel 0 frame: u32 req, then parts; a full queue drops the peer.
@(private)
_send :: proc(slot: ^_Peer_Slot, kind: u8, req: u32, parts: ..[]u8) {
	if len(parts) > _MAX_PARTS do return
	rb: [4]u8
	_put_u32(rb[:], req)
	all: [_MAX_PARTS + 1][]u8
	all[0] = rb[:]
	copy(all[1:], parts)
	if !stream_send(&slot.conn, kind, 0, ..all[:len(parts) + 1]) {
		_peer_drop(slot)
		return
	}
	_peer_flush(slot)
}

// _take_open closes req's open entry; false = it was not open (answered already).
@(private)
_take_open :: proc(slot: ^_Peer_Slot, req: Request) -> bool {
	for &o in slot.open {
		if o.used && o.req == req._req {
			o = {}
			return true
		}
	}
	return false
}

@(private)
_server_reply :: proc(k: ^_Server, req: Request, final: bool, kind: u8, parts: ..[]u8) {
	slot := _peer_of(k, req.peer)
	if slot == nil do return // the peer left: nobody to answer
	if final && !_take_open(slot, req) {
		when ODIN_TEST do assert(false, _ASSERT_SECOND_REPLY)
		return
	}
	_send(slot, kind, req._req, ..parts)
}

@(private)
_server_notify :: proc(k: ^_Server, to: Notify_To, kind: u8, parts: ..[]u8) {
	if !_is_notice(k.proto, kind) {
		when ODIN_TEST do assert(false, _ASSERT_NOT_NOTICE)
		return
	}
	switch p in to {
	case Peer:       if slot := _peer_of(k, p); slot != nil do _send(slot, kind, 0, ..parts)
	case Notify_All: for &slot in k.peers do if slot.state == .Joined && !slot.closing do _send(&slot, kind, 0, ..parts)
	}
}

package feature_session_client

// The two queues between the UI thread and the IO thread, both Byte_Rings
// of whole records [kind u8][link u32][len u32][body] guarded by c.mutex:
// ops (UI → IO: what to send) and events (IO → UI: what client_poll hands
// out). The IO thread alone touches c.link; the UI thread wakes it with
// ipc.client_interrupt.

import "core:sync"
import byte_ring "../../core/byte_ring"
import ipc "../../platform/ipc"

@(private)
_REC_HEADER :: 9

// A link key is its index | gen << 8: a record for a link that was freed
// (and its slot reused) finds no link.
@(private)
_NO_LINK :: max(u32)

@(private)
_Op :: enum u8 {
	Create,  // body: Spawn_Msg
	Attach,  // body: Attach_Msg
	Release, // body: u8 kill, u32 id, u32 channel (the link is already free)
	Kill,    // body: u32 id
	List,
	Stream,  // body: u8 kind + bytes on the link's channel
	Ack,     // body: u32 bytes the link's Terminal consumed
}

// _rec_push queues one record (c.mutex held); false = no room.
@(private)
_rec_push :: proc(ring: ^byte_ring.Byte_Ring, kind: u8, link: u32, parts: ..[]u8) -> bool {
	n := 0
	for p in parts do n += len(p)
	if ring.len + _REC_HEADER + n > len(ring.buf) do return false
	h: [_REC_HEADER]u8
	h[0] = kind
	_put(h[1:5], link)
	_put(h[5:9], u32(n))
	byte_ring.ring_push(ring, h[:])
	for p in parts do byte_ring.ring_push(ring, p)
	return true
}

// _rec_pop takes the next record into out (c.mutex held).
@(private)
_rec_pop :: proc(ring: ^byte_ring.Byte_Ring, out: []u8) -> (kind: u8, link: u32, body: []u8, ok: bool) {
	if ring.len < _REC_HEADER do return
	h: [_REC_HEADER]u8
	byte_ring.ring_pop(ring, h[:])
	n := int(_get(h[5:9]))
	got := byte_ring.ring_pop(ring, out[:min(n, len(out))])
	if got < n do byte_ring.ring_consume(ring, n - got) // cannot happen: out holds the largest record
	return h[0], _get(h[1:5]), out[:got], true
}

@(private = "file")
_put :: proc(b: []u8, v: u32) { b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }

@(private = "file")
_get :: proc(b: []u8) -> u32 { return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24 }

// _enqueue hands the IO thread one op and wakes it; false = the queue is full.
@(private)
_enqueue :: proc(c: ^Client, op: _Op, link: u32, parts: ..[]u8) -> bool {
	sync.mutex_lock(&c.mutex)
	ok := _rec_push(&c.ops, u8(op), link, ..parts)
	sync.mutex_unlock(&c.mutex)
	ipc.client_interrupt(&c.link)
	return ok
}

// _emit queues an event for client_poll (c.mutex held); a full queue drops
// the link to the core, which the UI then sees as Core_Lost.
@(private)
_emit :: proc(c: ^Client, kind: Client_Event_Kind, link: u32, parts: ..[]u8) {
	if !_rec_push(&c.events, u8(kind), link, ..parts) do sync.atomic_store(&c.overflow, true)
}

@(private)
_link_key :: proc(c: ^Client, l: ^Client_Link) -> u32 {
	return u32((uintptr(l) - uintptr(&c.links[0])) / size_of(Client_Link)) | l.gen << 8
}

// _link_of_key: the link a record names, nil when it is gone (c.mutex held).
@(private)
_link_of_key :: proc(c: ^Client, key: u32) -> ^Client_Link {
	if key == _NO_LINK || int(key & 0xFF) >= CLIENT_MAX_LINKS do return nil
	l := &c.links[key & 0xFF]
	return l if l.state != .Free && l.gen == key >> 8 else nil
}

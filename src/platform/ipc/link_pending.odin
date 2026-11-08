package platform_ipc

// The listening side of a Link: accepted peers wait in a fixed number of
// pending slots until their HELLO is complete. Anything that is not a HELLO
// is closed at once, a HELLO not complete by hello_ms is closed then, and a
// new peer with every slot taken closes the oldest. A good HELLO replaces
// the current peer: Link_Down for the old one, then Link_Up.

import "core:c"
import "core:sys/posix"

@(private)
_Pending :: struct {
	link: ^_Link,
	fd:   posix.FD,
	src:  u32, // 0 = slot free
	seq:  u64,
	n:    int,
	buf:  [STREAM_HEADER + _HELLO_MAX]u8,
}

@(private)
_link_accept :: proc(data: rawptr, fd: posix.FD) {
	k := (^_Link)(data)
	slot := &k.pending[0]
	for &pd in k.pending {
		if pd.src == 0 {
			slot = &pd
			break
		}
		if pd.seq < slot.seq do slot = &pd
	}
	if slot.src != 0 do _pending_drop(slot) // every slot taken: the oldest yields
	k.seq += 1
	if !_set_nonblocking_cloexec(fd) {
		posix.close(fd)
		return
	}
	id, ok := _poll_add(k.set, {fd = fd, want = {.IN}, on = _pending_ready, data = slot, due = _link_hello_due(k), on_due = _pending_late})
	if !ok {
		posix.close(fd)
		return
	}
	slot^ = {link = k, fd = fd, src = id, seq = k.seq}
}

// _link_broken: the listener is gone; one Down, then nothing more.
@(private)
_link_broken :: proc(data: rawptr) {
	k := (^_Link)(data)
	for &pd in k.pending do if pd.src != 0 do _pending_drop(&pd)
	if k.conn.open do _link_detach(k)
	_link_push(k, Link_Down{err = {kind = .Listener_Broken, reason = "the link can no longer accept"}})
	k.ended = true
}

@(private)
_pending_drop :: proc(pd: ^_Pending) {
	_poll_remove(pd.link.set, pd.src)
	posix.close(pd.fd)
	pd^ = {link = pd.link}
}

@(private = "file")
_pending_late :: proc(data: rawptr) {
	pd := (^_Pending)(data)
	if pd.src != 0 do _pending_drop(pd)
}

@(private = "file")
_pending_ready :: proc(data: rawptr, rev: posix.Poll_Event) {
	pd := (^_Pending)(data)
	for pd.n < len(pd.buf) {
		got := posix.recv(pd.fd, &pd.buf[pd.n], c.size_t(len(pd.buf) - pd.n), {})
		if got > 0 {
			pd.n += int(got)
			continue
		}
		if got < 0 && posix.errno() == .EINTR do continue
		if got < 0 && posix.errno() == .EAGAIN do break
		_pending_drop(pd) // EOF or error before a whole HELLO
		return
	}
	_pending_check(pd)
}

// _pending_check closes garbage as soon as the header shows it, and
// promotes a whole, matching HELLO.
@(private = "file")
_pending_check :: proc(pd: ^_Pending) {
	k := pd.link
	if pd.n < STREAM_HEADER do return
	kind, channel, length, valid := stream_parse_header(pd.buf[:pd.n])
	if !valid || kind != k.proto.hello_kind || channel != 0 || length > _HELLO_MAX {
		_pending_drop(pd)
		return
	}
	end := STREAM_HEADER + length
	if pd.n < end do return
	h, ok := _hello_decode(pd.buf[STREAM_HEADER:end])
	if !ok || int(h.role) >= 64 || int(h.role) not_in k.proto.roles || !_version_match(h.version, k.proto.version) {
		_pending_drop(pd)
		return
	}
	_link_promote(k, pd, end)
}

@(private = "file")
_link_promote :: proc(k: ^_Link, pd: ^_Pending, hello_end: int) {
	if k.conn.open do _link_lost(k, {kind = .Closed, reason = "a newer peer took the link"}, replaced = true)
	fd, extra := pd.fd, pd.buf[hello_end:pd.n]
	_poll_remove(k.set, pd.src)
	defer pd^ = {link = k}
	if !_link_attach(k, fd, extra, 0) do return
	k.up = true
	_link_push(k, Link_Up{})
	_link_send_hello(k, k.opts.role)
}

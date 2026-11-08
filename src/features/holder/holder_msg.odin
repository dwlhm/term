package feature_holder

// Messages from the core (catalog: features/session_proto/msg.odin). A request
// that does not decode is hostile: the link is dropped.

import "core:sys/posix"
import byte_ring "../../core/byte_ring"
import proto "../session_proto"
import ipc "../../platform/ipc"
import pty "../../platform/pty"

// _core_message returns false for a malformed or unknown request.
_core_message :: proc(h: ^Holder, f: ipc.Link_Frame, now: i64) -> bool {
	switch f.kind {
	case proto.MSG_SPAWN:      return _on_spawn(h, f)
	case proto.MSG_INPUT:      if s := _session_find(h, f.channel); s != nil do _session_input(s, f.body)
	case proto.MSG_RESIZE:     return _on_resize(h, f)
	case proto.MSG_SIGNAL:     return _on_signal(h, f)
	case proto.MSG_RELEASE:    if s := _session_find(h, f.channel); s != nil do _session_forget(h, s)
	case proto.MSG_PROC_QUERY: _on_proc_query(h, f.channel)
	case proto.MSG_DRAIN:      h.draining = true
	case proto.MSG_GOODBYE:    return _on_goodbye(h, f.body, now)
	case:                    return false
	}
	return true
}

// _on_spawn is idempotent: a known id re-answers SPAWNED.
@(private = "file")
_on_spawn :: proc(h: ^Holder, f: ipc.Link_Frame) -> bool {
	m: proto.Spawn_Msg
	r := ipc.wire_reader(f.body)
	proto.dec_spawn(&r, &m)
	if !ipc.wr_done(&r) {
		_send_text(h, proto.MSG_SPAWN_FAILED, f.channel, "bad spawn request")
		return true
	}
	s := _session_find(h, f.channel)
	reason: string
	switch {
	case s != nil:
	case f.channel == 0: reason = "session id 0 is reserved"
	case h.draining:     reason = "holder is draining"
	case:                s, reason = _session_spawn(h, f.channel, &m)
	}
	if s == nil {
		_send_text(h, proto.MSG_SPAWN_FAILED, f.channel, reason)
		return true
	}
	buf: [12]u8
	w := ipc.wire_writer(buf[:])
	ipc.ww_u32(&w, u32(s.pid))
	ipc.ww_u64(&w, u64(s.started_unix))
	_core_send(h, proto.MSG_SPAWNED, f.channel, ipc.wire_bytes_written(&w))
	return true
}

@(private = "file")
_on_resize :: proc(h: ^Holder, f: ipc.Link_Frame) -> bool {
	r := ipc.wire_reader(f.body)
	size := proto.dec_size(&r)
	if !ipc.wr_done(&r) || size.cols == 0 || size.rows == 0 do return false
	if s := _session_find(h, f.channel); s != nil && !s.eof {
		s.size = size
		pty.pty_set_size(s.master, size.cols, size.rows, size.xpixel, size.ypixel)
	}
	return true
}

// _on_signal never signals a reaped pid (it may belong to someone else now).
@(private = "file")
_on_signal :: proc(h: ^Holder, f: ipc.Link_Frame) -> bool {
	r := ipc.wire_reader(f.body)
	sig := ipc.wr_i32(&r)
	if !ipc.wr_done(&r) || sig < 1 || sig > 64 do return false
	if s := _session_find(h, f.channel); s != nil && !s.reaped do pty.pty_signal(-1 if s.eof else s.master, s.pid, posix.Signal(sig))
	return true
}

@(private = "file")
_on_proc_query :: proc(h: ^Holder, id: u32) {
	s := _session_find(h, id)
	if s == nil do return
	name_buf: [256]u8
	cwd_buf: [1024]u8
	info: proto.Proc_Info_Msg
	if !s.eof do info.pgid, info.name, info.cwd = pty.pty_foreground_info(s.master, name_buf[:], cwd_buf[:])
	w := ipc.wire_writer(h.msg_buf[:])
	proto.enc_proc_info(&w, info)
	_core_send(h, proto.MSG_PROC_INFO, id, ipc.wire_bytes_written(&w))
}

// _on_goodbye: Handover keeps the sessions (tails cleared: the core saved an
// exact state), Shutdown hangs every session up and ends the holder.
@(private = "file")
_on_goodbye :: proc(h: ^Holder, payload: []u8, now: i64) -> bool {
	if len(payload) != 1 do return false
	switch proto.Goodbye(payload[0]) {
	case .Handover:
		for slot in h.live[:h.count] do byte_ring.ring_clear(&h.sessions[slot].tail)
		h.previous = PREVIOUS_HANDOVER
		_core_begin_close(h, now)
	case .Shutdown:
		_forget_all(h)
		_holder_finish(h, now)
	case:
		return false
	}
	return true
}

@(private = "file")
_send_text :: proc(h: ^Holder, kind: u8, channel: u32, text: string) {
	_core_send(h, kind, channel, transmute([]u8)text)
}

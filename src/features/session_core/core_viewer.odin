package feature_session_core

// Viewer and CLI peers of the session Server: they join after HELLO (the
// package checks version, role, uid and slots), send requests on channel 0
// and attach-channel input, and leave. Requests: core_viewer_req.odin.

import proto "../session_proto"
import ipc "../../platform/ipc"

// core_viewer_events serves what the Server has after a wait.
core_viewer_events :: proc(c: ^Core) {
	for ev in ipc.server_next(&c.srv) {
		switch e in ev {
		case ipc.Peer_Joined:  _viewer_join(c, e.peer, proto.Stream_Role(e.role))
		case ipc.Peer_Left:    _viewer_drop(c, e.peer)
		case ipc.Request:
			req := e
			core_viewer_request(c, &req)
		case ipc.Stream_Input: core_attach_input(c, e)
		case ipc.Server_Down:  core_request_stop() // nobody can reach this core any more: hand over
		}
	}
}

core_viewer_of :: proc(c: ^Core, peer: ipc.Peer) -> ^Core_Viewer {
	for &v in c.viewers do if v.used && v.peer == peer do return &v
	return nil
}

// _viewer_join: the Server admits at most CORE_MAX_VIEWERS peers, and Left
// comes before the Joined that reuses a place.
@(private = "file")
_viewer_join :: proc(c: ^Core, peer: ipc.Peer, role: proto.Stream_Role) {
	for &v in c.viewers {
		if v.used do continue
		v = {used = true, peer = peer, role = role}
		return
	}
}

// _viewer_drop: its attachments and waits end; its sessions keep running
// (background), unless the session dir is owned and this was the owner's
// last window: the kernel closes it however the owner ended, and nobody else
// can show them.
@(private = "file")
_viewer_drop :: proc(c: ^Core, peer: ipc.Peer) {
	v := core_viewer_of(c, peer)
	if v == nil do return
	was_viewer := v.role == .Viewer
	v^ = {}
	for &s in c.sessions {
		if !s.used do continue
		for &a in s.attaches do if a.used && a.peer == peer do core_detach(c, &s, &a, false)
	}
	for &l in c.lists do if l.used && l.req.peer == peer do l = {}
	core_watchers_cancel_viewer(c, peer)
	core_settles_cancel_viewer(c, peer)
	core_leases_viewer_gone(c, peer)
	if c.owned && was_viewer && !_any_viewer(c) do for &s in c.sessions do if s.used do core_session_kill(c, &s)
}

@(private = "file")
_any_viewer :: proc(c: ^Core) -> bool {
	for &v in c.viewers do if v.used && v.role == .Viewer do return true
	return false
}

// core_viewer_fail answers req with FAIL.
core_viewer_fail :: proc(c: ^Core, req: ^ipc.Request, code: proto.Fail_Code, reason: string) {
	ipc.fail(&c.srv, req^, u8(code), reason)
}

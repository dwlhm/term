package feature_session

// A session's transport. A Terminal_Session never owns its program: the
// viewer's link goes to the core, the core's link goes to the holder. The
// link owner keeps Session_Info current (from core rows or holder PROC_INFO)
// and, on the viewer, pushes program output into the inbox from its IO thread.

import "core:sync"
import byte_ring "../../core/byte_ring"
import proto "../session_proto"
import ipc "../../platform/ipc"

// One credit window plus one chunk: the sender never has more in flight.
SESSION_INBOX_BYTES :: ipc.STREAM_WINDOW + ipc.STREAM_DATA_CHUNK

Session_Link :: struct {
	write:    proc(user: rawptr, data: []u8), // what a person typed or pasted
	reply:    proc(user: rawptr, data: []u8), // the Terminal answering a query (DSR, DA, APC…)
	resize:   proc(user: rawptr, size: proto.Size_Msg),
	consumed: proc(user: rawptr, n: int), // output bytes the Terminal took (flow-control credit); may be nil
	user:     rawptr,
}

Session_Info :: struct {
	pid:       i32,
	pgid:      i32,
	alive:     bool,
	exit_code: int,
	name_buf:  [64]u8,
	name_len:  int,
	cwd_buf:   [512]u8,
	cwd_len:   int,
}

Session_Inbox :: struct {
	ring:  byte_ring.Byte_Ring,
	mutex: sync.Mutex,
}

// session_inbox_push is called by the link's IO thread. false = no room
// (the sender exceeded its credit: a protocol error on the link).
session_inbox_push :: proc(sess: ^Terminal_Session, bytes: []u8) -> bool {
	sync.mutex_lock(&sess.inbox.mutex)
	defer sync.mutex_unlock(&sess.inbox.mutex)
	return byte_ring.ring_push(&sess.inbox.ring, bytes)
}

session_inbox_pending :: proc(sess: ^Terminal_Session) -> bool {
	sync.mutex_lock(&sess.inbox.mutex)
	defer sync.mutex_unlock(&sess.inbox.mutex)
	return sess.inbox.ring.len > 0
}

@(private)
_inbox_pop :: proc(sess: ^Terminal_Session, out: []u8) -> int {
	sync.mutex_lock(&sess.inbox.mutex)
	defer sync.mutex_unlock(&sess.inbox.mutex)
	return byte_ring.ring_pop(&sess.inbox.ring, out)
}

session_set_info :: proc(sess: ^Terminal_Session, pid, pgid: i32, alive: bool, exit_code: int, name, cwd: string) {
	if sess == nil do return
	sess.info.pid, sess.info.pgid, sess.info.alive, sess.info.exit_code = pid, pgid, alive, exit_code
	sess.info.name_len = copy(sess.info.name_buf[:], name)
	sess.info.cwd_len = copy(sess.info.cwd_buf[:], cwd)
}

session_process_name :: proc(sess: ^Terminal_Session) -> string {
	return string(sess.info.name_buf[:sess.info.name_len]) if sess != nil else ""
}

session_process_cwd :: proc(sess: ^Terminal_Session) -> string {
	return string(sess.info.cwd_buf[:sess.info.cwd_len]) if sess != nil else ""
}

// Session_Provider starts and ends the programs behind panes. The viewer's
// provider is the session client (programs run in the core); tests use a
// local one. release(kill = false) leaves the program running in the background.
Session_Provider :: struct {
	spawn:   proc(user: rawptr, config: Session_Config) -> ^Terminal_Session,
	release: proc(user: rawptr, sess: ^Terminal_Session, kill: bool),
	user:    rawptr,
}

session_provider_release :: proc(p: ^Session_Provider, sess: ^Terminal_Session, kill: bool) {
	if sess == nil do return
	if p.release != nil do p.release(p.user, sess, kill)
	else do session_destroy(sess)
}

package feature_session_proto

// Term's two protocols on platform/ipc, as Protocol values (IPC spec 7.3,
// 7.10), built from the message kinds of this package (msg*.odin).
//
// Both links keep term's HELLO = 10 and FAIL = 84. The holder link stays
// 0.0.2 byte for byte, since a holder lives through upgrades. The session
// link is 0.1.0: every channel 0 frame starts with u32 req. A waiting TELL or
// RESULT gets MSG_TELL_PROGRESS answers before its MSG_TELL_RESULT; detaching
// is a CLOSE on the attach channel, not a request.

import ipc "../../platform/ipc"

HOLDER_VERSION  :: ipc.Version{0, 0, 2}
SESSION_VERSION :: ipc.Version{0, 1, 0}

STREAM_PROTO_VERSION :: 2 // WELCOME's version on the holder link (HOLDER_VERSION packed)

@(rodata)
session_catalog := [?]ipc.Msg_Spec{
	{request = MSG_LIST, answer = MSG_SESSIONS},
	{request = MSG_CREATE, answer = MSG_ATTACHED},
	{request = MSG_KILL, answer = MSG_OK},
	{request = MSG_ATTACH, answer = MSG_ATTACHED},
	{request = MSG_OBSERVE, answer = MSG_OBSERVE_RESULT},
	{request = MSG_READ, answer = MSG_TEXT},
	{request = MSG_SEND, answer = MSG_OK},
	{request = MSG_SESSION_SIGNAL, answer = MSG_OK},
	{request = MSG_SESSION_SIZE, answer = MSG_OK},
	{request = MSG_TELL, answer = MSG_TELL_RESULT, progress = MSG_TELL_PROGRESS},
	{request = MSG_RESULT, answer = MSG_TELL_RESULT, progress = MSG_TELL_PROGRESS},
	{request = MSG_WATCH, answer = MSG_WATCH_RESULT},
	{request = MSG_CANCEL, answer = MSG_OK},
	{request = MSG_NEXT, answer = MSG_REQUEST},
	{request = MSG_ANSWER, answer = MSG_OK},
	{request = MSG_PROGRESS, answer = MSG_OK},
	{request = MSG_ENDPOINT, answer = MSG_OK},
	{request = MSG_SNAPSHOT, answer = MSG_SNAPSHOT_RESULT},
	{request = MSG_SETTLE, answer = MSG_SETTLE_RESULT},
	{request = MSG_ACT, answer = MSG_ACT_RESULT},
	{request = MSG_LEASE, answer = MSG_OK},
	{request = MSG_LEASE_RELEASE, answer = MSG_OK},
	{request = MSG_LEASE_MODE, answer = MSG_OK},
	{request = MSG_EVENT, notice = true},
	{request = MSG_REMOVED, notice = true},
	{request = MSG_LEASE_EVENT, notice = true},
}

// holder: core ↔ holder, a Link (no catalog, no req).
holder :: proc() -> ipc.Protocol {
	return {
		name = "term holder",
		version = HOLDER_VERSION,
		roles = {int(Stream_Role.Core)},
		hello_kind = MSG_HELLO,
		fail_kind = MSG_FAIL,
	}
}

// session: viewers and CLIs ↔ core, a Server/Client.
session :: proc() -> ipc.Protocol {
	return {
		name = "term session",
		version = SESSION_VERSION,
		roles = {int(Stream_Role.Viewer), int(Stream_Role.Cli)},
		catalog = session_catalog[:],
		hello_kind = MSG_HELLO,
		fail_kind = MSG_FAIL,
	}
}

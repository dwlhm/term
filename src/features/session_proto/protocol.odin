package feature_session_proto

// Term's two protocols on platform/ipc, as Protocol values (IPC spec 7.3,
// 7.10). For now only these values live here, built from the message kinds
// in platform/ipc; slice M1 moves the messages, codecs, FAIL codes and
// endpoints here as well.
//
// Both links keep term's HELLO = 10 and FAIL = 84. The holder link stays
// 0.0.2 byte for byte, since a holder lives through upgrades. The session
// link is 0.1.0: every channel 0 frame starts with u32 req.
//
// Not in the session catalog yet: WATCH (answered WATCH_RESULT or OK),
// DETACH (no answer), TELL and RESULT (events after the answer). They are an
// open question in the IPC spec, decided with the term session spec before M3.

import ipc "../../platform/ipc"

HOLDER_VERSION  :: ipc.Version{0, 0, 2}
SESSION_VERSION :: ipc.Version{0, 1, 0}

@(rodata)
session_catalog := [?]ipc.Msg_Spec{
	{request = ipc.MSG_LIST, answer = ipc.MSG_SESSIONS},
	{request = ipc.MSG_CREATE, answer = ipc.MSG_ATTACHED},
	{request = ipc.MSG_KILL, answer = ipc.MSG_OK},
	{request = ipc.MSG_ATTACH, answer = ipc.MSG_ATTACHED},
	{request = ipc.MSG_OBSERVE, answer = ipc.MSG_OBSERVE_RESULT},
	{request = ipc.MSG_READ, answer = ipc.MSG_TEXT},
	{request = ipc.MSG_SEND, answer = ipc.MSG_OK},
	{request = ipc.MSG_SESSION_SIGNAL, answer = ipc.MSG_OK},
	{request = ipc.MSG_SESSION_SIZE, answer = ipc.MSG_OK},
	{request = ipc.MSG_CANCEL, answer = ipc.MSG_OK},
	{request = ipc.MSG_NEXT, answer = ipc.MSG_REQUEST},
	{request = ipc.MSG_ANSWER, answer = ipc.MSG_OK},
	{request = ipc.MSG_PROGRESS, answer = ipc.MSG_OK},
	{request = ipc.MSG_ENDPOINT, answer = ipc.MSG_OK},
	{request = ipc.MSG_SNAPSHOT, answer = ipc.MSG_SNAPSHOT_RESULT},
	{request = ipc.MSG_SETTLE, answer = ipc.MSG_SETTLE_RESULT},
	{request = ipc.MSG_ACT, answer = ipc.MSG_ACT_RESULT},
	{request = ipc.MSG_LEASE, answer = ipc.MSG_OK},
	{request = ipc.MSG_LEASE_RELEASE, answer = ipc.MSG_OK},
	{request = ipc.MSG_LEASE_MODE, answer = ipc.MSG_OK},
	{request = ipc.MSG_EVENT, notice = true},
	{request = ipc.MSG_REMOVED, notice = true},
	{request = ipc.MSG_LEASE_EVENT, notice = true},
}

// holder: core ↔ holder, a Link (no catalog, no req).
holder :: proc() -> ipc.Protocol {
	return {
		name = "term holder",
		version = HOLDER_VERSION,
		roles = {int(ipc.Stream_Role.Core)},
		hello_kind = ipc.MSG_HELLO,
		fail_kind = ipc.MSG_FAIL,
	}
}

// session: viewers and CLIs ↔ core, a Server/Client.
session :: proc() -> ipc.Protocol {
	return {
		name = "term session",
		version = SESSION_VERSION,
		roles = {int(ipc.Stream_Role.Viewer), int(ipc.Stream_Role.Cli)},
		catalog = session_catalog[:],
		hello_kind = ipc.MSG_HELLO,
		fail_kind = ipc.MSG_FAIL,
	}
}

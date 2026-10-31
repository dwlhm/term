package platform_ipc

// One-shot client used by the `term` CLI. Contract: see ipc.odin wire format.

// ipc_client_request connects (non-blocking; ENOENT/ECONNREFUSED →
// Not_Running, EAGAIN → Busy), sends line + '\n' with MSG_NOSIGNAL, then reads
// until EOF into out. One overall deadline of timeout_ms covers every phase
// (poll-based) → Timeout. len(line)+1 > IPC_MAX_LINE or a '\n' inside line →
// Too_Large / Socket_Failed respectively before connecting. out full before
// EOF → Too_Large. A reply of exactly "err busy\n" → Busy (reply still
// returned). Always closes its fd.
ipc_client_request :: proc(path: string, line: string, out: []u8, timeout_ms: int = IPC_CLIENT_TIMEOUT_MS) -> (reply: string, err: Ipc_Error) {
	unimplemented("T5c")
}

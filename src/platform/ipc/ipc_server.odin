package platform_ipc

// Listener thread + fixed-slot mailbox. Contract: see ipc.odin invariants 1–3, 5.

// ipc_server_start binds via ipc_bind_listener (propagating its error), creates
// notify_pipe (both ends O_NONBLOCK|FD_CLOEXEC), stores wake/wake_data, and
// spawns the listener thread. On failure everything acquired is released.
//
// Listener loop (until stopping):
//  - poll(): listen_fd POLLIN only if a .Free slot exists; notify_pipe[0]
//    POLLIN (drain it fully when readable); .Reading → POLLIN; .Writing →
//    POLLOUT. Timeout = min(IPC_POLL_MAX_MS, nearest deadline). EINTR = retry.
//  - accept: set nonblocking/cloexec; ipc_peer_uid must equal getuid() else
//    close; slot → .Reading, deadline = now + IPC_IO_DEADLINE_MS.
//  - .Reading: recv into in_buf; on '\n': strip it (and a preceding '\r'),
//    if Queued+Taken count < IPC_MAILBOX_CAP → .Queued with ticket =
//    next_ticket++ (start at 1), deadline = now + IPC_REPLY_DEADLINE_MS, then
//    call wake(wake_data) after releasing the mutex; else write "err busy\n".
//    in_buf full without '\n' → "err too_large\n". recv 0 / error → close.
//  - .Queued/.Taken past deadline → "err timeout\n" (ticket invalidated).
//  - .Writing: send(MSG_NOSIGNAL) from out_off; done or error or past
//    deadline → close fd, slot → .Free.
//  "write X" above means: out_buf = X, state .Writing, deadline = now + IPC_IO_DEADLINE_MS.
ipc_server_start :: proc(srv: ^Ipc_Server, path: string, wake: Ipc_Wakeup_Proc, wake_data: rawptr) -> Ipc_Error {
	unimplemented("T5b")
}

// ipc_server_poll copies the lowest-ticket .Queued request into out and marks
// it .Taken. Returns false when nothing is queued. Never blocks on I/O.
ipc_server_poll :: proc(srv: ^Ipc_Server, out: ^Ipc_Request) -> bool {
	unimplemented("T5b")
}

// ipc_server_reply moves the .Taken slot with this ticket to .Writing with
// payload (truncated to IPC_MAX_REPLY) and pokes notify_pipe[1]. Unknown or
// expired ticket → silently ignored.
ipc_server_reply :: proc(srv: ^Ipc_Server, ticket: u64, payload: string) {
	unimplemented("T5b")
}

// ipc_server_stop: no-op if not running. Sets stopping, pokes notify_pipe,
// joins and destroys the thread, closes every slot fd, listen_fd and both
// pipe ends, then unlinks the path only if lstat ino == listen_ino.
ipc_server_stop :: proc(srv: ^Ipc_Server) {
	unimplemented("T5b")
}

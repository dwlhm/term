package platform_ipc

// Local Control Socket (Unix domain, one request per connection)
// Part of the Platform layer (src/platform/ipc/*).
//
// Invariants (never violate):
// 1. The UI thread never blocks: ipc_server_poll/ipc_server_reply only take
//    srv.mutex around fixed-size copies and do no syscall except one
//    non-blocking 1-byte write to notify_pipe (EAGAIN ignored).
// 2. Every client fd is O_NONBLOCK|FD_CLOEXEC and every phase has a deadline;
//    a stalled or malicious client can only ever waste its own slot.
// 3. Fixed memory: IPC_MAX_CONNS slots with inline buffers, no allocation
//    after ipc_server_start.
// 4. Only same-uid peers are served (ipc_peer_uid); the socket dir is 0700
//    and the socket 0600; never unlink anything that is not our socket inode.
// 5. send() always uses MSG_NOSIGNAL; a vanished client never raises SIGPIPE.
//
// Wire format: client sends ONE line terminated by '\n' (≤ IPC_MAX_LINE incl.
// '\n'); server writes the reply bytes then closes. Overload/limit replies are
// produced by the listener itself: "err busy\n", "err too_large\n",
// "err timeout\n".

import "core:sync"
import "core:sys/posix"
import "core:thread"

IPC_MAX_LINE          :: 4096
IPC_MAX_REPLY         :: 64 * 1024
IPC_MAX_CONNS         :: 8
IPC_MAILBOX_CAP       :: 8    // max conns in .Queued + .Taken at once
IPC_LISTEN_BACKLOG    :: 16
IPC_IO_DEADLINE_MS    :: 2000 // reading a request / writing a reply
IPC_REPLY_DEADLINE_MS :: 3000 // main thread must reply within this after queueing
IPC_POLL_MAX_MS       :: 1000 // listener poll() upper bound
IPC_CLIENT_TIMEOUT_MS :: 5000
IPC_SOCKET_PATH_ENV   :: "TERM_CTL_SOCK"

Ipc_Error :: enum u8 {
	None,
	Path_Too_Long,   // does not fit sockaddr_un.sun_path (incl. NUL)
	Unsafe_Path,     // dir not ours / not 0700 / symlink, or existing path is not our socket
	Already_Running, // a live server accepted our probe connect
	Not_Running,     // ENOENT / ECONNREFUSED on connect
	Socket_Failed,   // any other syscall failure
	Timeout,
	Too_Large,       // reply exceeded the caller's buffer, or request > IPC_MAX_LINE
	Busy,            // server replied "err busy" or connect got EAGAIN
}

Ipc_Wakeup_Proc :: #type proc "contextless" (user_data: rawptr)

Ipc_Conn_State :: enum u8 {
	Free,
	Reading, // listener owns; accumulating in_buf until '\n'
	Queued,  // line complete, waiting for ipc_server_poll
	Taken,   // handed to the main thread, waiting for ipc_server_reply
	Writing, // listener owns; flushing out_buf then close
}

Ipc_Conn :: struct {
	fd:          posix.FD,
	state:       Ipc_Conn_State,
	deadline_ns: i64, // monotonic (time.tick_now) deadline of the current phase
	ticket:      u64, // unique per request, assigned on .Queued
	in_len:      int,
	in_buf:      [IPC_MAX_LINE]u8,
	out_len:     int,
	out_off:     int,
	out_buf:     [IPC_MAX_REPLY]u8,
}

// Ipc_Server must live at a stable address (heap) between start and stop.
Ipc_Server :: struct {
	path_buf:    [128]u8,
	path_len:    int,
	listen_fd:   posix.FD,
	listen_ino:  u64,       // inode of our bound socket; guards unlink
	notify_pipe: [2]posix.FD, // [0] polled by listener, [1] written by main/stop; both O_NONBLOCK
	thread:      ^thread.Thread,
	mutex:       sync.Mutex, // guards conns[*].state/ticket/in_*/out_* during .Queued/.Taken hand-off
	conns:       [IPC_MAX_CONNS]Ipc_Conn,
	next_ticket: u64,
	stopping:    bool, // atomic
	running:     bool,
	wake:        Ipc_Wakeup_Proc,
	wake_data:   rawptr,
}

Ipc_Request :: struct {
	ticket:   u64,
	line_len: int,
	line_buf: [IPC_MAX_LINE]u8, // request without the trailing '\n' (and without '\r')
}

ipc_request_line :: proc(r: ^Ipc_Request) -> string {
	return string(r.line_buf[:r.line_len])
}

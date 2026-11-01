package feature_holder

// Holder (`term --holder <socket>`): a process supervisor with no VT parser.
// It owns every PTY so shells survive a GUI or core crash; one core at a time
// drives it over a framed ipc.Stream_Conn (channel = session id).
//
// Invariants:
// 1. One thread, one posix.poll over the listener, pending connections, the
//    core link, every session master and a SIGCHLD self-pipe. The timeout is
//    the nearest deadline, -1 when idle (zero wakeups).
// 2. Allocation only at spawn (tail + input rings) and at connect (the
//    core's Stream_Conn); the steady-state loop never allocates.
// 3. PTYs are always read: into the 1 MiB overwrite-oldest tail and, with a
//    core, as MSG_OUTPUT. Reading pauses only while more than HOLDER_BACKLOG
//    is queued for the core, so a stalled core slows programs down instead
//    of growing memory.
// 4. Core input is hostile: a malformed frame or request closes that core
//    link, a bad SPAWN answers SPAWN_FAILED; the holder never crashes on it.
// 5. A reaped pid is never signalled; EXITED follows the last output (reader
//    at EOF) or HOLDER_EXIT_FLOW_MS of flowing time after the child exit.

import "core:fmt"
import "core:sys/posix"
import ipc "../../platform/ipc"

HOLDER_MAX_SESSIONS :: 256
HOLDER_TAIL_BYTES   :: 1 << 20
HOLDER_INPUT_BYTES  :: 1 << 20
HOLDER_BACKLOG      :: 8 << 20 // queued for the core before PTY reads pause
HOLDER_CTL_CAP      :: HOLDER_BACKLOG + (1 << 20)
HOLDER_EXIT_FLOW_MS :: 200
HOLDER_GRACE_MS     :: 3000
HOLDER_LINGER_MS    :: 5000 // flush budget for BYE before a link is dropped
HOLDER_HELLO_MS     :: 5000
HOLDER_MAX_PENDING  :: 4
HOLDER_READ_CHUNK   :: 64 * 1024

PREVIOUS_NONE     :: u8(0)
PREVIOUS_HANDOVER :: u8(1)
PREVIOUS_CRASH    :: u8(2)

Session :: struct {
	used:          bool,
	id:            u32,
	pid:           i32,
	started_unix:  i64,
	master:        i32,
	size:          ipc.Size_Msg,
	tail:          ipc.Byte_Ring, // last HOLDER_TAIL_BYTES of output, overwrite-oldest
	input:         ipc.Byte_Ring, // bytes for the program, written on POLLOUT
	eof:           bool, // reader done (0/EIO): the master is no longer polled
	reaped:        bool,
	exit_final:    bool, // EXITED may be reported
	exit_sent:     bool, // the current core knows the exit (EXITED or WELCOME)
	tailed:        bool, // the current core has this session's TAIL: OUTPUT may flow
	exit:          ipc.Exit_Msg,
	exit_deadline: i64, // reap + HOLDER_EXIT_FLOW_MS, shifted by paused time
}

// Pending is an accepted connection that has not sent its HELLO yet.
Pending :: struct {
	fd:       posix.FD, // -1 = free
	buf:      [512]u8,
	len:      int,
	deadline: i64,
}

Core_State :: enum u8 {
	None,
	Linked,
	Closing, // BYE queued: only flushed until empty or the linger deadline
}

Poll_Kind :: enum u8 { Listener, Signal, Pending, Core, Session }

Poll_Tag :: struct {
	kind:  Poll_Kind,
	index: int,
}

HOLDER_MAX_POLL :: 3 + HOLDER_MAX_PENDING + HOLDER_MAX_SESSIONS

Holder :: struct {
	listen_fd:     posix.FD,
	listen_ino:    u64,
	path_buf:      [256]u8,
	path_len:      int,
	build_buf:     [64]u8,
	build:         string, // ipc_build_id: holders of another build get drained
	sessions:      [HOLDER_MAX_SESSIONS]Session,
	count:         int,
	pending:       [HOLDER_MAX_PENDING]Pending,
	core:          ipc.Stream_Conn,
	core_state:    Core_State,
	core_deadline: i64, // Closing: linger end
	tail_cursor:   int, // sessions below this index have been offered their TAIL
	previous:      u8, // how the last core link ended, for the next WELCOME
	crash_times:   [HOLDER_CRASH_MEMORY]i64, // when core links ended in a crash (ring)
	crash_next:    int,
	instance:      u64,
	paused:        bool, // PTY reads paused by core backpressure
	pause_start:   i64,
	draining:      bool,
	stopping:      bool, // exit once the closing link is flushed
	done:          bool,
	exit_code:     int,
	sup:           Supervisor,
	signals:       Signal_State,
	orphans:       [HOLDER_MAX_SESSIONS]i32, // released, not yet reaped children
	pfds:          [HOLDER_MAX_POLL]posix.pollfd,
	tags:          [HOLDER_MAX_POLL]Poll_Tag,
	msg_buf:       [16 * 1024]u8, // WELCOME / PROC_INFO encoding scratch
	read_buf:      [HOLDER_READ_CHUNK]u8, // one PTY read (a stack array would be zeroed per read)
}

// holder_run serves socket_path until shut down, drained empty, or idle
// (no core and no sessions) for the grace period. setsid is the spawner's job.
holder_run :: proc(socket_path: string) -> int {
	h := new(Holder)
	defer free(h)
	if !_holder_open(h, socket_path) {
		_holder_close(h)
		return 1
	}
	for !h.done {
		_holder_tick(h, _now())
		if h.done do break
		n := _poll_build(h)
		ready := posix.poll(&h.pfds[0], posix.nfds_t(n), _poll_timeout(h, _now()))
		if ready < 0 && posix.errno() != .EINTR {
			fmt.eprintfln("holder: poll failed: %v", posix.errno())
			h.exit_code = 1
			break
		}
		if ready > 0 do _poll_dispatch(h, n)
		_core_pump(h, _now())
	}
	code := h.exit_code
	_holder_close(h)
	return code
}

@(private = "file")
_holder_open :: proc(h: ^Holder, socket_path: string) -> bool {
	h.listen_fd = -1
	for &p in h.pending do p.fd = -1
	h.core.fd = -1
	if len(socket_path) >= len(h.path_buf) {
		fmt.eprintln("holder: socket path too long")
		return false
	}
	copy(h.path_buf[:], socket_path)
	h.path_len = len(socket_path)
	fd, ino, err := ipc.ipc_bind_listener(socket_path)
	if err != .None {
		fmt.eprintfln("holder: cannot listen on %s: %s", socket_path, ipc.ipc_error_message(err))
		return false
	}
	h.listen_fd, h.listen_ino = fd, ino
	if !_signals_install(&h.signals) {
		fmt.eprintln("holder: cannot install the SIGCHLD pipe")
		return false
	}
	h.instance = _random_u64()
	h.build = ipc.ipc_build_id(h.build_buf[:])
	now := _now()
	_supervisor_init(&h.sup, now)
	return true
}

// _holder_close releases everything; sessions still held are hung up.
@(private = "file")
_holder_close :: proc(h: ^Holder) {
	for &s in h.sessions do if s.used do _session_forget(h, &s)
	_core_destroy(h)
	for &p in h.pending do _pending_close(&p)
	if h.listen_fd >= 0 {
		posix.close(h.listen_fd)
		ipc.ipc_unlink_if_ours(string(h.path_buf[:h.path_len]), h.listen_ino)
	}
	_orphans_reap_wait(h)
	_signals_restore(&h.signals)
}

// _holder_finish ends the holder: BYE to a linked core (flushed within the
// linger budget), then exit 0.
_holder_finish :: proc(h: ^Holder, now: i64) {
	h.stopping = true
	if h.core_state == .Linked {
		_core_begin_close(h, now)
		return
	}
	if h.core_state == .None do h.done = true
}

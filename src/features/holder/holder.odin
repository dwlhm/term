package feature_holder

// Holder (`term --holder <socket>`): a process supervisor with no VT parser.
// It owns every PTY so shells survive a GUI or core crash; one core at a time
// drives it over an ipc.Link (proto.holder(), channel = session id): the
// newest core to pass HELLO takes the holder.
//
// Invariants:
// 1. One thread, one wait (an ipc.Poll_Set) over the link, every session
//    master (poll_set_watch) and SIGCHLD (poll_set_poke from the handler).
//    The deadline is the nearest one, none when idle (zero wakeups). A round
//    reads the clock once, visits only live sessions and drains each ready
//    master into one OUTPUT frame (macOS hands out ~1 KiB per read).
// 2. Allocation only at spawn (tail + input rings) and at open (the link's
//    buffers, reused by every core); the steady-state loop never allocates.
// 3. PTYs are always read: into the 1 MiB overwrite-oldest tail and, with a
//    core, as MSG_OUTPUT. Reading pauses only while more than HOLDER_BACKLOG
//    is queued for the core, so a stalled core slows programs down instead
//    of growing memory.
// 4. Core input is hostile: a malformed frame or request closes that core
//    link, a bad SPAWN answers SPAWN_FAILED; the holder never crashes on it.
// 5. A reaped pid is never signalled; EXITED follows the last output (reader
//    at EOF) or HOLDER_EXIT_FLOW_MS of flowing time after the child exit.

import "core:fmt"
import "core:strings"
import byte_ring "../../core/byte_ring"
import proto "../session_proto"
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
HOLDER_READ_CHUNK   :: ipc.STREAM_DATA_CHUNK // drain budget per master per round

PREVIOUS_NONE     :: u8(0)
PREVIOUS_HANDOVER :: u8(1)
PREVIOUS_CRASH    :: u8(2)

Session :: struct {
	used:          bool,
	id:            u32,
	pid:           i32,
	started_unix:  i64,
	master:        i32,
	size:          proto.Size_Msg,
	tail:          byte_ring.Byte_Ring, // last HOLDER_TAIL_BYTES of output, overwrite-oldest
	input:         byte_ring.Byte_Ring, // bytes for the program, written on POLLOUT
	eof:           bool, // reader done (0/EIO): the master is no longer polled
	reaped:        bool,
	exit_final:    bool, // EXITED may be reported
	exit_sent:     bool, // the current core knows the exit (EXITED or WELCOME)
	tailed:        bool, // the current core has this session's TAIL: OUTPUT may flow
	exit:          proto.Exit_Msg,
	exit_deadline: i64, // reap + HOLDER_EXIT_FLOW_MS, shifted by paused time
	holder:        ^Holder,
	watch:         ipc.Fd_Watch, // the master in the Poll_Set; 0 once at EOF
}

Core_State :: enum u8 {
	None,
	Linked,
	Closing, // BYE queued: only flushed until empty or the linger deadline
}

HOLDER_POLL_CAP :: HOLDER_MAX_SESSIONS + 4 // the masters, the link and its pending HELLOs

Holder :: struct {
	set:           ipc.Poll_Set,
	link:          ipc.Link,
	build_buf:     [64]u8,
	build:         string, // proto.build_id: holders of another build get drained
	sessions:      [HOLDER_MAX_SESSIONS]Session,
	count:         int,
	live:          [HOLDER_MAX_SESSIONS]u16, // slots in use: live[:count], unordered
	core_state:    Core_State,
	core_deadline: i64, // Closing: linger end
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
	msg_buf:       [16 * 1024]u8, // WELCOME / PROC_INFO encoding scratch
	read_buf:      [HOLDER_READ_CHUNK]u8, // one drained frame (a stack array would be zeroed per read)
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
	now := _now() // one clock read per round: taken when the wait returns
	for !h.done {
		_holder_tick(h, now)
		if h.done do break
		_holder_wants(h)
		ipc.poll_set_wait(&h.set, _holder_due(h, now))
		now = _now()
		if ipc.poll_set_woken(&h.set) do _reap_all(h, now) // SIGCHLD
		_core_events(h, now)
		_core_pump(h, now)
	}
	code := h.exit_code
	_holder_close(h)
	return code
}

@(private = "file")
_holder_open :: proc(h: ^Holder, socket_path: string) -> bool {
	if err := ipc.poll_set_init(&h.set, HOLDER_POLL_CAP); err.kind != .None {
		fmt.eprintfln("holder: cannot create its poll set: %s", ipc.error_message(err))
		return false
	}
	slash := strings.last_index_byte(socket_path, '/')
	at := ipc.Endpoint{socket_path[:max(slash, 0)], socket_path[slash + 1:]}
	opts := ipc.Link_Opts{hello_ms = HOLDER_HELLO_MS, pending = HOLDER_MAX_PENDING, backlog = HOLDER_CTL_CAP, role = u8(proto.Stream_Role.Holder)}
	if err := ipc.link_listen(&h.link, at, proto.holder(), &h.set, opts); err.kind != .None {
		fmt.eprintfln("holder: cannot listen on %s: %s (%s)", socket_path, ipc.error_message(err), err.reason)
		return false
	}
	if !_signals_install(&h.signals, &h.set) {
		fmt.eprintln("holder: cannot install the SIGCHLD handler")
		return false
	}
	h.instance = _random_u64()
	h.build = proto.build_id(h.build_buf[:])
	now := _now()
	_supervisor_init(&h.sup, now)
	return true
}

// _holder_close releases everything; sessions still held are hung up.
@(private = "file")
_holder_close :: proc(h: ^Holder) {
	_forget_all(h)
	ipc.link_close(&h.link) // unlinks the socket while it is still ours
	_orphans_reap_wait(h)
	_signals_restore(&h.signals)
	ipc.poll_set_destroy(&h.set)
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

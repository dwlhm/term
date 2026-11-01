package feature_session_core

// The core tier (`term --core`): one headless Terminal per session, fed by the
// holders that own the programs, served to viewers and the `term session` CLI.
//
// Invariants:
// 1. Single-threaded poll loop; poll timeout = nearest deadline, -1 when idle.
// 2. Buffers are allocated at start, per session at create/adopt and per
//    connection at accept; the steady-state loop does not allocate.
// 3. Every byte a program prints reaches its Terminal; viewers get the same
//    bytes minus queries the core answered (terminal.relay_feed).
// 4. A viewer never blocks a program: a slow one loses its backlog and gets a
//    repaint (stream overflow → recovering → paint at parser ground).
// 5. Sessions outlive viewers. The core exits only when no session and no
//    viewer is left for CORE_GRACE_MS, after telling every holder to shut down.

import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:time"
import terminal "../../core/terminal"
import ipc "../../platform/ipc"
import session "../session"

CORE_MAX_SESSIONS :: 256
CORE_MAX_HOLDERS  :: 4
CORE_MAX_VIEWERS  :: 16
CORE_MAX_ATTACH   :: 8
CORE_GRACE_MS     :: 3000
CORE_PROC_WAIT_MS :: 300 // LIST waits this long for fresh foreground info
CORE_HOLDER_CTL   :: 2 << 20
CORE_VIEWER_CTL   :: 2 << 20
CORE_SOCKET_NAME  :: "core.sock"
CORE_POISON_CRASHES :: 3 // recent core crashes after which tails are not replayed

Core_Holder :: struct {
	used:     bool,
	welcomed: bool,
	current:  bool, // our build: new sessions go here
	poisoned: bool, // its tails keep crashing cores: rebuild screens without them
	handover: bool, // the last core left on purpose: tails are unanswered output
	instance: u64,
	conn:     ipc.Stream_Conn,
}

Core_Attach :: struct {
	used:       bool,
	observe:    bool,
	recovering: bool, // missed output: gets a paint at the next parser ground
	viewer:     int,
	channel:    u32,
	size:       ipc.Size_Msg,
	active_ns:  i64,
}

Core_Link :: struct {
	core: ^Core,
	id:   u32,
}

Core_Session :: struct {
	used:         bool,
	exited:       bool,
	proc_pending: bool,
	id:           u32,
	holder:       int,
	started_ns:   i64,
	row_hash:     u64,
	exit:         ipc.Exit_Msg,
	sess:         ^session.Terminal_Session,
	relay:        terminal.Relay,
	link:         Core_Link,
	attaches:     [CORE_MAX_ATTACH]Core_Attach,
}

Core_Viewer :: struct {
	used:         bool,
	hello:        bool,
	role:         ipc.Stream_Role,
	list_waiting: bool,
	list_due_ns:  i64,
	next_channel: u32,
	conn:         ipc.Stream_Conn,
}

Core :: struct {
	dir_buf:     [256]u8,
	dir:         string,
	sock_buf:    [256]u8,
	sock:        string,
	build_buf:   [64]u8,
	build:       string,
	listen_fd:   posix.FD,
	listen_ino:  u64,
	next_id:     u32,
	empty_since: i64,
	holders:     [CORE_MAX_HOLDERS]Core_Holder,
	sessions:    [CORE_MAX_SESSIONS]Core_Session,
	viewers:     [CORE_MAX_VIEWERS]Core_Viewer,
	viewer_out:  [dynamic]u8,
	replies:     [dynamic]u8,
	paint:       [dynamic]u8,
	msg:         []u8, // one encoded payload
}

@(private)
_stop_requested: bool

@(private)
_now :: proc() -> i64 { return time.tick_now()._nsec }

// core_run serves until no session and no viewer is left. 0 = clean exit or
// another core already serves this session dir.
core_run :: proc() -> int {
	c := new(Core)
	defer _core_destroy(c)
	if !_core_listen(c) do return 0 if c.listen_fd == -2 else 1
	c.build = ipc.ipc_build_id(c.build_buf[:])
	c.next_id = 1
	c.msg = make([]u8, ipc.STREAM_MAX_PAYLOAD)
	reserve(&c.viewer_out, 256 * 1024)
	reserve(&c.replies, 4096)
	reserve(&c.paint, 1 << 20)
	_install_stop_signals()
	core_adopt_holders(c)
	if core_current_holder(c) < 0 && !core_start_holder(c) do return 1
	c.empty_since = _now()
	for !sync.atomic_load(&_stop_requested) && !_core_done(c) do _core_step(c)
	if sync.atomic_load(&_stop_requested) {
		core_handover(c)
	} else {
		core_shutdown_holders(c)
		_remove_private_dir(c)
	}
	return 0
}

// _remove_private_dir: a private session (TERM_SESSION_DIR) ends with its last
// tier. rmdir only succeeds once the holder removed its socket (empty dir).
@(private = "file")
_remove_private_dir :: proc(c: ^Core) {
	env: [256]u8
	if v, _ := os.lookup_env(env[:], ipc.SESSION_DIR_ENV); len(v) == 0 do return
	posix.close(c.listen_fd)
	ipc.ipc_unlink_if_ours(c.sock, c.listen_ino)
	c.listen_fd = -1
	cbuf: [256]u8
	copy(cbuf[:len(cbuf) - 1], c.dir)
	for _ in 0..<50 {
		if posix.rmdir(cstring(raw_data(cbuf[:]))) == .OK do return
		time.sleep(20 * time.Millisecond)
	}
}

@(private = "file")
_core_listen :: proc(c: ^Core) -> bool {
	c.listen_fd = -1
	err: ipc.Ipc_Error
	if c.dir, err = ipc.ipc_session_dir(c.dir_buf[:]); err != .None do return false
	ok: bool
	if c.sock, ok = ipc.ipc_session_path(c.sock_buf[:], c.dir, CORE_SOCKET_NAME); !ok do return false
	c.listen_fd, c.listen_ino, err = ipc.ipc_bind_listener(c.sock)
	if err == .Already_Running do c.listen_fd = -2
	return err == .None
}

@(private = "file")
_core_destroy :: proc(c: ^Core) {
	if c.listen_fd >= 0 {
		posix.close(c.listen_fd)
		ipc.ipc_unlink_if_ours(c.sock, c.listen_ino)
	}
	for &h in c.holders do if h.used do ipc.stream_conn_destroy(&h.conn)
	for &v in c.viewers do if v.used do ipc.stream_conn_destroy(&v.conn)
	for &s in c.sessions do if s.used do core_session_free(c, &s)
	delete(c.viewer_out)
	delete(c.replies)
	delete(c.paint)
	delete(c.msg)
	free(c)
}

// _core_done: nothing left to serve for a whole grace period.
@(private = "file")
_core_done :: proc(c: ^Core) -> bool {
	if core_session_count(c) > 0 || _viewer_count(c) > 0 {
		c.empty_since = 0
		return false
	}
	if c.empty_since == 0 do c.empty_since = _now()
	return _now() - c.empty_since >= CORE_GRACE_MS * 1_000_000
}

@(private = "file")
_viewer_count :: proc(c: ^Core) -> int {
	n := 0
	for &v in c.viewers do if v.used do n += 1
	return n
}

@(private = "file")
_stop_handler :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&_stop_requested, true)
}

// SIGTERM/SIGINT are a planned restart: holders keep every program and the
// next core restores the saved screens (core_handover).
@(private = "file")
_install_stop_signals :: proc() {
	posix.signal(.SIGTERM, _stop_handler)
	posix.signal(.SIGINT, _stop_handler)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

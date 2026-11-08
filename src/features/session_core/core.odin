package feature_session_core

// The core tier (`term --core`): one headless Terminal per session, fed by the
// holders that own the programs, served to viewers and the `term session` CLI.
//
// Invariants:
// 1. Single-threaded wait loop (an ipc.Poll_Set); deadline = the nearest one, none when idle.
// 2. Buffers are allocated at start, per session at create/adopt and per
//    connection at accept; the steady-state loop does not allocate.
// 3. Every byte a program prints reaches its Terminal; viewers get the same
//    bytes minus queries the core answered (terminal.relay_feed).
// 4. A viewer never blocks a program: a slow one loses its backlog and gets a
//    repaint (stream overflow → recovering → paint at parser ground).
// 5. Sessions outlive viewers. The core exits only when no session and no
//    viewer is left for its grace (CORE_GRACE_MS, env TERM_CORE_GRACE_MS),
//    after telling every holder to shut down.

import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:time"
import terminal "../../core/terminal"
import proto "../session_proto"
import ipc "../../platform/ipc"
import session "../session"

CORE_MAX_SESSIONS :: 256
CORE_MAX_HOLDERS  :: 4
CORE_MAX_VIEWERS  :: 16
CORE_MAX_ATTACH   :: 8
CORE_GRACE_MS     :: 3000
CORE_PROC_WAIT_MS :: 300 // LIST waits this long for fresh foreground info
CORE_SETTLE_MS :: 250 // output quiet this long → refresh the foreground process (titles, active), resync stale viewers
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
	link:     ipc.Link,
	broken:   bool, // its backlog overflowed: dropped after this round
	path_buf: [128]u8,
	path_len: int, // its socket: removed when the holder dies without unlinking it
}

Core_Attach :: struct {
	used:       bool,
	observe:    bool,
	recovering: bool, // missed output: gets a paint at the next parser ground
	stale:      bool, // painted without history after missing output: gets its history once output settles
	history:    int,  // scrollback lines this viewer asked for (first paint and resync)
	viewer:     int,
	channel:    u32,
	size:       proto.Size_Msg,
	active_ns:  i64,
}

Core_Link :: struct {
	core: ^Core,
	id:   u32,
}

Core_Session :: struct {
	used:              bool,
	exited:            bool,
	proc_pending:      bool,
	settle_due_ns:     i64, // output settles then: foreground process query + stale viewer resync (0 = nothing due)
	id:                u32,
	holder:            int,
	started_unix:      i64,
	row_hash:          u64,
	exit:              proto.Exit_Msg,
	sess:              ^session.Terminal_Session,
	relay:             terminal.Relay,
	link:              Core_Link,
	stitch:            ^Stitch_State, // nil until a read asks for alt-screen history
	attaches:          [CORE_MAX_ATTACH]Core_Attach,
	last_prompt_state: proto.Prompt_State,
	last_cmd_seq:      u32,
	output_ns:         i64, // when its program last printed (or the session began)
	lease:             Core_Lease, // an automation holding its input (core_auto_lease.odin)
	gen:               u64, // screen generation: +1 per output chunk or resize (MSG_SNAPSHOT / MSG_SETTLE)
	endpoint:          Core_Endpoint, // a virtual session (core_endpoint.odin)
}

Core_Viewer :: struct {
	used:          bool,
	core:          ^Core,
	index:         int,
	watch:         ipc.Fd_Watch, // its fd in the Poll_Set
	hello:         bool,
	role:          proto.Stream_Role,
	seq:           u32, // per accepted connection: a stitch answers only its own reader
	list_waiting:  bool,
	list_due_ns:   i64,
	next_channel:  u32,
	conn:          ipc.Stream_Conn,
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
	viewer_seq:  u32,
	empty_since: i64,
	grace_ns:    i64,
	owned:       bool, // SESSION_OWNED_ENV: sessions end with the owner's last viewer
	set:         ipc.Poll_Set, // core_request_stop / SIGTERM poke it
	listen_watch: ipc.Fd_Watch,
	holders:     [CORE_MAX_HOLDERS]Core_Holder,
	sessions:    [CORE_MAX_SESSIONS]Core_Session,
	viewers:     [CORE_MAX_VIEWERS]Core_Viewer,
	watchers:    [CORE_MAX_WATCHERS]Core_Watcher,
	settles:     [CORE_MAX_SETTLES]Core_Settle,
	broker:      Broker,
	broker_due_ns: i64, // next request deadline (0 = none)
	typed:       [dynamic]u8, // input the broker types into a session
	viewer_out:  [dynamic]u8,
	replies:     [dynamic]u8,
	paint:       [dynamic]u8,
	text:        [dynamic]u8, // MSG_READ answer, MSG_SNAPSHOT row text
	snap_runs:   [dynamic]proto.Snap_Run, // one snapshot row
	snap_spans:  [dynamic][2]int, // its runs' text in c.text
	snap_links:  [dynamic]u16, // OSC 8 ids one snapshot refers to
	act:         [dynamic]u8, // one MSG_ACT's encoded input
	msg:         []u8, // one encoded payload
}

@(private)
_now :: proc() -> i64 { return time.tick_now()._nsec }

@(private)
_now_unix :: proc() -> i64 { return time.to_unix_seconds(time.now()) }

// core_new allocates a core and every buffer its loop uses (no sockets yet).
core_new :: proc() -> ^Core {
	c := new(Core)
	c.listen_fd = -1
	c.build = ipc.ipc_build_id(c.build_buf[:])
	c.next_id = 1
	c.grace_ns = _grace_ms() * 1_000_000
	owned_buf: [64]u8 // lookup_env also stores the key here
	c.owned = os.get_env(owned_buf[:], proto.SESSION_OWNED_ENV) == "1"
	c.msg = make([]u8, ipc.STREAM_MAX_PAYLOAD)
	reserve(&c.viewer_out, 256 * 1024)
	reserve(&c.replies, 4096)
	reserve(&c.paint, 1 << 20)
	reserve(&c.typed, BROKER_TEXT_CAP + 1024)
	broker_init(&c.broker, _now)
	return c
}

// core_run serves until no session and no viewer is left. 0 = clean exit or
// another core already serves this session dir.
core_run :: proc() -> int {
	c := core_new()
	defer core_destroy(c)
	if err := ipc.poll_set_init(&c.set, CORE_MAX_POLL); err.kind != .None do return 1
	if !_core_listen(c) do return 0 if c.listen_fd == -2 else 1
	_stop_open(c)
	_install_stop_signals()
	core_adopt_holders(c)
	if core_current_holder(c) < 0 && !core_start_holder(c) do return 1
	c.empty_since = _now()
	for !_stop_is_requested() && !_core_done(c) do _core_step(c)
	if _stop_is_requested() {
		core_handover(c)
	} else {
		core_shutdown_holders(c)
		_remove_private_dir(c)
	}
	return 0
}

@(private = "file")
_grace_ms :: proc() -> i64 {
	buf: [32]u8
	if v, ok := strconv.parse_int(os.get_env(buf[:], "TERM_CORE_GRACE_MS")); ok && v >= 0 do return i64(v)
	return CORE_GRACE_MS
}

core_destroy :: proc(c: ^Core) {
	_stop_close(c)
	if c.listen_fd >= 0 {
		ipc.poll_set_unwatch(&c.set, c.listen_watch)
		posix.close(c.listen_fd)
		ipc.ipc_unlink_if_ours(c.sock, c.listen_ino)
	}
	for &h in c.holders do if h.used do ipc.link_close(&h.link)
	for &v in c.viewers {
		if !v.used do continue
		ipc.poll_set_unwatch(&c.set, v.watch)
		ipc.stream_conn_destroy(&v.conn)
	}
	for &s in c.sessions do if s.used do core_session_free(c, &s)
	delete(c.viewer_out)
	delete(c.replies)
	delete(c.paint)
	delete(c.text)
	delete(c.snap_runs)
	delete(c.snap_spans)
	delete(c.snap_links)
	delete(c.act)
	delete(c.typed)
	delete(c.msg)
	broker_destroy(&c.broker)
	ipc.poll_set_destroy(&c.set)
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
	return _now() - c.empty_since >= c.grace_ns
}

@(private = "file")
_viewer_count :: proc(c: ^Core) -> int {
	n := 0
	for &v in c.viewers do if v.used do n += 1
	return n
}

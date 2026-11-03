package feature_holder

// Core supervision (grace, backoff, idle exit) and the SIGCHLD self-pipe.

import "core:c"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import ipc "../../platform/ipc"

HOLDER_BACKOFF_MAX_N   :: 6
HOLDER_BACKOFF_CAP_MS  :: 60_000
HOLDER_RESTART_WINDOW  :: 5 * 60 * 1000 // ms: restarts counted for the backoff

Supervisor :: struct {
	grace:        i64, // ns
	no_core:      bool, // TERM_HOLDER_NO_CORE=1: never start a core (tests)
	linked:       bool,
	absent_since: i64, // no core since
	empty_since:  i64, // no session since
	restarts:     [HOLDER_BACKOFF_MAX_N + 2]i64,
	next_restart: int,
}

_supervisor_init :: proc(sup: ^Supervisor, now: i64) {
	buf: [32]u8
	grace_ms := HOLDER_GRACE_MS
	if v, ok := strconv.parse_int(os.get_env(buf[:], "TERM_HOLDER_GRACE_MS")); ok && v >= 0 do grace_ms = v
	sup.grace = _ms(grace_ms)
	sup.no_core = os.get_env(buf[:], "TERM_HOLDER_NO_CORE") == "1"
	sup.absent_since, sup.empty_since = now, now
}

_supervisor_linked :: proc(sup: ^Supervisor) { sup.linked = true }

_supervisor_unlinked :: proc(sup: ^Supervisor, now: i64) {
	sup.linked = false
	sup.absent_since = now
}

_supervisor_empty :: proc(sup: ^Supervisor, now: i64) { sup.empty_since = now }

// _supervise_deadline: when to start a core (sessions, no core) or to exit
// (no core, no sessions); NO_DEADLINE while a core is linked.
_supervise_deadline :: proc(h: ^Holder, now: i64) -> i64 {
	sup := &h.sup
	if sup.linked || h.stopping do return NO_DEADLINE
	if h.count == 0 do return max(sup.absent_since, sup.empty_since) + sup.grace
	if sup.no_core do return NO_DEADLINE
	return sup.absent_since + _backoff(sup, now)
}

// _backoff = grace·2^n, n = restarts in the last 5 min (≤ 6), capped at 60 s.
@(private = "file")
_backoff :: proc(sup: ^Supervisor, now: i64) -> i64 {
	n := 0
	for t in sup.restarts do if t != 0 && now - t < _ms(HOLDER_RESTART_WINDOW) do n += 1
	return min(sup.grace << uint(min(n, HOLDER_BACKOFF_MAX_N)), _ms(HOLDER_BACKOFF_CAP_MS))
}

_supervise :: proc(h: ^Holder, now: i64) {
	if now < _supervise_deadline(h, now) do return
	if h.count == 0 {
		h.done = true
		return
	}
	sup := &h.sup
	sup.restarts[sup.next_restart] = now
	sup.next_restart = (sup.next_restart + 1) % len(sup.restarts)
	sup.absent_since = now // the next attempt waits a full (longer) backoff
	_start_core()
}

_random_u64 :: proc() -> u64 {
	b: [8]u8
	crypto.rand_bytes(b[:])
	return transmute(u64)b
}

Signal_State :: struct {
	pipe:      [2]posix.FD,
	old_chld:  posix.sigaction_t,
	old_pipe:  posix.sigaction_t,
	installed: bool,
}

@(private = "file")
_sigchld_fd: posix.FD = -1

@(private = "file")
_on_sigchld :: proc "c" (sig: posix.Signal) {
	saved := posix.errno()
	b: u8 = 1
	posix.write(_sigchld_fd, &b, 1) // a full pipe already means "reap"
	posix.errno(saved)
}

// _signals_install: SIGCHLD → self-pipe, SIGPIPE ignored (children get
// default dispositions back at spawn).
_signals_install :: proc(st: ^Signal_State) -> bool {
	st.pipe = {-1, -1}
	if posix.pipe(&st.pipe) != .OK do return false
	for fd in st.pipe {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
		posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC))
	}
	_sigchld_fd = st.pipe[1]
	act := posix.sigaction_t{sa_handler = _on_sigchld, sa_flags = {.RESTART, .NOCLDSTOP}}
	posix.sigemptyset(&act.sa_mask)
	if posix.sigaction(.SIGCHLD, &act, &st.old_chld) != .OK do return false
	ign := posix.sigaction_t{sa_handler = auto_cast posix.SIG_IGN}
	posix.sigemptyset(&ign.sa_mask)
	posix.sigaction(.SIGPIPE, &ign, &st.old_pipe)
	st.installed = true
	return true
}

_signals_restore :: proc(st: ^Signal_State) {
	if st.installed {
		posix.sigaction(.SIGCHLD, &st.old_chld, nil)
		posix.sigaction(.SIGPIPE, &st.old_pipe, nil)
		st.installed = false
	}
	_sigchld_fd = -1
	for &fd in st.pipe {
		if fd >= 0 do posix.close(fd)
		fd = -1
	}
}

_signals_drain :: proc(st: ^Signal_State) {
	buf: [64]u8
	for posix.read(st.pipe[0], &buf[0], len(buf)) > 0 {}
}

// _start_core launches `<own executable> --core` detached (new session,
// reparented to init) with stdout/stderr appended to core.log (ipc_log_path).
@(private = "file")
_start_core :: proc() {
	log_buf: [256]u8
	log_path := ipc.ipc_log_path(log_buf[:], "core.log")
	if !ipc.ipc_spawn_self_detached({"--core"}, log_path) {
		fmt.eprintfln("holder: cannot start a core: %v", posix.errno())
	}
}

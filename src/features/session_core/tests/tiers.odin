package feature_session_core_tests

// Test fixture: holder_run and core_run in threads of this process on a
// private session dir under /tmp (sun_path is short), plus CLI helpers.
// The holder never starts a core of its own (TERM_HOLDER_NO_CORE=1): the
// test runner binary must never be re-executed as `--core`.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import holder "../../holder"
import core ".."
import client "../../session_client"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

Tiers :: struct {
	dir_buf:     [64]u8,
	dir:         string,
	hsock_buf:   [96]u8,
	hsock:       string,
	holder_th:   ^thread.Thread,
	core_th:     ^thread.Thread,
	holder_done: bool, // atomic
	core_done:   bool, // atomic
}

@(private = "file")
_seq: int

tiers_start :: proc() -> ^Tiers {
	t := new(Tiers)
	_seq += 1
	t.dir = fmt.bprintf(t.dir_buf[:], "/tmp/tsc-%d-%d", posix.getpid(), _seq)
	os.set_env(proto.SESSION_DIR_ENV, t.dir)
	os.set_env("TERM_HOLDER_NO_CORE", "1")
	os.set_env("TERM_HOLDER_GRACE_MS", "100")
	os.set_env("TERM_CORE_GRACE_MS", "100")
	buf: [64]u8
	_, _ = proto.session_dir(buf[:]) // creates the dir 0700
	t.hsock = fmt.bprintf(t.hsock_buf[:], "%s/h.%08x.sock", t.dir, u32(posix.getpid()) * 31 + u32(_seq))
	t.holder_th = thread.create_and_start_with_poly_data(t, proc(t: ^Tiers) {
		holder.holder_run(t.hsock)
		sync.atomic_store(&t.holder_done, true)
	})
	_wait_socket(t.hsock)
	tiers_core_start(t)
	return t
}

tiers_core_start :: proc(t: ^Tiers) {
	sync.atomic_store(&t.core_done, false)
	t.core_th = thread.create_and_start_with_poly_data(t, proc(t: ^Tiers) {
		core.core_run()
		sync.atomic_store(&t.core_done, true)
	})
	buf: [128]u8
	_wait_socket(fmt.bprintf(buf[:], "%s/core.sock", t.dir))
}

// tiers_core_restart_stop stops the core as SIGTERM does (a planned restart:
// the holder keeps every program, the next core restores the screens).
// kill -9 (the crash path) is covered by scripts/stress/session_tiers.py.
tiers_core_restart_stop :: proc(t: ^Tiers) {
	core.core_request_stop()
	_join(&t.core_th)
}

// tiers_stop kills what is left, then waits for the core to shut the holder
// down and remove the dir. false = a tier did not end on its own.
tiers_stop :: proc(t: ^Tiers) -> bool {
	if t.core_th != nil {
		ids: [64]u32
		for id in cli_list_ids(ids[:]) do cli_kill(id)
	}
	ok := _wait_flag(&t.core_done, 5000) && _wait_flag(&t.holder_done, 5000)
	if !ok do core.core_request_stop()
	_join(&t.core_th)
	_join(&t.holder_th)
	cbuf: [64]u8
	copy(cbuf[:63], t.dir)
	gone := posix.access(cstring(raw_data(cbuf[:]))) != .OK
	free(t)
	return ok && gone
}

@(private = "file")
_join :: proc(th: ^^thread.Thread) {
	if th^ == nil do return
	thread.join(th^)
	thread.destroy(th^)
	th^ = nil
}

@(private = "file")
_wait_flag :: proc(flag: ^bool, ms: int) -> bool {
	for _ in 0..<ms / 5 {
		if sync.atomic_load(flag) do return true
		time.sleep(5 * time.Millisecond)
	}
	return sync.atomic_load(flag)
}

@(private = "file")
_wait_socket :: proc(path: string) {
	for _ in 0..<400 {
		if ipc.ipc_probe(path) == .None do return
		time.sleep(5 * time.Millisecond)
	}
}

contains :: proc(s, sub: string) -> bool {
	for i := 0; i + len(sub) <= len(s); i += 1 do if s[i:i + len(sub)] == sub do return true
	return false
}

pid_alive :: proc(pid: u32) -> bool {
	return pid > 0 && posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK
}

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
	os.set_env(ipc.SESSION_DIR_ENV, t.dir)
	os.set_env("TERM_HOLDER_NO_CORE", "1")
	os.set_env("TERM_HOLDER_GRACE_MS", "100")
	os.set_env("TERM_CORE_GRACE_MS", "100")
	buf: [64]u8
	_, _ = ipc.ipc_session_dir(buf[:]) // creates the dir 0700
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

// cli_conn is a `term session` style link: HELLO done, synchronous frames.
cli_conn :: proc(conn: ^ipc.Stream_Conn) -> bool {
	fd, ok := client.client_dial(.Cli, false)
	return ok && ipc.stream_conn_init(conn, fd, 0)
}

// cli_list returns the SESSIONS payload reader (positioned after the count).
cli_list :: proc(conn: ^ipc.Stream_Conn) -> (r: ipc.Wire_Reader, count: int, ok: bool) {
	ipc.stream_send(conn, ipc.MSG_LIST, 0)
	for {
		f, got := client.client_wait_frame(conn, 3000)
		if !got do return
		if f.kind != ipc.MSG_SESSIONS do continue
		r = ipc.wire_reader(f.payload)
		count = int(ipc.wr_u32(&r))
		return r, count, r.ok
	}
}

cli_list_ids :: proc(out: []u32) -> []u32 {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return nil
	defer ipc.stream_conn_destroy(&conn)
	r, count, ok := cli_list(&conn)
	n := 0
	for _ in 0..<count {
		if !ok || n == len(out) do break
		out[n] = ipc.dec_row(&r).id
		n += 1
	}
	return out[:n]
}

cli_list_rows :: proc(out: []ipc.Session_Row) -> []ipc.Session_Row {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return nil
	defer ipc.stream_conn_destroy(&conn)
	r, count, ok := cli_list(&conn)
	n := 0
	for _ in 0..<count {
		if !ok || n == len(out) do break
		out[n] = ipc.dec_row(&r)
		n += 1
	}
	return out[:n]
}

// cli_wait_rows waits until a core lists a row: a fresh core has to adopt the
// holder's sessions first, so a single LIST right after it starts can be empty.
cli_wait_rows :: proc(out: []ipc.Session_Row, ms := 3000) -> []ipc.Session_Row {
	for _ in 0..<ms / 10 {
		if n := cli_list_rows(out); len(n) > 0 do return n
		time.sleep(10 * time.Millisecond)
	}
	return cli_list_rows(out)
}

// cli_kill: true = the core answered OK.
cli_kill :: proc(id: u32) -> bool {
	conn: ipc.Stream_Conn
	if !cli_conn(&conn) do return false
	defer ipc.stream_conn_destroy(&conn)
	b: [4]u8
	w := ipc.wire_writer(b[:])
	ipc.ww_u32(&w, id)
	ipc.stream_send(&conn, ipc.MSG_KILL, 0, b[:])
	for {
		f, got := client.client_wait_frame(&conn, 3000)
		if !got || f.kind == ipc.MSG_FAIL do return false
		if f.kind == ipc.MSG_OK do return true
	}
}

contains :: proc(s, sub: string) -> bool {
	for i := 0; i + len(sub) <= len(s); i += 1 do if s[i:i + len(sub)] == sub do return true
	return false
}

pid_alive :: proc(pid: u32) -> bool {
	return pid > 0 && posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK
}

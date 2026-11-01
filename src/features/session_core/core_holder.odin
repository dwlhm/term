package feature_session_core

// Holder links: find and adopt running holders, start one of our build,
// and turn holder frames into session state.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import ipc "../../platform/ipc"

HOLDER_PREFIX :: "h."

// core_adopt_holders connects to every holder socket in the session dir.
// A socket nobody answers on is stale and removed.
core_adopt_holders :: proc(c: ^Core) {
	dir, err := os.open(c.dir)
	if err != nil do return
	defer os.close(dir)
	entries, _ := os.read_dir(dir, -1, context.temp_allocator)
	for e in entries {
		if !strings.has_prefix(e.name, HOLDER_PREFIX) || !strings.has_suffix(e.name, ".sock") do continue
		buf: [256]u8
		path, ok := ipc.ipc_session_path(buf[:], c.dir, e.name)
		if !ok do continue
		if !_holder_connect(c, path) && ipc.ipc_probe(path) == .Not_Running {
			_unlink_socket(path)
		}
	}
	free_all(context.temp_allocator)
	// Settle the handshakes so adopted sessions exist before viewers arrive.
	deadline := _now() + 2 * 1_000_000_000
	for _core_unwelcomed(c) && _now() < deadline do _core_step(c)
}

core_current_holder :: proc(c: ^Core) -> int {
	for &h, i in c.holders do if h.used && h.welcomed && h.current do return i
	return -1
}

// core_start_holder starts `term --holder <dir>/h.<id>.sock` detached and links to it.
core_start_holder :: proc(c: ^Core) -> bool {
	name_buf, path_buf, log_buf: [256]u8
	name := fmt.bprintf(name_buf[:], "%s%08x.sock", HOLDER_PREFIX, u32(_now()) ~ u32(posix.getpid()))
	path, ok := ipc.ipc_session_path(path_buf[:], c.dir, name)
	log_path := ipc.ipc_log_path(log_buf[:], "holder.log")
	if !ok || !ipc.ipc_spawn_self_detached({"--holder", path}, log_path) do return false
	deadline := _now() + 3 * 1_000_000_000
	for _now() < deadline {
		if _holder_connect(c, path) do break
		time.sleep(20 * time.Millisecond)
	}
	for core_current_holder(c) < 0 && _core_unwelcomed(c) && _now() < deadline do _core_step(c)
	return core_current_holder(c) >= 0
}

@(private = "file")
_core_unwelcomed :: proc(c: ^Core) -> bool {
	for &h in c.holders do if h.used && !h.welcomed do return true
	return false
}

@(private = "file")
_holder_connect :: proc(c: ^Core, path: string) -> bool {
	slot := -1
	for &h, i in c.holders do if !h.used { slot = i; break }
	if slot < 0 do return false
	fd, err := ipc.ipc_connect(path, 500)
	if err != .None do return false
	h := &c.holders[slot]
	h^ = {used = true}
	if !ipc.stream_conn_init(&h.conn, fd, CORE_HOLDER_CTL) {
		_holder_drop(c, slot)
		return false
	}
	w := ipc.wire_writer(c.msg)
	ipc.enc_hello(&w, {version = ipc.STREAM_PROTO_VERSION, role = .Core, build = c.build})
	ipc.stream_send(&h.conn, ipc.MSG_HELLO, 0, ipc.wire_bytes_written(&w))
	return true
}

@(private = "file")
_unlink_socket :: proc(path: string) {
	cbuf: [256]u8
	copy(cbuf[:], path)
	posix.unlink(cstring(raw_data(cbuf[:])))
}

// core_holder_send queues one frame for a session's holder (dropped if the holder is gone).
core_holder_send :: proc(c: ^Core, holder: int, kind: u8, id: u32, parts: ..[]u8) {
	if holder < 0 || !c.holders[holder].used do return
	ipc.stream_send(&c.holders[holder].conn, kind, id, ..parts)
}

core_holder_service :: proc(c: ^Core, i: int, rev: posix.Poll_Event) {
	h := &c.holders[i]
	if .OUT in rev do ipc.stream_flush(&h.conn)
	gone := ipc.stream_fill(&h.conn) != .None
	for f in ipc.stream_next(&h.conn) {
		if !_holder_frame(c, i, f) {
			gone = true
			break
		}
	}
	if gone || h.conn.err == .Bad_Frame || h.conn.err == .Overflow do _holder_drop(c, i)
}

// _holder_frame applies one holder frame; false = the holder broke protocol.
@(private = "file")
_holder_frame :: proc(c: ^Core, hi: int, f: ipc.Stream_Frame) -> bool {
	r := ipc.wire_reader(f.payload)
	switch f.kind {
	case ipc.MSG_HELLO:
		_, _, ok := ipc.stream_hello_check(f.payload, {.Holder})
		return ok
	case ipc.MSG_WELCOME:
		return _holder_welcome(c, hi, &r)
	case ipc.MSG_TAIL:
		if s := core_session_find(c, f.channel); s != nil do core_session_adopt_tail(c, s, f.payload)
	case ipc.MSG_OUTPUT:
		if s := core_session_find(c, f.channel); s != nil do core_session_output(c, s, f.payload)
	case ipc.MSG_SPAWNED:
		if s := core_session_find(c, f.channel); s != nil do core_session_spawned(c, s, i32(ipc.wr_u32(&r)))
	case ipc.MSG_SPAWN_FAILED:
		if s := core_session_find(c, f.channel); s != nil do core_session_exited(c, s, {code = 127}, string(f.payload))
	case ipc.MSG_EXITED:
		exit := ipc.dec_exit(&r)
		if s := core_session_find(c, f.channel); s != nil && r.ok do core_session_exited(c, s, exit, "")
	case ipc.MSG_PROC_INFO:
		info := ipc.dec_proc_info(&r)
		if s := core_session_find(c, f.channel); s != nil && r.ok do core_session_proc_info(c, s, info)
	case ipc.MSG_BYE:
		return false
	}
	return true
}

@(private = "file")
_holder_welcome :: proc(c: ^Core, hi: int, r: ^ipc.Wire_Reader) -> bool {
	h := &c.holders[hi]
	wel := ipc.dec_welcome(r)
	if !r.ok || wel.version != ipc.STREAM_PROTO_VERSION do return false
	h.welcomed, h.instance, h.current = true, wel.instance, wel.build == c.build
	// Another build keeps what it runs, takes nothing new and exits when empty.
	if !h.current do ipc.stream_send(&h.conn, ipc.MSG_DRAIN, 0)
	for _ in 0..<wel.count {
		held := ipc.dec_held(r)
		if !r.ok do return false
		core_session_adopt(c, hi, held)
	}
	return true
}

// _holder_drop: a holder that is gone took its programs with it.
@(private = "file")
_holder_drop :: proc(c: ^Core, hi: int) {
	for &s in c.sessions {
		if s.used && s.holder == hi {
			s.holder = -1
			if !s.exited do core_session_exited(c, &s, {code = -1}, "holder lost")
		}
	}
	ipc.stream_conn_destroy(&c.holders[hi].conn)
	c.holders[hi] = {}
}

// core_shutdown_holders: the last session and viewer are gone; holders exit too.
core_shutdown_holders :: proc(c: ^Core) {
	mode := [1]u8{u8(ipc.Goodbye.Shutdown)}
	for &h in c.holders {
		if !h.used do continue
		ipc.stream_send(&h.conn, ipc.MSG_GOODBYE, 0, mode[:])
		deadline := _now() + 1_000_000_000
		for ipc.stream_wants_write(&h.conn) && h.conn.err == .None && _now() < deadline {
			ipc.stream_flush(&h.conn)
			time.sleep(5 * time.Millisecond)
		}
	}
}

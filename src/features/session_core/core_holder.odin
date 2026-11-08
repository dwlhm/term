package feature_session_core

// Holder links: find and adopt running holders, start one of our build,
// and turn holder frames into session state.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import proto "../session_proto"
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
		path, ok := proto.session_path(buf[:], c.dir, e.name)
		if !ok do continue
		if !_holder_connect(c, path) && !ipc.endpoint_alive(_endpoint(path)) do _unlink_socket(path)
	}
	free_all(context.temp_allocator)
	// Settle the handshakes so adopted sessions exist before viewers arrive.
	deadline := _now() + 2 * 1_000_000_000
	for _core_unwelcomed(c) && _now() < deadline do _core_step(c)
	core_sweep_snapshots(c)
	core_endpoints_restore(c)
	core_restore_broker(c)
}

core_current_holder :: proc(c: ^Core) -> int {
	for &h, i in c.holders do if h.used && h.welcomed && h.current do return i
	return -1
}

// core_start_holder starts `term --holder <dir>/h.<id>.sock` detached and links to it.
core_start_holder :: proc(c: ^Core) -> bool {
	name_buf, path_buf, log_buf: [256]u8
	name := fmt.bprintf(name_buf[:], "%s%08x.sock", HOLDER_PREFIX, u32(_now()) ~ u32(posix.getpid()))
	path, ok := proto.session_path(path_buf[:], c.dir, name)
	log_path := proto.log_path(log_buf[:], "holder.log")
	if !ok || !proto.spawn_self({"--holder", path}, log_path) do return false
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
	h := &c.holders[slot]
	h^ = {used = true}
	h.path_len = copy(h.path_buf[:], path)
	if err := ipc.link_dial(&h.link, _endpoint(path), proto.holder(), u8(proto.Stream_Role.Core), &c.set, {backlog = CORE_HOLDER_CTL}); err.kind != .None {
		h^ = {}
		return false
	}
	return true
}

// _endpoint: a holder socket path as dir + name.
@(private = "file")
_endpoint :: proc(path: string) -> ipc.Endpoint {
	slash := strings.last_index_byte(path, '/')
	return {path[:max(slash, 0)], path[slash + 1:]}
}

@(private = "file")
_unlink_socket :: proc(path: string) {
	cbuf: [256]u8
	copy(cbuf[:], path)
	posix.unlink(cstring(raw_data(cbuf[:])))
}

// core_holder_send queues one frame for a session's holder (dropped if the
// holder is gone; one whose backlog overflows is dropped after this round).
core_holder_send :: proc(c: ^Core, holder: int, kind: u8, id: u32, parts: ..[]u8) {
	if holder < 0 || !c.holders[holder].used do return
	h := &c.holders[holder]
	if !h.broken && !ipc.link_send(&h.link, kind, id, ..parts) do h.broken = true
}

// core_holder_events handles what a holder link reported after a wait.
core_holder_events :: proc(c: ^Core, i: int) {
	h := &c.holders[i]
	for ev in ipc.link_next(&h.link) {
		switch e in ev {
		case ipc.Link_Up: // its WELCOME follows
		case ipc.Link_Down:
			_holder_drop(c, i)
			return
		case ipc.Link_Frame:
			if !_holder_frame(c, i, e) {
				_holder_drop(c, i)
				return
			}
		}
	}
	if h.broken do _holder_drop(c, i)
}

// _holder_frame applies one holder frame; false = the holder broke protocol.
@(private = "file")
_holder_frame :: proc(c: ^Core, hi: int, f: ipc.Link_Frame) -> bool {
	r := ipc.wire_reader(f.body)
	switch f.kind {
	case proto.MSG_WELCOME:
		return _holder_welcome(c, hi, &r)
	case proto.MSG_TAIL:
		if s := core_session_find(c, f.channel); s != nil do core_session_adopt_tail(c, s, f.body)
	case proto.MSG_OUTPUT:
		if s := core_session_find(c, f.channel); s != nil do core_session_output(c, s, f.body)
	case proto.MSG_SPAWNED:
		pid := i32(ipc.wr_u32(&r))
		started_unix := i64(ipc.wr_u64(&r))
		if s := core_session_find(c, f.channel); s != nil && r.ok {
			core_session_spawned(c, s, pid, started_unix)
		}
	case proto.MSG_SPAWN_FAILED:
		if s := core_session_find(c, f.channel); s != nil do core_session_exited(c, s, {code = 127}, string(f.body))
	case proto.MSG_EXITED:
		exit := proto.dec_exit(&r)
		if s := core_session_find(c, f.channel); s != nil && r.ok do core_session_exited(c, s, exit, "")
	case proto.MSG_PROC_INFO:
		info := proto.dec_proc_info(&r)
		if s := core_session_find(c, f.channel); s != nil && r.ok do core_session_proc_info(c, s, info)
	case proto.MSG_BYE:
		return false
	}
	return true
}

@(private = "file")
_holder_welcome :: proc(c: ^Core, hi: int, r: ^ipc.Wire_Reader) -> bool {
	h := &c.holders[hi]
	wel := proto.dec_welcome(r)
	if !r.ok || wel.version != proto.STREAM_PROTO_VERSION do return false
	h.welcomed, h.instance, h.current = true, wel.instance, wel.build == c.build
	h.poisoned = wel.previous == 2 && wel.crashes >= CORE_POISON_CRASHES
	h.handover = wel.previous == 1
	if h.poisoned do fmt.eprintfln("core: %d core crashes in 5 min: screens start empty (tails not replayed)", wel.crashes)
	// Another build keeps what it runs, takes nothing new and exits when empty.
	if !h.current do core_holder_send(c, hi, proto.MSG_DRAIN, 0)
	for _ in 0..<wel.count {
		held := proto.dec_held(r)
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
	h := &c.holders[hi]
	ipc.link_close(&h.link)
	// A holder killed outright leaves its socket; nobody answers there any more.
	path := string(h.path_buf[:h.path_len])
	if len(path) > 0 && !ipc.endpoint_alive(_endpoint(path)) do _unlink_socket(path)
	h^ = {}
}

// core_shutdown_holders: the last session and viewer are gone; holders exit too.
core_shutdown_holders :: proc(c: ^Core) { core_holders_goodbye(c, .Shutdown) }

// core_holders_goodbye tells every holder how this core leaves and gives the
// links up to 1 s to write it. Only the holder links move from here on:
// nothing the session Server takes in is served any more.
core_holders_goodbye :: proc(c: ^Core, mode: proto.Goodbye) {
	b := [1]u8{u8(mode)}
	for &h, i in c.holders do if h.used do core_holder_send(c, i, proto.MSG_GOODBYE, 0, b[:])
	deadline := _now() + 1_000_000_000
	for _now() < deadline {
		queued := 0
		for &h in c.holders do if h.used do queued += ipc.link_backlog(&h.link)
		if queued == 0 do return
		ipc.poll_set_wait(&c.set, deadline)
	}
}

package feature_session_core

// Planned restart (SIGTERM: an update, `make install`): every screen is saved
// as a paint (terminal_paint + OSC 7501) and the holders are told GOODBYE
// Handover, so they drop their tails. The next core restores each screen from
// its snapshot, replays only what the program printed since and answers it
// (nobody did), with no resize nudge. Without a snapshot it takes the crash path.

import "core:fmt"
import "core:os"
import terminal "../../core/terminal"
import extension "../../core/terminal/extension"
import proto "../session_proto"
import ipc "../../platform/ipc"

CORE_SNAPSHOT_HISTORY :: 10_000 // scrollback lines kept across a planned restart
CORE_BROKER_SNAPSHOT  :: "snap.broker"

core_handover :: proc(c: ^Core) {
	for &s in c.sessions {
		if !s.used || s.exited || s.endpoint.used do continue
		terminal.relay_flush(&s.relay, &s.sess.term)
		terminal.terminal_paint(&s.sess.term, &c.paint, CORE_SNAPSHOT_HISTORY)
		extension.osc_7501_encode(&s.sess.program_status, &c.paint)
		path_buf: [256]u8
		if path, ok := _snapshot_path(c, path_buf[:], s.id); ok do _write_atomic(path, c.paint[:])
	}
	core_endpoints_save(c)
	_save_broker(c)
	core_holders_goodbye(c, .Handover)
}

// core_restore_snapshot feeds a saved screen into a fresh Terminal (its
// replies were answered before the restart) and removes the file. false = none.
core_restore_snapshot :: proc(c: ^Core, s: ^Core_Session) -> bool {
	path_buf: [256]u8
	path, ok := _snapshot_path(c, path_buf[:], s.id)
	if !ok do return false
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return false
	defer delete(data)
	os.remove(path)
	terminal.terminal_feed_bytes(&s.sess.term, data)
	for terminal.terminal_drain_response(&s.sess.term, c.msg[:4096]) > 0 {}
	_ = terminal.terminal_consume_damage(&s.sess.term)
	return true
}

// core_sweep_snapshots removes snapshots no adopted session will claim
// (their program ended between the handover and this core's start).
core_sweep_snapshots :: proc(c: ^Core) {
	dir, err := os.open(c.dir)
	if err != nil do return
	defer os.close(dir)
	entries, _ := os.read_dir(dir, -1, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for e in entries {
		id: u32
		if !_parse_snapshot_name(e.name, &id) || core_session_find(c, id) != nil do continue
		path_buf: [256]u8
		if path, ok := _snapshot_path(c, path_buf[:], id); ok do os.remove(path)
	}
}

@(private = "file")
_parse_snapshot_name :: proc(name: string, id: ^u32) -> bool {
	if len(name) < len("snap.0.vt") || name[:5] != "snap." || name[len(name) - 3:] != ".vt" do return false
	n: u32
	for ch in name[5:len(name) - 3] {
		if ch < '0' || ch > '9' do return false
		n = n * 10 + u32(ch - '0')
	}
	id^ = n
	return n > 0
}

@(private = "file")
_snapshot_path :: proc(c: ^Core, buf: []u8, id: u32) -> (string, bool) {
	name_buf: [32]u8
	return proto.session_path(buf, c.dir, fmt.bprintf(name_buf[:], "snap.%d.vt", id))
}

// _write_atomic writes temp + rename, mode 0600: a restart interrupted
// mid-write never leaves half a file behind.
@(private = "file")
_write_atomic :: proc(path: string, data: []u8) {
	tmp_buf: [256]u8
	tmp := fmt.bprintf(tmp_buf[:], "%s.tmp", path)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil do return
	_, werr := os.write(f, data)
	os.close(f)
	if werr == nil do _ = os.rename(tmp, path)
	else do os.remove(tmp)
}

@(private = "file")
_save_broker :: proc(c: ^Core) {
	path_buf: [256]u8
	path, ok := proto.session_path(path_buf[:], c.dir, CORE_BROKER_SNAPSHOT)
	if !ok do return
	buf := make([]u8, CORE_MAX_REQUESTS * (BROKER_BODY_CAP + BROKER_TEXT_CAP + 128) + CORE_MAX_SESSIONS * 16 + 64)
	defer delete(buf)
	w := ipc.wire_writer(buf)
	broker_encode(&c.broker, &w)
	if w.ok do _write_atomic(path, ipc.wire_bytes_written(&w))
}

// core_restore_broker picks up the requests the last core left (once every
// holder's sessions are adopted): sides whose session is gone end, and
// blocking tells lost their connection with the old core.
core_restore_broker :: proc(c: ^Core) {
	path_buf: [256]u8
	path, ok := proto.session_path(path_buf[:], c.dir, CORE_BROKER_SNAPSHOT)
	if !ok do return
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return
	defer delete(data)
	os.remove(path)
	r := ipc.wire_reader(data)
	if !broker_decode(&c.broker, &r) {
		broker_destroy(&c.broker)
		broker_init(&c.broker, _now)
		return
	}
	for &q in c.broker.reqs {
		if q.phase == .Free || q.phase == .Spent do continue
		for sid in ([2]u32{q.to, q.from}) do if sid != 0 && core_session_find(c, sid) == nil do core_broker_session_gone(c, sid, 0)
	}
	for &p in c.broker.parties {
		if p.sid != 0 && core_session_find(c, p.sid) == nil do core_broker_session_gone(c, p.sid, 0)
	}
	for vi in 0..<CORE_MAX_VIEWERS {
		broker_viewer_gone(&c.broker, vi)
		core_broker_apply(c)
	}
}

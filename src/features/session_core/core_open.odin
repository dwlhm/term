package feature_session_core

// Opening and leaving the core's socket: the session Server in the session
// dir, and removing a private session dir once the last tier is gone.

import "core:os"
import "core:sys/posix"
import "core:time"
import proto "../session_proto"
import ipc "../../platform/ipc"

// _remove_private_dir: a private session (TERM_SESSION_DIR) ends with its last
// tier. rmdir only succeeds once the holder removed its socket (empty dir).
@(private)
_remove_private_dir :: proc(c: ^Core) {
	env: [256]u8
	if v, _ := os.lookup_env(env[:], proto.SESSION_DIR_ENV); len(v) == 0 do return
	ipc.server_close(&c.srv)
	cbuf: [256]u8
	copy(cbuf[:len(cbuf) - 1], c.dir)
	for _ in 0..<50 {
		if posix.rmdir(cstring(raw_data(cbuf[:]))) == .OK do return
		time.sleep(20 * time.Millisecond)
	}
}

// core_listen opens the session Server on c.set; .Already_Running = another
// core serves this session dir.
core_listen :: proc(c: ^Core) -> ipc.Error {
	err: ipc.Error
	if c.dir, err = proto.session_dir(c.dir_buf[:]); err.kind != .None do return err
	return ipc.server_open(&c.srv, {c.dir, proto.CORE_SOCKET}, proto.session(), &c.set, {max_peers = CORE_MAX_VIEWERS, busy_reason = CORE_BUSY_REASON})
}

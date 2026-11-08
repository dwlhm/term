package feature_session_core

// Opening and leaving the core's socket: listening in the session dir (the
// listener is a watched fd until M3) and removing a private session dir
// once the last tier is gone.

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
	ipc.poll_set_unwatch(&c.set, c.listen_watch)
	posix.close(c.listen_fd)
	ipc.ipc_unlink_if_ours(c.sock, c.listen_ino)
	c.listen_fd, c.listen_watch = -1, 0
	cbuf: [256]u8
	copy(cbuf[:len(cbuf) - 1], c.dir)
	for _ in 0..<50 {
		if posix.rmdir(cstring(raw_data(cbuf[:]))) == .OK do return
		time.sleep(20 * time.Millisecond)
	}
}

@(private)
_core_listen :: proc(c: ^Core) -> bool {
	c.listen_fd = -1
	err: ipc.Ipc_Error
	if c.dir, err = proto.session_dir(c.dir_buf[:]); err != .None do return false
	ok: bool
	if c.sock, ok = proto.session_path(c.sock_buf[:], c.dir, CORE_SOCKET_NAME); !ok do return false
	c.listen_fd, c.listen_ino, err = ipc.ipc_bind_listener(c.sock)
	if err == .Already_Running do c.listen_fd = -2
	if err != .None do return false
	id, werr := ipc.poll_set_watch(&c.set, c.listen_fd, _accept_viewers, c)
	c.listen_watch = id
	return werr.kind == .None
}

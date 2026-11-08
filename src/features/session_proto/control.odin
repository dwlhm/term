package feature_session_proto

// The control socket (term show|quit, session attach) on platform/ipc: a
// Server{.Line} (IPC spec 7.6) — one line in, one answer out, then close.
// A .Line protocol needs no catalog and no version, so the package never
// resolves either. control_endpoint splits ctl_socket_path so the package
// validates the dir: $TERM_CTL_SOCK is no longer used unchecked (gap G6).

import ipc "../../platform/ipc"

// CONTROL_MAX_REPLY is a line client's reply buffer; a longer answer comes
// back from the package as "err too_large\n".
CONTROL_MAX_REPLY :: 4096

// control: the control socket's protocol; its name is all a .Line server uses.
control :: proc() -> ipc.Protocol {
	return {name = "term control"}
}

// control_endpoint: ctl_socket_path split into {dir, name} at the last '/'.
// A path the OS cannot use is .Unsafe_Path; the caller passes the endpoint to
// the package, which validates dir (ours, no symlink, closed to others).
control_endpoint :: proc(buf: []u8) -> (at: ipc.Endpoint, err: ipc.Error) {
	path, perr := ctl_socket_path(buf)
	if perr != .None {
		return {}, {kind = .Unsafe_Path, reason = "the control socket path is not usable"}
	}
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] == '/' do return {dir = path[:i], name = path[i + 1:]}, {}
	}
	return {}, {kind = .Unsafe_Path, reason = "the control socket path has no directory"}
}

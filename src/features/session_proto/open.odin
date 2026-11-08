package feature_session_proto

// Opening the session link: the core's endpoint in the session dir, and an
// ipc.Client that starts a core (`<this executable> --core`) when none runs.

import ipc "../../platform/ipc"

CORE_SOCKET :: "core.sock"
CORE_LOG    :: "core.log"

// session_endpoint: core.sock in the session dir; dir lives in buf.
session_endpoint :: proc(buf: []u8) -> (ipc.Endpoint, ipc.Error) {
	dir, err := session_dir(buf)
	return {dir, CORE_SOCKET}, err
}

// session_open connects c to the session core with role; start = start a
// core when none runs (otherwise .No_Server).
session_open :: proc(c: ^ipc.Client, role: Stream_Role, start := true) -> ipc.Error {
	dir_buf, log_buf: [256]u8
	at, err := session_endpoint(dir_buf[:])
	if err.kind != .None do return err
	opts := ipc.Client_Opts{role = u8(role)}
	if start {
		opts.start = {"", "--core"}
		opts.log = log_path(log_buf[:], CORE_LOG)
	}
	return ipc.client_open(c, at, session(), opts)
}

// error_text: what a person reads when the session link fails.
error_text :: proc(err: ipc.Error) -> string {
	#partial switch err.kind {
	case .No_Server:     return "no session is running"
	case .Timeout:       return "the session core did not answer"
	case .Closed:        return "the session core went away"
	case .Start_Failed:  return "cannot start the session core (see $TMPDIR/term-<uid>/core.log)"
	case .Handshake:     return "the session core did not complete the handshake (is it from another term build?)"
	}
	return err.reason if err.reason != "" else ipc.error_message(err)
}

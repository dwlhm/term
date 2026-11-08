package platform_ipc

// Public API of the IPC package: what an application gives (Protocol,
// Endpoint) and the one error type every call returns. Client, Server, Link
// and Poll_Set hold an opaque handle: Odin's @(private) hides a type's name
// but not its fields, so state lives behind a rawptr only this package can
// cast. A zero handle is closed.
//
// The package knows nothing about term: no env names, socket names, message
// kinds or user-facing text. Contract and tests: the approved IPC spec
// (https://claude.ai/artifact/8ztwThM4isrBNXBhACvBcz, sections 7 and 8).

// Version is a wire version. Before 1.0 a peer must match major and minor;
// from 1.0 on, major only. Sent in HELLO as major<<16 | minor<<8 | patch.
Version :: struct {
	major, minor, patch: u8,
}

Protocol :: struct {
	name:       string,           // in errors and logs, e.g. "term session"
	version:    Version,
	roles:      bit_set[0 ..< 64], // roles (application u8s) a server lets in
	catalog:    []Msg_Spec,       // empty for a Link; required by Server and Client
	hello_kind: u8,               // 0 = 3
	fail_kind:  u8,               // 0 = 4
}

// Msg_Spec: one request kind on channel 0 and the only answers it may get.
Msg_Spec :: struct {
	request:  u8,
	answer:   u8,   // the one valid final answer kind
	progress: u8,   // kind of progress answers; 0 = none
	notice:   bool, // a server → all notice (req 0), not a request
}

// Endpoint: the socket is dir/name. dir is always validated: owned by us,
// not a symlink, no group/other bits. There is no way to skip that.
Endpoint :: struct {
	dir:  string,
	name: string,
}

Error :: struct {
	kind:   Error_Kind,
	code:   u8,     // .Failed: the peer's FAIL code (reserved or the application's)
	reason: string, // from the peer or the package; temp_allocator
}

Error_Kind :: enum u8 {
	None,
	Unsafe_Path,     // the endpoint dir is not private to us
	Unsafe_Peer,     // the other side runs as another uid
	Bad_Protocol,    // catalog with duplicate or reserved kinds, or answer 0
	Bad_Opts,        // a limit out of its range
	No_Server,       // nothing listens and the client was not asked to start one
	Start_Failed,    // a started server did not accept in time
	Busy,            // every connection slot is in use
	Version,         // reason names both versions
	Handshake,       // no valid HELLO in time
	Failed,          // the peer answered FAIL (see code)
	Timeout,         // no answer before the deadline
	Closed,          // the connection ended, a frame was malformed, or the peer stopped reading
	Interrupted,     // client_interrupt, or on_event returned .Stop
	Bad_Reply,       // an answer for our req whose kind is not in the catalog
	Listener_Broken, // the server or link can no longer accept
	Not_Implemented, // only while the API is a skeleton (spec section 10); removed in I5
}

// FAIL codes the package uses itself; applications use any other non-zero code.
FAIL_BAD_REQUEST :: u8(3)
FAIL_BUSY        :: u8(5)
FAIL_VERSION     :: u8(6)
FAIL_TIMEOUT     :: u8(7)

// error_message is generic English text without the application's name.
error_message :: proc(e: Error) -> string {
	switch e.kind {
	case .None:            return "no error"
	case .Unsafe_Path:     return "the socket directory is not private"
	case .Unsafe_Peer:     return "the other side runs as another user"
	case .Bad_Protocol:    return "the protocol description is invalid"
	case .Bad_Opts:        return "an option is out of range"
	case .No_Server:       return "nothing is listening"
	case .Start_Failed:    return "the server could not be started"
	case .Busy:            return "the server is busy"
	case .Version:         return "the two sides speak different protocol versions"
	case .Handshake:       return "the handshake did not complete"
	case .Failed:          return "the request failed"
	case .Timeout:         return "no answer in time"
	case .Closed:          return "the connection closed"
	case .Interrupted:     return "interrupted"
	case .Bad_Reply:       return "the answer does not fit the protocol"
	case .Listener_Broken: return "the listening socket broke"
	case .Not_Implemented: return "not implemented"
	}
	return "unknown error"
}

// private_dir: "$TMPDIR/<app>-<uid>" (or /tmp), created 0700 when missing,
// then validated like any Endpoint dir.
private_dir :: proc(buf: []u8, app: string) -> (dir: string, err: Error) {
	return _private_dir(buf, app)
}

@(private)
_not_implemented :: proc "contextless" () -> Error { return {kind = .Not_Implemented} }

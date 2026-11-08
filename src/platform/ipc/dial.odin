package platform_ipc

// _dial connects to path (bounded by _DIAL_MS) and checks that the other
// side runs as our uid (a second line behind the private dir, spec G7).

import "core:fmt"
import "core:sys/posix"

@(private)
_DIAL_MS :: 500

@(private)
_dial :: proc(path: string) -> (fd: posix.FD, err: Error) {
	e: Ipc_Error
	fd, e = ipc_connect(path, _DIAL_MS)
	#partial switch e {
	case .None:
	case .Not_Running: return -1, {kind = .No_Server, reason = fmt.tprintf("nothing listens at %s", path)}
	case .Path_Too_Long: return -1, {kind = .Unsafe_Path, reason = fmt.tprintf("%s is too long for a unix socket", path)}
	case .Busy: return -1, {kind = .Busy, reason = fmt.tprintf("%s does not accept", path)}
	case: return -1, {kind = .No_Server, reason = fmt.tprintf("cannot connect to %s", path)}
	}
	uid, ok := ipc_peer_uid(fd)
	if !ok || uid != posix.getuid() {
		posix.close(fd)
		return -1, {kind = .Unsafe_Peer, reason = fmt.tprintf("%s is served by another user", path)}
	}
	return fd, {}
}

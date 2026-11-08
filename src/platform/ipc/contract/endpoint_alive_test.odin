package platform_ipc_contract

// P41 (M5): endpoint_alive tells a socket someone accepts on from one left
// behind by a process that died (so its owner may remove it). A listener
// that is merely slow to accept is never reported dead.

import "core:fmt"
import "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../"

@(test)
test_P41_endpoint_alive :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	testing.expect(t, !ipc.endpoint_alive({dir, "none"}), "no socket file: not alive")
	o: Owner
	if !owner_open(t, &o, {dir, "s"}) do return
	testing.expect(t, ipc.endpoint_alive({dir, "s"}), "a listening Server is alive")
	owner_close(&o)
	testing.expect(t, !ipc.endpoint_alive({dir, "s"}), "after server_close: not alive")
	_stale_socket(t, dir, "stale")
	testing.expect(t, !ipc.endpoint_alive({dir, "stale"}), "a socket file nobody listens on: not alive")
	testing.expect(t, !ipc.endpoint_alive({"/tmp", "x"}), "an unsafe dir is never probed")
}

// _stale_socket binds dir/name and closes it without unlinking, as a killed process leaves it.
@(private = "file")
_stale_socket :: proc(t: ^testing.T, dir, name: string) {
	addr := posix.sockaddr_un{sun_family = .UNIX}
	path := fmt.tprintf("%s/%s", dir, name)
	copy(([^]u8)(&addr.sun_path[0])[:len(addr.sun_path) - 1], path)
	fd := posix.socket(.UNIX, .STREAM)
	ok := fd >= 0 && posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK
	testing.expect(t, ok, "bind the stale socket")
	posix.close(fd)
}

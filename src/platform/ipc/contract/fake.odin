package platform_ipc_contract

// Fake_Server: a raw listener on a thread of its own that does HELLO the way
// a Server does (spec 7.10) and then hands every frame from its one client
// to answer, for tests whose server misbehaves on purpose.

import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import ipc "../"

Fake_Server :: struct {
	at:       ipc.Endpoint,
	lfd:      posix.FD,
	answer:   proc(fd: posix.FD, f: Raw_Frame), // nil = never answer
	stopping: bool,                             // atomic
	thread:   ^thread.Thread,
}

fake_open :: proc(t: ^testing.T, fs: ^Fake_Server, at: ipc.Endpoint, loc := #caller_location) -> bool {
	fs.at, fs.lfd = at, raw_listen(at)
	testing.expect(t, fs.lfd >= 0, "fake server: cannot listen", loc = loc)
	if fs.lfd < 0 do return false
	fs.thread = thread.create_and_start_with_poly_data(fs, _fake_loop, context)
	return true
}

fake_close :: proc(fs: ^Fake_Server) {
	if fs.thread == nil do return
	sync.atomic_store(&fs.stopping, true)
	thread.join(fs.thread)
	thread.destroy(fs.thread)
	fs.thread = nil
	posix.close(fs.lfd)
	posix.unlink(cstr(sock_path(fs.at)))
}

@(private = "file")
_fake_loop :: proc(fs: ^Fake_Server) {
	fd := posix.FD(-1)
	defer if fd >= 0 do posix.close(fd)
	buf: [64 * 1024]u8
	for !sync.atomic_load(&fs.stopping) {
		if fd < 0 {
			fd = raw_accept(fs.lfd, 20)
			if fd >= 0 && !_fake_hello(fd) {
				posix.close(fd)
				fd = -1
			}
			continue
		}
		if !raw_wait(fd, 20) do continue
		f, ok := raw_frame(fd, buf[:], 1000)
		if !ok {
			posix.close(fd)
			fd = -1
		} else if fs.answer != nil {
			fs.answer(fd, f)
		}
	}
}

@(private = "file")
_fake_hello :: proc(fd: posix.FD) -> bool {
	buf: [256]u8
	f, ok := raw_frame(fd, buf[:], 1000)
	if !ok || f.kind != HELLO_KIND do return false
	hb: [64]u8
	return raw_send(fd, HELLO_KIND, 0, hello_body(hb[:], TEST_VERSION, 0))
}

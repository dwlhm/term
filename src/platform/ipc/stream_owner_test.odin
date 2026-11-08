package platform_ipc

// Stream_Conn owns exactly one fd: a zero value owns none, destroy closes only
// what init took, a failed init closes what it was given, release hands it back.

import "core:mem"
import "core:sys/posix"
import "core:testing"

@(private = "file")
_is_open :: proc(fd: posix.FD) -> bool { return posix.fcntl(fd, .GETFD) != -1 }

// _with_fd0_on_a_pipe runs body while fd 0 is the read end of a fresh pipe,
// then puts the real stdin back.
@(private = "file")
_with_fd0_on_a_pipe :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	saved := posix.dup(0)
	defer {
		posix.dup2(saved, 0)
		posix.close(saved)
	}
	p: [2]posix.FD
	testing.expect(t, posix.pipe(&p) == .OK)
	defer posix.close(p[1])
	testing.expect(t, posix.dup2(p[0], 0) == 0)
	posix.close(p[0])
	body(t)
}

@(test)
test_P1_zero_conn_keeps_fd_0 :: proc(t: ^testing.T) {
	_with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		conn: Stream_Conn
		stream_conn_destroy(&conn)
		testing.expect(t, _is_open(0), "destroying a zero Stream_Conn closed fd 0")
	})
}

@(test)
test_P2_destroy_twice_spares_a_reused_fd :: proc(t: ^testing.T) {
	sp: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &sp) == .OK)
	defer posix.close(sp[1])
	conn: Stream_Conn
	testing.expect(t, stream_conn_init(&conn, sp[0], 0))
	stream_conn_destroy(&conn)
	p: [2]posix.FD
	testing.expect(t, posix.pipe(&p) == .OK)
	defer { posix.close(p[0]); posix.close(p[1]) }
	testing.expect_value(t, p[0], sp[0]) // the number came back: the case under test
	stream_conn_destroy(&conn)
	testing.expect(t, _is_open(p[0]), "a second destroy closed an fd it no longer owned")
}

@(test)
test_P3_failed_init_owns_nothing :: proc(t: ^testing.T) {
	_with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		p: [2]posix.FD
		testing.expect(t, posix.pipe(&p) == .OK)
		posix.close(p[1])
		bad := p[0]
		posix.close(bad) // a number that is no longer an fd: init must fail
		conn: Stream_Conn
		testing.expect(t, !stream_conn_init(&conn, bad, 0))
		testing.expect(t, !conn.open && conn.in_buf == nil && conn.ctl.buf == nil, "a failed init left state behind")
		stream_conn_destroy(&conn)
		testing.expect(t, _is_open(0), "destroy after a failed init closed fd 0")
	})
}

@(test)
test_P4_release_returns_the_open_fd :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	sp: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &sp) == .OK)
	defer posix.close(sp[1])
	conn: Stream_Conn
	testing.expect(t, stream_conn_init(&conn, sp[0], 0, mem.tracking_allocator(&track)))
	testing.expect(t, stream_channel_open(&conn, 3, true))
	fd := stream_conn_release(&conn)
	defer posix.close(fd)
	testing.expect_value(t, fd, sp[0])
	testing.expect(t, _is_open(fd), "release closed the fd")
	testing.expect(t, !conn.open && conn.in_buf == nil, "release left the conn non-zero")
	testing.expect_value(t, len(track.allocation_map), 0)
	stream_conn_destroy(&conn)
	testing.expect(t, _is_open(fd), "destroy after release closed the fd")
}

package platform_ipc

// Blocking halves of line_call, each bounded by the call's deadline.

import "core:c"
import "core:sys/posix"
import "core:time"

@(private)
_line_wait :: proc(fd: posix.FD, events: posix.Poll_Event, due: i64) -> Error {
	pfd := posix.pollfd{fd = fd, events = events}
	timeout := -1
	if due >= 0 do timeout = int(max(0, (due - time.tick_now()._nsec + 999_999) / 1_000_000))
	for {
		n := posix.poll(&pfd, 1, c.int(timeout))
		if n > 0 do return {}
		if n == 0 do return {kind = .Timeout, reason = "no answer in time"}
		if posix.errno() != .EINTR do return {kind = .Closed, reason = "poll failed"}
	}
}

@(private)
_line_send :: proc(fd: posix.FD, data: []u8, due: i64) -> Error {
	off := 0
	for off < len(data) {
		n := posix.send(fd, raw_data(data[off:]), c.size_t(len(data[off:])), {.NOSIGNAL})
		switch {
		case n > 0:                     off += int(n)
		case posix.errno() == .EINTR:   continue
		case posix.errno() == .EAGAIN:  if err := _line_wait(fd, {.OUT}, due); err.kind != .None do return err
		case:                           return {kind = .Closed, reason = "the server closed before the line was sent"}
		}
	}
	return {}
}

// _line_read_all reads until EOF; more than out holds is .Bad_Reply.
@(private)
_line_read_all :: proc(fd: posix.FD, out: []u8, due: i64) -> (n: int, err: Error) {
	for {
		if err = _line_wait(fd, {.IN}, due); err.kind != .None do return
		if n == len(out) {
			scratch: [1]u8
			if posix.recv(fd, raw_data(scratch[:]), 1, {}) == 0 do return n, {}
			return n, {kind = .Bad_Reply, reason = "the answer does not fit the buffer"}
		}
		got := posix.recv(fd, raw_data(out[n:]), c.size_t(len(out[n:])), {})
		switch {
		case got > 0:                   n += int(got)
		case got == 0:                  return n, {}
		case posix.errno() == .EINTR, posix.errno() == .EAGAIN:
		case:                           return n, {kind = .Closed, reason = "the connection broke"}
		}
	}
}

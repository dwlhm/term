package feature_session_core_tests

// P33, P34: term on top of the IPC package (IPC spec section 8, slice T3),
// written against the new API before term uses it. They stay red until M2
// (P33) and M3 (P34), so they only build with -define:IPC_CONTRACT=true,
// which `make test-ipc-contract` passes; `make test` never runs them.

import "core:fmt"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import proto "../../session_proto"
import ipc "../../../platform/ipc"

IPC_CONTRACT :: #config(IPC_CONTRACT, false)

when IPC_CONTRACT {

// A fake holder socket next to the real one: a starting core dials every
// h.*.sock, so it says HELLO here too. The first frame is kept, then the
// connection closes and the core carries on with the real holder.
@(private = "file")
_Capture :: struct {
	lfd:   posix.FD,
	frame: [512]u8,
	n:     int,
}

@(private = "file")
_capture :: proc(cp: ^_Capture) {
	pfd := posix.pollfd{fd = cp.lfd, events = {.IN}}
	if posix.poll(&pfd, 1, 5000) <= 0 do return
	fd := posix.accept(cp.lfd, nil, nil)
	if fd < 0 do return
	defer posix.close(fd)
	for !_whole_frame(cp.frame[:cp.n]) && cp.n < len(cp.frame) {
		pfd = {fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 2000) <= 0 do return
		got := posix.recv(fd, &cp.frame[cp.n], uint(len(cp.frame) - cp.n), {})
		if got <= 0 do return
		cp.n += int(got)
	}
}

@(private = "file")
_listen_unix :: proc(path: string) -> posix.FD {
	addr: posix.sockaddr_un
	if !ipc.ipc_fill_sockaddr(path, &addr) do return -1
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 4) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(private = "file")
_whole_frame :: proc(b: []u8) -> bool {
	if len(b) < 9 do return false
	r := ipc.wire_reader(b[5:9])
	return len(b) >= 9 + int(ipc.wr_u32(&r))
}

// _hello_0_0_2: the core's HELLO to a holder as term sends it today: kind 10,
// channel 0, version 2 (= 0.0.2), role Core (1), caps 0, build id.
@(private = "file")
_hello_0_0_2 :: proc(buf: []u8) -> []u8 {
	bb: [64]u8
	build := ipc.ipc_build_id(bb[:])
	w := ipc.wire_writer(buf)
	ipc.ww_u8(&w, 10)
	ipc.ww_u32(&w, 0)
	ipc.ww_u32(&w, u32(4 + 1 + 8 + 4 + len(build)))
	ipc.ww_u32(&w, 2)
	ipc.ww_u8(&w, 1)
	ipc.ww_u64(&w, 0)
	ipc.ww_str(&w, build)
	return ipc.wire_bytes_written(&w)
}

@(private = "file")
_listed :: proc(id: u32) -> bool {
	rows: [16]ipc.Session_Row
	for r in cli_wait_rows(rows[:]) do if r.id == id do return true
	return false
}

// _background_session starts a program and leaves it to the holder.
@(private = "file")
_background_session :: proc() -> u32 {
	v := view_open()
	defer view_close(v)
	return view_attached(v, view_sh(v, "sleep 30"))
}

@(test)
test_P33_core_hello_to_a_holder_is_0_0_2_byte_for_byte :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	tiers := tiers_start()
	id := _background_session()
	path := fmt.tprintf("%s/h.fffffffe.sock", tiers.dir)
	cp := _Capture{lfd = _listen_unix(path)}
	testing.expect(t, cp.lfd >= 0, "cannot place a fake holder socket")
	th := thread.create_and_start_with_poly_data(&cp, _capture)
	tiers_core_restart_stop(tiers)
	tiers_core_start(tiers)
	thread.join(th)
	thread.destroy(th)
	posix.close(cp.lfd)
	posix.unlink(fmt.ctprintf("%s", path))
	want: [256]u8
	testing.expect(t, string(cp.frame[:cp.n]) == string(_hello_0_0_2(want[:])), "the core's HELLO to a holder is not 0.0.2 byte for byte")
	testing.expect(t, _listed(id), "the session did not live through the restart")
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

@(test)
test_P33_a_link_dial_is_taken_by_the_holder :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	tiers := tiers_start()
	id := _background_session()
	tiers_core_restart_stop(tiers) // the holder keeps the session with no core
	testing.expect(t, _dial_holder(t, tiers), "the holder did not take a Link with proto.holder()")
	tiers_core_start(tiers)
	testing.expect(t, _listed(id), "the session did not live through the restart")
	testing.expect(t, tiers_stop(tiers), "tiers end and remove the dir")
}

// _dial_holder links to the real holder as a core would; true = Link_Up.
@(private = "file")
_dial_holder :: proc(t: ^testing.T, tiers: ^Tiers) -> (up: bool) {
	set: ipc.Poll_Set
	if err := ipc.poll_set_init(&set, 8); err.kind != .None {
		testing.expectf(t, false, "poll_set_init: %v", err.kind)
		return
	}
	defer ipc.poll_set_destroy(&set)
	l: ipc.Link
	defer ipc.link_close(&l)
	at := ipc.Endpoint{tiers.dir, tiers.hsock[len(tiers.dir) + 1:]}
	if err := ipc.link_dial(&l, at, proto.holder(), u8(ipc.Stream_Role.Core), &set); err.kind != .None {
		testing.expectf(t, false, "link_dial: %v %q", err.kind, err.reason)
		return
	}
	due := time.tick_now()._nsec + 3 * 1_000_000_000
	for !up && time.tick_now()._nsec < due {
		ipc.poll_set_wait(&set, due)
		for ev in ipc.link_next(&l) do if _, is_up := ev.(ipc.Link_Up); is_up do up = true
	}
	return
}

} // when IPC_CONTRACT

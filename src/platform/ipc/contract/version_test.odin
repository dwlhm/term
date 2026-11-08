package platform_ipc_contract

// P20: version matching (before 1.0 major and minor must match, from 1.0
// major only) and how a refusal looks on the wire. P23: client_open with no
// server, with a start that fails, and with two clients racing to start one.

import "core:fmt"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import ipc "../"

@(private = "file")
_Pair :: struct {
	client, server: ipc.Version,
	ok:             bool,
}

@(private = "file")
_pairs := [?]_Pair{
	{{0, 0, 2}, {0, 1, 0}, false},
	{{0, 1, 0}, {0, 1, 1}, true},
	{{1, 2, 0}, {1, 3, 0}, true},
}

@(test)
test_P20_versions_that_match_and_that_do_not :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	for p in _pairs {
		dir := test_dir()
		defer test_dir_remove(dir)
		sp, cp := test_protocol(), test_protocol()
		sp.version, cp.version = p.server, p.client
		o: Owner
		if !owner_open(t, &o, {dir, "s"}, sp) do return
		defer owner_close(&o)
		c: ipc.Client
		err := ipc.client_open(&c, {dir, "s"}, cp, {role = TEST_ROLE_CLIENT})
		defer ipc.client_close(&c)
		what := fmt.tprintf("client %v to server %v", p.client, p.server)
		if p.ok {
			expect_ok(t, err, what)
			continue
		}
		expect_kind(t, err, .Version, what)
		testing.expect_value(t, err.reason, "ipc contract: client 0.0.2, server 0.1.0")
	}
}

@(test)
test_P20_refusal_is_hello_then_fail_version :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	o: Owner
	if !owner_open(t, &o, {dir, "s"}) do return
	defer owner_close(&o)
	fd := raw_dial({dir, "s"})
	if !testing.expect(t, fd >= 0, "cannot connect") do return
	defer posix.close(fd)
	hb: [64]u8
	raw_send(fd, HELLO_KIND, 0, hello_body(hb[:], {0, 0, 2}, TEST_ROLE_CLIENT))
	buf: [256]u8
	f, ok := raw_frame(fd, buf[:], 1000)
	testing.expect(t, ok && f.kind == HELLO_KIND, "a refused peer gets HELLO first")
	expect_fail(t, fd, 0, ipc.FAIL_VERSION)
	testing.expect(t, raw_closed(fd, 1000), "a refused peer is not closed")
}

@(test)
test_P23_no_server_and_no_start :: proc(t: ^testing.T) {
	dir := test_dir()
	defer test_dir_remove(dir)
	c: ipc.Client
	defer ipc.client_close(&c)
	expect_kind(t, ipc.client_open(&c, {dir, "s"}, test_protocol(), {role = TEST_ROLE_CLIENT}), .No_Server, "client_open")
}

@(test)
test_P23_start_that_never_listens :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	c: ipc.Client
	defer ipc.client_close(&c)
	start := time.tick_now()
	err := ipc.client_open(&c, {dir, "s"}, test_protocol(), {role = TEST_ROLE_CLIENT, start = {"/usr/bin/false"}, start_ms = 500})
	expect_kind(t, err, .Start_Failed, "client_open")
	testing.expectf(t, ms_since(start) <= 800, "Start_Failed after %.0f ms, start_ms is 500", ms_since(start))
}

@(private = "file")
_Racer :: struct {
	at:  ipc.Endpoint,
	err: ipc.Error,
	pid: u32,
}

// _race opens a client that starts the server if needed and asks its pid.
@(private = "file")
_race :: proc(r: ^_Racer) {
	c: ipc.Client
	defer ipc.client_close(&c)
	r.err = ipc.client_open(&c, r.at, test_protocol(), {role = TEST_ROLE_CLIENT, start = child_start(r.at)})
	if r.err.kind == .None do r.pid, r.err = child_ask(&c, CHILD_ASK_PID)
}

@(test)
test_P23_two_clients_race_to_start_one_server :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	dir := test_dir()
	defer test_dir_remove(dir)
	a, b := _Racer{at = {dir, "s"}}, _Racer{at = {dir, "s"}}
	other := thread.create_and_start_with_poly_data(&b, _race, context)
	_race(&a)
	thread.join(other)
	thread.destroy(other)
	expect_ok(t, a.err, "first racer")
	expect_ok(t, b.err, "second racer")
	testing.expect(t, a.pid != 0 && a.pid != u32(posix.getpid()), "the server did not run in a process of its own")
	testing.expect_value(t, b.pid, a.pid)
}

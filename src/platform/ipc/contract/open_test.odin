package platform_ipc_contract

// P6: *_open refuses a bad catalog or a limit out of range and creates no
// socket.

import "core:fmt"
import "core:testing"
import ipc "../"

@(private = "file")
_bad_catalogs := [?][]ipc.Msg_Spec{
	{{request = TEST_PING, answer = TEST_PONG}, {request = TEST_PING, answer = TEST_JOB_DONE}}, // duplicate request
	{{request = 1, answer = TEST_PONG}},                                                     // CREDIT is the transport's
	{{request = HELLO_KIND, answer = TEST_PONG}},                                            // default hello_kind
	{{request = TEST_PING, answer = FAIL_KIND}},                                             // default fail_kind
	{{request = TEST_PING, answer = 0}},                                                     // no answer
	{{request = TEST_PING, answer = TEST_PONG, progress = 2}},                               // CLOSE as progress
}

@(test)
test_P6_bad_catalog_is_refused :: proc(t: ^testing.T) {
	dir := test_dir()
	defer test_dir_remove(dir)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	at := ipc.Endpoint{dir, "s"}
	for cat, i in _bad_catalogs {
		proto := test_protocol()
		proto.catalog = cat
		s: ipc.Server
		expect_kind(t, ipc.server_open(&s, at, proto, &set), .Bad_Protocol, fmt.tprintf("server_open catalog %d", i))
		ipc.server_close(&s)
		c: ipc.Client
		expect_kind(t, ipc.client_open(&c, at, proto, {role = TEST_ROLE_CLIENT}), .Bad_Protocol, fmt.tprintf("client_open catalog %d", i))
		ipc.client_close(&c)
		testing.expectf(t, !exists(sock_path(at)), "catalog %d left a socket", i)
	}
	proto := test_protocol()
	proto.hello_kind = TEST_PING // a custom hello_kind is reserved as well
	s: ipc.Server
	expect_kind(t, ipc.server_open(&s, at, proto, &set), .Bad_Protocol, "server_open hello_kind = PING")
	ipc.server_close(&s)
}

@(private = "file")
_bad_server_opts := [?]ipc.Server_Opts{
	{max_peers = -1}, {max_peers = 257},
	{max_open = -1}, {max_open = 1025},
	{hello_ms = -1},
	{max_payload = -1}, {max_payload = 16 << 20 + 1},
}

@(private = "file")
_bad_link_opts := [?]ipc.Link_Opts{{hello_ms = -1}, {pending = -1}, {pending = 17}, {backlog = -1}}

@(test)
test_P6_limits_out_of_range_are_refused :: proc(t: ^testing.T) {
	dir := test_dir()
	defer test_dir_remove(dir)
	set: ipc.Poll_Set
	if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
	defer ipc.poll_set_destroy(&set)
	at := ipc.Endpoint{dir, "s"}
	for opts in _bad_server_opts {
		s: ipc.Server
		expect_kind(t, ipc.server_open(&s, at, test_protocol(), &set, opts), .Bad_Opts, fmt.tprintf("server_open %v", opts))
		ipc.server_close(&s)
	}
	for opts in _bad_link_opts {
		l: ipc.Link
		expect_kind(t, ipc.link_listen(&l, at, link_protocol(), &set, opts), .Bad_Opts, fmt.tprintf("link_listen %v", opts))
		ipc.link_close(&l)
	}
	testing.expect(t, !exists(sock_path(at)), "a refused open left a socket")
}


package platform_ipc_contract

// P5: every public type closes safely as a zero value and twice after open,
// and never touches fd 0 that it does not own.

import "core:testing"
import ipc "../"

@(test)
test_P5_poll_set_closes_twice :: proc(t: ^testing.T) {
	with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		set: ipc.Poll_Set
		ipc.poll_set_destroy(&set)
		ipc.poll_set_destroy(&set)
		if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
		ipc.poll_set_destroy(&set)
		ipc.poll_set_destroy(&set)
		testing.expect(t, set == {}, "a destroyed Poll_Set is not zero")
	})
}

@(test)
test_P5_server_closes_twice :: proc(t: ^testing.T) {
	with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		dir := test_dir()
		defer test_dir_remove(dir)
		zero: ipc.Server
		ipc.server_close(&zero)
		ipc.server_close(&zero)
		set: ipc.Poll_Set
		if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
		defer ipc.poll_set_destroy(&set)
		s: ipc.Server
		if !expect_ok(t, ipc.server_open(&s, {dir, "s"}, test_protocol(), &set), "server_open") do return
		ipc.server_close(&s)
		ipc.server_close(&s)
		testing.expect(t, s == {}, "a closed Server is not zero")
	})
}

@(test)
test_P5_client_closes_twice :: proc(t: ^testing.T) {
	with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		dir := test_dir()
		defer test_dir_remove(dir)
		zero: ipc.Client
		ipc.client_close(&zero)
		ipc.client_close(&zero)
		o: Owner
		if !owner_open(t, &o, {dir, "s"}) do return
		defer owner_close(&o)
		c: ipc.Client
		if !open_client(t, &c, {dir, "s"}) do return
		ipc.client_close(&c)
		ipc.client_close(&c)
		testing.expect(t, c == {}, "a closed Client is not zero")
	})
}

@(test)
test_P5_link_closes_twice :: proc(t: ^testing.T) {
	with_fd0_on_a_pipe(t, proc(t: ^testing.T) {
		dir := test_dir()
		defer test_dir_remove(dir)
		zero: ipc.Link
		ipc.link_close(&zero)
		ipc.link_close(&zero)
		set: ipc.Poll_Set
		if !expect_ok(t, ipc.poll_set_init(&set, 8), "poll_set_init") do return
		defer ipc.poll_set_destroy(&set)
		listen, dial: ipc.Link
		if !expect_ok(t, ipc.link_listen(&listen, {dir, "l"}, link_protocol(), &set), "link_listen") do return
		if !expect_ok(t, ipc.link_dial(&dial, {dir, "l"}, link_protocol(), TEST_ROLE_CLIENT, &set), "link_dial") do return
		for l in ([]^ipc.Link{&dial, &listen}) {
			ipc.link_close(l)
			ipc.link_close(l)
			testing.expect(t, l^ == {}, "a closed Link is not zero")
		}
	})
}

// link_protocol: a Link has no catalog; 0.0.2 like term's holder link.
link_protocol :: proc() -> ipc.Protocol {
	return {name = "ipc contract link", version = {0, 0, 2}, roles = {int(TEST_ROLE_CLIENT)}}
}

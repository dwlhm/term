package term

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"
import sess_feat "../../features/session"

@(private = "file")
ctl_socket_counter: int

// Ctl_Socket owns one test's private dir and the socket path inside it.
@(private = "file")
Ctl_Socket :: struct {
	dir_buf:  [256]u8,
	path_buf: [300]u8,
	dir:      string,
	path:     string,
}

// ctl_socket_open makes a private dir under $TMPDIR for one test (the package
// validates it) and points $TERM_CTL_SOCK at the socket inside.
@(private = "file")
ctl_socket_open :: proc(s: ^Ctl_Socket, t: ^testing.T) -> bool {
	ctl_socket_counter += 1
	name := fmt.tprintf("termctl-%d-%d", os.get_pid(), ctl_socket_counter)
	dir, derr := plat_ipc.private_dir(s.dir_buf[:], name)
	if derr.kind != .None {
		testing.expectf(t, false, "private control dir: %s", plat_ipc.error_message(derr))
		return false
	}
	path, ok := proto.session_path(s.path_buf[:], dir, "ctl.sock")
	if !ok {
		testing.expect(t, false, "control socket path is too long")
		return false
	}
	s.dir, s.path = dir, path
	os.set_env("TERM_CTL_SOCK", path)
	return true
}

@(private = "file")
ctl_socket_close :: proc(s: ^Ctl_Socket) {
	os.unset_env("TERM_CTL_SOCK")
	os.remove_all(s.dir)
}

// _ctl_test_app starts a Primary app whose control Server watches s's socket.
@(private = "file")
_ctl_test_app :: proc(t: ^testing.T, s: ^Ctl_Socket) -> (app: ^Term_App, at: plat_ipc.Endpoint, ok: bool) {
	app = new(Term_App)
	app.role = .Primary
	sess_feat.session_registry_init(&app.session_reg)
	err := app_control_start(app)
	if err.kind != .None {
		testing.expectf(t, false, "app_control_start: %s", plat_ipc.error_message(err))
		sess_feat.session_registry_destroy(&app.session_reg)
		free(app)
		return nil, {}, false
	}
	aerr: plat_ipc.Error
	at, aerr = proto.control_endpoint(s.path_buf[:])
	if aerr.kind != .None {
		testing.expectf(t, false, "control_endpoint: %s", plat_ipc.error_message(aerr))
		app_control_stop(app)
		sess_feat.session_registry_destroy(&app.session_reg)
		free(app)
		return nil, {}, false
	}
	return app, at, true
}

@(private = "file")
_ctl_test_app_close :: proc(app: ^Term_App) {
	app_control_stop(app)
	sess_feat.session_registry_destroy(&app.session_reg)
	free(app)
}

@(private = "file")
Client_Result :: struct {
	reply: string,
	err:   plat_ipc.Error,
	done:  bool,
}

@(private = "file")
Client_Arg :: struct {
	at:     plat_ipc.Endpoint,
	line:   string,
	out:    []u8,
	result: ^Client_Result,
}

@(private = "file")
client_thread :: proc(a: ^Client_Arg) {
	r, e := app_control_request(a.at, a.line, a.out)
	a.result.reply = r
	a.result.err = e
	a.result.done = true
}

// run_client serves the app's control socket while one line client waits;
// the reply points into the caller's out.
@(private = "file")
run_client :: proc(app: ^Term_App, at: plat_ipc.Endpoint, line: string, out: []u8) -> (reply: string, err: plat_ipc.Error) {
	res := Client_Result{}
	arg := Client_Arg{at = at, line = line, out = out, result = &res}
	thr := thread.create_and_start_with_poly_data(&arg, client_thread)
	if thr == nil do return "", {kind = .Start_Failed, reason = "cannot start the client thread"}

	deadline := time.tick_now()._nsec + 2_000_000_000
	for time.tick_now()._nsec < deadline {
		_ = app_control_poll(app)
		time.sleep(1 * time.Millisecond)
		if res.done do break
	}
	thread.join(thr)
	thread.destroy(thr)
	return res.reply, res.err
}

@(test)
test_control_ping :: proc(t: ^testing.T) {
	s: Ctl_Socket
	if !ctl_socket_open(&s, t) do return
	defer ctl_socket_close(&s)

	app, at, ok := _ctl_test_app(t, &s)
	if !ok do return
	defer _ctl_test_app_close(app)

	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	reply, cerr := run_client(app, at, "ping", reply_buf[:])
	testing.expect_value(t, cerr.kind, plat_ipc.Error_Kind.None)
	testing.expect(t, strings.has_prefix(reply, "ok\nterm "), "reply prefix")
}

@(test)
test_control_ls_and_kill_belong_to_the_core :: proc(t: ^testing.T) {
	s: Ctl_Socket
	if !ctl_socket_open(&s, t) do return
	defer ctl_socket_close(&s)

	app, at, ok := _ctl_test_app(t, &s)
	if !ok do return
	defer _ctl_test_app_close(app)

	for line in ([]string{"ls", "kill 77"}) {
		reply_buf: [proto.CONTROL_MAX_REPLY]u8
		reply, cerr := run_client(app, at, line, reply_buf[:])
		testing.expect_value(t, cerr.kind, plat_ipc.Error_Kind.None)
		testing.expect(t, strings.has_prefix(reply, "err bad_request"), "served by the session core")
	}
}

@(test)
test_control_bad_request :: proc(t: ^testing.T) {
	s: Ctl_Socket
	if !ctl_socket_open(&s, t) do return
	defer ctl_socket_close(&s)

	app, at, ok := _ctl_test_app(t, &s)
	if !ok do return
	defer _ctl_test_app_close(app)

	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	reply, cerr := run_client(app, at, "frobnicate", reply_buf[:])
	testing.expect_value(t, cerr.kind, plat_ipc.Error_Kind.None)
	testing.expect(t, strings.has_prefix(reply, "err bad_request"), "bad request")
}

@(test)
test_control_quit_replies_then_quits :: proc(t: ^testing.T) {
	s: Ctl_Socket
	if !ctl_socket_open(&s, t) do return
	defer ctl_socket_close(&s)

	app, at, ok := _ctl_test_app(t, &s)
	if !ok do return
	defer _ctl_test_app_close(app)
	app.running = true

	reply_buf: [proto.CONTROL_MAX_REPLY]u8
	reply, cerr := run_client(app, at, "quit", reply_buf[:])
	testing.expect_value(t, cerr.kind, plat_ipc.Error_Kind.None)
	testing.expect_value(t, reply, "ok\n")
	testing.expect_value(t, app.running, false)
}

@(test)
test_cli_not_handled_for_gui_args :: proc(t: ^testing.T) {
	handled, code := app_run_control_cli([]string{"term"})
	testing.expect_value(t, handled, false)
	_ = code

	handled2, code2 := app_run_control_cli([]string{"term", "-e", "ls"})
	testing.expect_value(t, handled2, false)
	_ = code2

	handled3, code3 := app_run_control_cli([]string{"term", "session"})
	testing.expect_value(t, handled3, true)
	testing.expect_value(t, code3, 1)
}

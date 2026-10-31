package term

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"
import sess_feat "../../features/session"

@(private = "file")
ctl_sock_counter: int

@(private = "file")
unique_ctl_sock :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 do tmp = "/tmp"
	ctl_sock_counter += 1
	return fmt.tprintf("%s/termctl-%d-%d.sock", tmp, int(posix.getpid()), ctl_sock_counter)
}

@(private = "file")
Client_Result :: struct {
	buf:   [plat_ipc.IPC_MAX_REPLY]u8,
	reply: string,
	err:   plat_ipc.Ipc_Error,
	done:  bool,
}

@(private = "file")
Client_Arg :: struct {
	path:       string,
	line:       string,
	timeout_ms: int,
	result:     ^Client_Result,
}

@(private = "file")
client_thread :: proc(a: Client_Arg) {
	r, e := plat_ipc.ipc_client_request(a.path, a.line, a.result.buf[:], a.timeout_ms)
	a.result.reply = r
	a.result.err = e
	// done flag
	a.result.done = true
}

// helper to run a client request while polling
@(private = "file")
run_client :: proc(app: ^Term_App, path: string, line: string, timeout_ms: int = plat_ipc.IPC_CLIENT_TIMEOUT_MS) -> (reply: string, err: plat_ipc.Ipc_Error) {
	res := Client_Result{}
	arg := Client_Arg{path = path, line = line, timeout_ms = timeout_ms, result = &res}
	thr := thread.create_and_start_with_poly_data(arg, client_thread)
	if thr == nil do return "", .Socket_Failed

	deadline := time.tick_now()._nsec + 2_000_000_000
	for time.tick_now()._nsec < deadline {
		if app_control_poll(app) do _ = true
		time.sleep(1 * time.Millisecond)
		if res.done do break
	}
	thread.join(thr)
	thread.destroy(thr)
	return res.reply, res.err
}

@(test)
test_control_ping :: proc(t: ^testing.T) {
	sock := unique_ctl_sock()
	os.set_env("TERM_CTL_SOCK", sock)
	defer os.unset_env("TERM_CTL_SOCK")

	app := new(Term_App)
	defer free(app)
	app.role = .Primary
	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	err := app_control_start(app)
	testing.expect_value(t, err, plat_ipc.Ipc_Error.None)
	if err != .None do return
	defer app_control_stop(app)

	reply, cerr := run_client(app, sock, "ping")
	testing.expect_value(t, cerr, plat_ipc.Ipc_Error.None)
	testing.expect(t, strings.has_prefix(reply, "ok\nterm "), "reply prefix")
}

@(test)
test_control_ls_empty_and_one :: proc(t: ^testing.T) {
	sock := unique_ctl_sock()
	os.set_env("TERM_CTL_SOCK", sock)
	defer os.unset_env("TERM_CTL_SOCK")

	app := new(Term_App)
	defer free(app)
	app.role = .Primary
	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	err := app_control_start(app)
	testing.expect_value(t, err, plat_ipc.Ipc_Error.None)
	if err != .None do return
	defer app_control_stop(app)

	// empty
	reply, cerr := run_client(app, sock, "ls")
	testing.expect_value(t, cerr, plat_ipc.Ipc_Error.None)
	testing.expect_value(t, reply, "ok\n")

	// detach one real session with id 77
	cfg := sess_feat.Session_Config{shell = "/bin/sh", rows = 24, cols = 80}
	sess, serr := sess_feat.session_create(cfg)
	testing.expect(t, serr == .None, "session_create failed")
	testing.expect(t, sess != nil, "session")
	if sess == nil do return
	ok := sess_feat.session_registry_detach(&app.session_reg, 77, sess)
	testing.expect(t, ok, "detach")

	reply2, cerr2 := run_client(app, sock, "ls")
	testing.expect_value(t, cerr2, plat_ipc.Ipc_Error.None)
	// reply has ok\n + one row
	testing.expect(t, strings.has_prefix(reply2, "ok\n"), "prefix")
	// extract row line
	body := reply2[len("ok\n"):]
	line := strings.trim_right(body, "\n") // empty trailing fields end in '\t'; keep them
	row, rok := ctrl_feat.control_parse_session_row(line)
	testing.expect(t, rok, "parse row")
	testing.expect_value(t, row.id, u32(77))
}

@(test)
test_control_kill_and_not_found :: proc(t: ^testing.T) {
	sock := unique_ctl_sock()
	os.set_env("TERM_CTL_SOCK", sock)
	defer os.unset_env("TERM_CTL_SOCK")

	app := new(Term_App)
	defer free(app)
	app.role = .Primary
	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	cfg := sess_feat.Session_Config{shell = "/bin/sh", rows = 24, cols = 80}
	sess, serr := sess_feat.session_create(cfg)
	testing.expect(t, serr == .None, "session_create failed")
	if sess == nil do return
	_ = sess_feat.session_registry_detach(&app.session_reg, 77, sess)

	err := app_control_start(app)
	testing.expect_value(t, err, plat_ipc.Ipc_Error.None)
	if err != .None do return
	defer app_control_stop(app)

	reply, cerr := run_client(app, sock, "kill 77")
	testing.expect_value(t, cerr, plat_ipc.Ipc_Error.None)
	testing.expect_value(t, reply, "ok\n")
	testing.expect_value(t, sess_feat.session_registry_count(&app.session_reg), 0)

	reply2, cerr2 := run_client(app, sock, "kill 77")
	testing.expect_value(t, cerr2, plat_ipc.Ipc_Error.None)
	testing.expect(t, strings.has_prefix(reply2, "err not_found"), "not found")
}

@(test)
test_control_bad_request :: proc(t: ^testing.T) {
	sock := unique_ctl_sock()
	os.set_env("TERM_CTL_SOCK", sock)
	defer os.unset_env("TERM_CTL_SOCK")

	app := new(Term_App)
	defer free(app)
	app.role = .Primary
	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	err := app_control_start(app)
	testing.expect_value(t, err, plat_ipc.Ipc_Error.None)
	if err != .None do return
	defer app_control_stop(app)

	reply, cerr := run_client(app, sock, "frobnicate")
	testing.expect_value(t, cerr, plat_ipc.Ipc_Error.None)
	testing.expect(t, strings.has_prefix(reply, "err bad_request"), "bad request")
}

@(test)
test_control_quit_replies_then_quits :: proc(t: ^testing.T) {
	sock := unique_ctl_sock()
	os.set_env("TERM_CTL_SOCK", sock)
	defer os.unset_env("TERM_CTL_SOCK")

	app := new(Term_App)
	defer free(app)
	app.role = .Primary
	app.running = true
	sess_feat.session_registry_init(&app.session_reg)
	defer sess_feat.session_registry_destroy(&app.session_reg)

	err := app_control_start(app)
	testing.expect_value(t, err, plat_ipc.Ipc_Error.None)
	if err != .None do return
	defer app_control_stop(app)

	reply, cerr := run_client(app, sock, "quit")
	testing.expect_value(t, cerr, plat_ipc.Ipc_Error.None)
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
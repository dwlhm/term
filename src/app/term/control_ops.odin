package term

// Control Socket Bridge (term session attach, show, quit)
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: the owner side runs entirely on the UI thread inside app_run and
// never blocks (a .Line Server queues lines under its mutex and writes on its
// own IO thread). Every request gets exactly one reply. `term session
// ls|kill` talk to the session core, not to this socket.

import "core:fmt"
import "core:strings"

import proto "../../features/session_proto"
import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"
import sess_feat "../../features/session"

// app_control_start (Primary only, called from main() BEFORE app_init):
// resolve proto.control_endpoint and open app.control as a .Line Server whose
// IO runs on its own thread, waking this one through app_wakeup_callback.
app_control_start :: proc(app: ^Term_App) -> plat_ipc.Error {
	if app == nil do return {kind = .Bad_Opts, reason = "no application"}
	buf: [256]u8
	at, perr := proto.control_endpoint(buf[:])
	if perr.kind != .None do return perr
	return plat_ipc.server_open_thread(&app.control, at, proto.control(), app_wakeup_callback, app, {framing = .Line})
}

// app_control_poll takes every line the IO thread has queued:
// parse (control_parse_request) → dispatch → ipc.reply. Builder memory comes
// from context.temp_allocator. Returns true if UI state changed.
//   ping   → ok + "term <VERSION>\n"
//   show   → app_show_window; ok
//   quit   → reply ok FIRST, then app_request_quit_flow (asks about running programs)
//   attach → unknown id: err not_found "no such session"; .Exited: err
//            exited "session has exited"; else app_attach_background_session
//            then app_show_window; ok
//   ls/kill → err bad_request (served by the session core)
//   parse error → err bad_request control_parse_error_message(err)
// A broken listener closes the server here and says so once on stderr.
app_control_poll :: proc(app: ^Term_App) -> (dirty: bool) {
	if app == nil do return false
	for ev in plat_ipc.server_next(&app.control) {
		#partial switch e in ev {
		case plat_ipc.Server_Down:
			plat_ipc.server_close(&app.control)
			reason := e.err.reason if len(e.err.reason) > 0 else plat_ipc.error_message(e.err)
			fmt.eprintf("term: control socket closed (%s)\n", reason)
		case plat_ipc.Request:
			quit, force, changed := _control_answer(app, e)
			dirty = dirty || changed
			if quit {
				if force do app_quit_finish(app)
				else do app_request_quit_flow(app)
			}
		}
	}
	return dirty
}

// _control_answer writes and queues the reply for one request.
@(private = "file")
_control_answer :: proc(app: ^Term_App, req: plat_ipc.Request) -> (quit, force, dirty: bool) {
	req := req
	b := strings.builder_make(context.temp_allocator)
	parsed, perr := ctrl_feat.control_parse_request(plat_ipc.request_line(&req))
	if perr != .None {
		ctrl_feat.control_write_err(&b, .Bad_Request, ctrl_feat.control_parse_error_message(perr))
	} else {
		dirty, quit, force = _control_dispatch(app, parsed, &b)
	}
	text := strings.to_string(b)
	plat_ipc.reply(&app.control, req, transmute([]u8)text)
	return
}

// _control_dispatch writes the reply for one parsed request.
@(private = "file")
_control_dispatch :: proc(app: ^Term_App, req: ctrl_feat.Control_Request, b: ^strings.Builder) -> (dirty, quit, force: bool) {
	switch req.verb {
	case .Ping:
		ctrl_feat.control_write_ok(b)
		fmt.sbprintf(b, "term %s\n", VERSION)
	case .Show:
		app_show_window(app)
		ctrl_feat.control_write_ok(b)
		dirty = true
	case .Quit:
		ctrl_feat.control_write_ok(b)
		quit = true
		force = req.force
	case .List, .Kill:
		ctrl_feat.control_write_err(b, .Bad_Request, "served by the session core: term session ls|kill")
	case .Attach:
		dirty = _control_attach(app, req.id, b)
	}
	return
}

@(private = "file")
_control_attach :: proc(app: ^Term_App, id: u32, b: ^strings.Builder) -> bool {
	entry := sess_feat.session_registry_find(&app.session_reg, id)
	if entry != nil && entry.state == .Exited {
		ctrl_feat.control_write_err(b, .Exited, "session has exited")
		return false
	}
	if entry == nil || !app_attach_background_session(app, id) {
		ctrl_feat.control_write_err(b, .Not_Found, "no such session")
		return false
	}
	app_show_window(app)
	ctrl_feat.control_write_ok(b)
	return true
}

// app_control_stop: idempotent; a zero Server is already closed.
app_control_stop :: proc(app: ^Term_App) {
	if app == nil do return
	plat_ipc.server_close(&app.control)
}

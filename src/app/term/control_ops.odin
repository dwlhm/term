package term

// Control Socket Bridge (term session attach, show, quit)
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: runs entirely on the UI thread inside app_run; never blocks
// (ipc_server_poll/reply are non-blocking). Every request gets exactly one
// reply. `term session ls|kill` talk to the session core, not to this socket.

import "core:fmt"
import "core:strings"

import plat_ipc "../../platform/ipc"
import ctrl_feat "../../features/control"
import sess_feat "../../features/session"

// app_control_start (Primary only, called from main() BEFORE app_init):
// resolve ipc_default_socket_path, allocate app.control with new(), and
// ipc_server_start(app.control, path, app_wakeup_callback, app).
// On any error app.control is freed and set to nil; the error is returned.
app_control_start :: proc(app: ^Term_App) -> plat_ipc.Ipc_Error {
	if app == nil do return .Socket_Failed
	buf: [256]u8
	path, perr := plat_ipc.ipc_default_socket_path(buf[:])
	if perr != .None do return perr
	app.control = new(plat_ipc.Ipc_Server)
	serr := plat_ipc.ipc_server_start(app.control, path, app_wakeup_callback, app)
	if serr != .None {
		free(app.control)
		app.control = nil
		return serr
	}
	return .None
}

// app_control_poll handles at most ipc.IPC_MAILBOX_CAP queued requests:
// parse (control_parse_request) → dispatch → ipc_server_reply. Builder
// memory comes from context.temp_allocator. Returns true if UI state changed.
//   ping   → ok + "term <VERSION>\n"
//   show   → app_show_window; ok
//   quit   → reply ok FIRST, then app_request_quit_flow (asks about running programs)
//   attach → unknown id: err not_found "no such session"; .Exited: err
//            exited "session has exited"; else app_attach_background_session
//            then app_show_window; ok
//   ls/kill → err bad_request (served by the session core)
//   parse error → err bad_request control_parse_error_message(err)
app_control_poll :: proc(app: ^Term_App) -> (dirty: bool) {
	if app == nil || app.control == nil do return false
	req: plat_ipc.Ipc_Request
	for _ in 0..<plat_ipc.IPC_MAILBOX_CAP {
		if !plat_ipc.ipc_server_poll(app.control, &req) do break
		b := strings.builder_make(context.temp_allocator)
		parsed, perr := ctrl_feat.control_parse_request(plat_ipc.ipc_request_line(&req))
		quit := false
		if perr != .None {
			ctrl_feat.control_write_err(&b, .Bad_Request, ctrl_feat.control_parse_error_message(perr))
		} else {
			changed: bool
			changed, quit = _control_dispatch(app, parsed, &b)
			dirty ||= changed
		}
		plat_ipc.ipc_server_reply(app.control, req.ticket, strings.to_string(b))
		if quit do app_request_quit_flow(app) // after the reply is queued, so the client gets "ok"
	}
	return dirty
}

// _control_dispatch writes the reply for one parsed request.
@(private = "file")
_control_dispatch :: proc(app: ^Term_App, req: ctrl_feat.Control_Request, b: ^strings.Builder) -> (dirty, quit: bool) {
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

// app_control_stop: nil-safe; ipc_server_stop, free, set nil.
app_control_stop :: proc(app: ^Term_App) {
	if app == nil do return
	if app.control != nil {
		plat_ipc.ipc_server_stop(app.control)
		free(app.control)
		app.control = nil
	}
}
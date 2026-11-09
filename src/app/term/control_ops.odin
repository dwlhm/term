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
import client_feat "../../features/session_client"
import mux_feat "../../features/multiplexer"
import tabs_feat "../../features/tabs"
import damage "../../core/terminal/damage"
import chrome_splits "../../core/chrome/splits"
import chrome_render "../../core/render/chrome"

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
_control_dispatch :: proc(
	app: ^Term_App, req: ctrl_feat.Control_Request, b: ^strings.Builder,
) -> (dirty, quit, force: bool) {
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
	case .Split:
		dirty = _control_split(app, req.split_dir, req.id, b)
	case .Tab:
		dirty = _control_tab(app, req.id, b)
	}
	return
}

@(private = "file")
_control_prepare_pane :: proc(
	app: ^Term_App, id: u32, b: ^strings.Builder,
) -> (pane_id: u32, sess: ^sess_feat.Terminal_Session, ok: bool) {
	if id > 0 {
		entry := sess_feat.session_registry_find(&app.session_reg, id)
		if entry != nil && entry.state == .Exited {
			ctrl_feat.control_write_err(b, .Exited, "session has exited")
			return 0, nil, false
		}
		if entry == nil {
			ctrl_feat.control_write_err(b, .Not_Found, "no such session")
			return 0, nil, false
		}
		size := proto.Size_Msg{cols = 80, rows = 24}
		sess = client_feat.client_attach(&app.client, {id = id, size = size, history = APP_ATTACH_HISTORY})
		if sess == nil {
			ctrl_feat.control_write_err(b, .Internal, "failed to attach session")
			return 0, nil, false
		}
		sess_feat.session_set_clipboard_sink(sess, _app_osc_52_sink, rawptr(&app.clipboard))
		pane_id = mux_feat.multiplexer_add_terminal_pane(&app.mux, sess)
		_ = sess_feat.session_registry_remove(&app.session_reg, id)
		return pane_id, sess, true
	}
	new_p, spawn_ok := app_spawn_terminal_pane(app, 24, 80)
	if !spawn_ok {
		ctrl_feat.control_write_err(b, .Internal, "failed to spawn terminal pane")
		return 0, nil, false
	}
	return new_p, nil, true
}

@(private = "file")
_control_split :: proc(app: ^Term_App, dir: ctrl_feat.Split_Dir, id: u32, b: ^strings.Builder) -> bool {
	pane_id, sess, ok := _control_prepare_pane(app, id, b)
	if !ok do return false

	_, active_tab := tabs_feat.tabs_manager_get_active(&app.tabs_mgr)
	if active_tab == nil || active_tab.split_tree == nil {
		ctrl_feat.control_write_err(b, .Internal, "no active tab")
		return false
	}

	target_leaf := chrome_splits.split_tree_find_leaf(active_tab.split_tree, app.mux.focused_pane_id)
	if target_leaf == nil do target_leaf = active_tab.split_tree
	kind: chrome_splits.Split_Kind = .Horizontal if dir == .Right else .Vertical
	chrome_splits.split_node_split(target_leaf, kind, 0.5, pane_id, app.tabs_mgr.allocator)
	mux_feat.multiplexer_focus_pane(&app.mux, pane_id)
	active_tab.active_pane_id = pane_id
	app.last_title_sync = {}
	app_sync_layout_and_winsize(app, true)

	if sess != nil do damage.damage_mark_all(&sess.term.damage)
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	app_show_window(app)
	ctrl_feat.control_write_ok(b)
	return true
}

@(private = "file")
_control_tab :: proc(app: ^Term_App, id: u32, b: ^strings.Builder) -> bool {
	if id > 0 {
		return _control_attach(app, id, b)
	}
	new_p, ok := app_spawn_terminal_pane(app, 24, 80)
	if !ok {
		ctrl_feat.control_write_err(b, .Internal, "failed to spawn terminal pane")
		return false
	}
	_, new_tab_idx := tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
	if new_tab_idx >= 0 do app_select_tab(app, new_tab_idx)
	app_show_window(app)
	ctrl_feat.control_write_ok(b)
	return true
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

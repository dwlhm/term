package term

// Control Socket Bridge (term session ls/attach/kill, show, quit)
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: runs entirely on the UI thread inside app_run; never blocks
// (ipc_server_poll/reply are non-blocking). Every request gets exactly one
// reply. Only `ls` lists background (detached) sessions; ids are the
// registry ids (former pane ids).

import ipc "../../platform/ipc"

// app_control_start (Primary only, called from main() BEFORE app_init):
// resolve ipc_default_socket_path, allocate app.control with new(), and
// ipc_server_start(app.control, path, app_pty_wakeup_callback, app).
// On any error app.control is freed and set to nil; the error is returned.
app_control_start :: proc(app: ^Term_App) -> ipc.Ipc_Error {
	unimplemented("T7")
}

// app_control_poll handles at most ipc.IPC_MAILBOX_CAP queued requests:
// parse (control_parse_request) → dispatch → ipc_server_reply. Builder
// memory comes from context.temp_allocator. Returns true if UI state changed.
//   ping   → ok + "term <VERSION>\n"
//   show   → app_show_window; ok
//   quit   → reply ok FIRST, then app_request_quit
//   ls     → ok + one control_write_session_row per registry entry
//            (session_snapshot_make for pid/process/cwd/status/elapsed;
//            state from entry.state)
//   attach → unknown id: err not_found "no such session"; .Exited: err
//            exited "session has exited"; else app_attach_background_session
//            then app_show_window; ok
//   kill   → session_registry_remove; unknown: err not_found; ok
//   parse error → err bad_request control_parse_error_message(err)
app_control_poll :: proc(app: ^Term_App) -> (dirty: bool) {
	unimplemented("T7")
}

// app_control_stop: nil-safe; ipc_server_stop, free, set nil.
app_control_stop :: proc(app: ^Term_App) {
	unimplemented("T7")
}

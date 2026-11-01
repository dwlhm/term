package term

// Quit (⌘Q, Dock Quit, window close, `term quit`): sessions shown in this
// viewer end with it unless the user keeps them. With no CLI/TUI running in
// any of them, Term quits at once and kills them. Otherwise the quit dialog
// asks, per running program, "keep running" (it becomes a background session)
// or "kill". Background sessions are never touched. A viewer that dies
// (crash, SIGTERM) kills nothing: its sessions stay in the core.

import "core:time"
import sess_feat "../../features/session"
import client_feat "../../features/session_client"
import plat_ipc "../../platform/ipc"

APP_QUIT_MAX     :: 64
APP_QUIT_WAIT_MS :: 500 // how long quit waits for the core's fresh foreground info

Quit_Phase :: enum u8 { Idle, Waiting, Asking }

Quit_Candidate :: struct {
	id:     u32,
	keep:   bool,
	title:  sess_feat.Registry_Text,
	detail: sess_feat.Registry_Text,
}

App_Quit_State :: struct {
	phase:      Quit_Phase,
	due_ns:     i64,
	candidates: [APP_QUIT_MAX]Quit_Candidate,
	count:      int,
	dialog:     Quit_Dialog_State,
}

app_request_quit_flow :: proc(app: ^Term_App) {
	if app == nil || app.quit.phase != .Idle do return
	if app.role == .Standalone || !_any_shown(app) {
		app_quit_finish(app)
		return
	}
	app.quit.count = 0
	app.quit.phase = .Waiting
	app.quit.due_ns = time.tick_now()._nsec + APP_QUIT_WAIT_MS * 1_000_000
	if !client_feat.client_list(&app.client) do _decide(app)
}

// app_quit_note_row records a shown session's row while quit waits for them.
app_quit_note_row :: proc(app: ^Term_App, row: plat_ipc.Session_Row) {
	if app.quit.phase != .Waiting || !row.active do return
	for i in 0..<app.quit.count do if app.quit.candidates[i].id == row.id do return
	if app.quit.count >= APP_QUIT_MAX do return
	c := &app.quit.candidates[app.quit.count]
	c^ = {id = row.id, keep = true}
	c.title.len = copy(c.title.buf[:], row.title if len(row.title) > 0 else row.process)
	c.detail.len = copy(c.detail.buf[:], row.status if len(row.status) > 0 else row.cwd)
	app.quit.count += 1
}

// app_quit_rows_arrived: the core answered LIST, every shown row has been noted.
app_quit_rows_arrived :: proc(app: ^Term_App) {
	if app.quit.phase == .Waiting do _decide(app)
}

// app_quit_tick decides without the core's answer once the wait is over.
app_quit_tick :: proc(app: ^Term_App) {
	if app.quit.phase == .Waiting && time.tick_now()._nsec >= app.quit.due_ns do _decide(app)
}

// app_quit_wait_ms is the event-loop timeout while quit waits (-1 otherwise).
app_quit_wait_ms :: proc(app: ^Term_App) -> i32 {
	if app.quit.phase != .Waiting do return -1
	return max(1, i32((app.quit.due_ns - time.tick_now()._nsec) / 1_000_000) + 1)
}

@(private = "file")
_decide :: proc(app: ^Term_App) {
	if app.quit.count == 0 {
		app_quit_finish(app)
		return
	}
	app.quit.phase = .Asking
	quit_dialog_open(&app.quit.dialog)
}

app_quit_cancel :: proc(app: ^Term_App) {
	app.quit.phase, app.quit.count = .Idle, 0
	quit_dialog_close(&app.quit.dialog)
}

// app_quit_finish ends every shown session except the kept ones, then quits.
app_quit_finish :: proc(app: ^Term_App) {
	for &p in app.mux.panes {
		if p.session == nil do continue
		id := client_feat.client_session_id(&app.client, p.session)
		sess_feat.session_provider_release(&app.mux.provider, p.session, !_kept(app, id))
		p.session = nil
	}
	app.quit.phase = .Idle
	quit_dialog_close(&app.quit.dialog)
	app_request_quit(app)
}

@(private = "file")
_kept :: proc(app: ^Term_App, id: u32) -> bool {
	if app.quit.phase != .Asking do return false
	for i in 0..<app.quit.count do if app.quit.candidates[i].id == id do return app.quit.candidates[i].keep
	return false
}

@(private = "file")
_any_shown :: proc(app: ^Term_App) -> bool {
	for &p in app.mux.panes do if p.kind == .Terminal && p.session != nil do return true
	return false
}

// app_quit_candidates is the dialog's view of what quit is asking about.
app_quit_candidates :: proc(app: ^Term_App) -> []Quit_Candidate {
	return app.quit.candidates[:app.quit.count]
}

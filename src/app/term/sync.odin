package term

// Synchronized output (CSI ?2026 h / l).
//
// A program that enables it promises to send a complete frame and then clear the
// flag; the terminal must not present anything in between, otherwise `htop`,
// `neovim` and friends visibly tear. A short safety valve keeps a crashed client
// from freezing presentation forever.

import "core:time"
import core_terminal "../../core/terminal"

SYNC_OUTPUT_HOLD_MS :: f64(150.0)

Sync_Output_State :: struct {
	holding: bool,
	since:   time.Time,
}

_app_any_pane_sync_output :: proc(app: ^Term_App) -> bool {
	if app == nil do return false
	for &pane in app.mux.panes {
		if pane.kind != .Terminal || pane.session == nil do continue
		if core_terminal.terminal_sync_output(&pane.session.term) do return true
	}
	return false
}

// app_sync_output_hold reports whether presentation must be skipped right now.
app_sync_output_hold :: proc(app: ^Term_App, now: time.Time) -> bool {
	if app == nil do return false
	if !_app_any_pane_sync_output(app) {
		app.sync_output.holding = false
		return false
	}
	if !app.sync_output.holding {
		app.sync_output.holding = true
		app.sync_output.since = now
	}
	if time.duration_milliseconds(time.diff(app.sync_output.since, now)) > SYNC_OUTPUT_HOLD_MS {
		return false
	}
	return true
}

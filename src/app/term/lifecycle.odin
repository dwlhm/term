package term

// Window & Process Lifecycle
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: the ONLY procs allowed to set app.running = false are
// app_request_quit (control `quit`, SIGTERM/SIGINT/SIGHUP) and app_destroy.
// Every "close" gesture (⌘Q, window close button, last tab closed, last shell
// exited) goes through app_request_hide.

import plat_win "../../platform/window"

// Instance_Role decides what "close" means for this process.
Instance_Role :: enum u8 {
	Primary,    // owns the control socket; close = hide, sessions persist
	Standalone, // diagnostics/scripted run (--telemetry, --grid-dump, -e): close = quit
}

// app_resolve_role: Standalone iff any of --telemetry, --grid-dump or -e was
// given (scripted/diagnostic runs must exit when their shell exits); else Primary.
app_resolve_role :: proc(opts: Cli_Options) -> Instance_Role {
	return .Primary // T4a
}

// app_spawn_default_tab spawns one shell pane sized to the content area,
// creates a "Shell" tab for it, focuses it. Returns false if spawn failed.
app_spawn_default_tab :: proc(app: ^Term_App) -> bool {
	unimplemented("T4a")
}

// app_request_hide: Primary → hide the window (all tabs/sessions keep
// running, the loop parks with zero rendering). Standalone → app_request_quit.
app_request_hide :: proc(app: ^Term_App) {
	if app == nil do return
	app_request_quit(app) // T4: replace with the Primary/Standalone behavior above
}

// app_show_window makes the window visible, raises and focuses it. If no tab
// exists (all were closed while hidden) a fresh shell tab is spawned first.
app_show_window :: proc(app: ^Term_App) {
	if app == nil do return
	plat_win.platform_bring_window_to_front(app.window.handle) // T4: complete per doc
}

// app_request_quit is the single real exit path.
app_request_quit :: proc(app: ^Term_App) {
	if app == nil do return
	app.running = false
}

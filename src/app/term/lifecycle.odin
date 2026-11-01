package term

// Window & Process Lifecycle
// Part of Tier 3 Application Shell (src/app/term/*).
//
// Invariant: the ONLY procs allowed to set app.running = false are
// app_request_quit (SIGTERM/SIGINT/SIGHUP, the end of the quit flow) and
// app_destroy. Every "close" gesture (⌘Q, Dock Quit, window close button,
// `term quit`) goes through app_request_quit_flow (quit_flow.odin); closing
// the last tab or the last shell exiting quits the viewer (nothing is shown).

import plat_win "../../platform/window"
import chrome_render "../../core/render/chrome"
import chrome_splits "../../core/chrome/splits"
import mux_feat "../../features/multiplexer"
import tabs_feat "../../features/tabs"
import damage "../../core/terminal/damage"

// Instance_Role decides what "close" means for this process.
Instance_Role :: enum u8 {
	Primary,    // owns the control socket; quit asks before killing running programs
	Standalone, // diagnostics/scripted run (--telemetry, --grid-dump, -e): private session, quit kills it
}

// app_resolve_role: Standalone iff any of --telemetry, --grid-dump or -e was
// given (scripted/diagnostic runs must exit when their shell exits); else Primary.
app_resolve_role :: proc(opts: Cli_Options) -> Instance_Role {
	if len(opts.telemetry_path) > 0 || len(opts.grid_dump_dir) > 0 || len(opts.initial_cmd) > 0 {
		return .Standalone
	}
	return .Primary
}

// app_spawn_default_tab spawns one shell pane sized to the content area,
// creates a "Shell" tab for it, focuses it. Returns false if spawn failed.
app_spawn_default_tab :: proc(app: ^Term_App) -> bool {
	if app == nil do return false

	content_area := layout_compute_content_area(&app.layout)
	term_cols := max(20, int((content_area[2] - 2.0 * app.layout.metrics.pane_pad_x) / app.layout.metrics.cell_w))
	term_rows := max(10, int((content_area[3] - 2.0 * app.layout.metrics.pane_pad_y) / app.layout.metrics.cell_h))
	new_p, ok := app_spawn_terminal_pane(app, term_rows, term_cols)
	if !ok do return false

	if len(app.tabs_mgr.entries) == 0 {
		tabs_feat.tabs_manager_create_tab(&app.tabs_mgr, "Shell", new_p)
		mux_feat.multiplexer_focus_pane(&app.mux, new_p)
	} else {
		tab := &app.tabs_mgr.entries[0]
		tab.split_tree = chrome_splits.split_node_create_leaf(new_p, app.tabs_mgr.allocator)
		tab.active_pane_id = new_p
		tabs_feat.tabs_manager_set_title(&app.tabs_mgr, 0, "Shell")
		mux_feat.multiplexer_focus_pane(&app.mux, new_p)
	}
	return true
}

// app_show_window raises and focuses the window (`term show`, a second launch,
// `term session attach`). If no tab exists a fresh shell tab is spawned first.
app_show_window :: proc(app: ^Term_App) {
	if app == nil do return
	if len(app.tabs_mgr.entries) == 0 {
		_ = app_spawn_default_tab(app)
	}
	plat_win.platform_bring_window_to_front(app.window.handle)
	app_sync_layout_and_winsize(app)
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			damage.damage_mark_all(&pane.session.term.damage)
		}
	}
	chrome_render.chrome_renderer_mark_dirty(&app.chrome_view.rend, true)
	app.composer.sched.force_next = true
}

// app_request_quit is the single real exit path.
app_request_quit :: proc(app: ^Term_App) {
	if app == nil do return
	app.running = false
}

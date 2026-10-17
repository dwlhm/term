package term

// Opt-in runtime diagnostics for stress testing: telemetry stream and grid snapshots.
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:fmt"
import telemetry "../../features/telemetry"

Diagnostics :: struct {
	tel:           telemetry.Telemetry,
	grid_dump_dir: string,
	dump_seq:      int,
}

diagnostics_init :: proc(d: ^Diagnostics, opts: Cli_Options) {
	if len(opts.telemetry_path) > 0 && !telemetry.telemetry_open(&d.tel, opts.telemetry_path) {
		fmt.eprintfln("warning: cannot open telemetry file %q", opts.telemetry_path)
	}
	d.grid_dump_dir = opts.grid_dump_dir
	if len(d.grid_dump_dir) > 0 && !telemetry.grid_dump_install_signal() {
		fmt.eprintln("warning: cannot install SIGUSR1 grid dump handler")
	}
}

// diagnostics_poll services pending SIGUSR1 grid dump requests from the main loop.
diagnostics_poll :: proc(app: ^Term_App) {
	if len(app.diag.grid_dump_dir) == 0 || !telemetry.grid_dump_take_request() do return
	diagnostics_dump_grids(app)
}

diagnostics_dump_grids :: proc(app: ^Term_App) {
	d := &app.diag
	if len(d.grid_dump_dir) == 0 do return
	d.dump_seq += 1
	for &pane in app.mux.panes {
		if pane.kind == .Terminal && pane.session != nil {
			_ = telemetry.grid_dump_write(d.grid_dump_dir, d.dump_seq, pane.id, &pane.session.term)
		}
	}
}

// diagnostics_shutdown writes final grid snapshots and the telemetry summary.
// Must run before panes are destroyed.
diagnostics_shutdown :: proc(app: ^Term_App) {
	diagnostics_dump_grids(app)
	telemetry.telemetry_close(&app.diag.tel)
}

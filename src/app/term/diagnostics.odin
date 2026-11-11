package term

// Opt-in runtime diagnostics: telemetry stream, grid snapshots and (env
// TERM_DEBUG_KEYS=1) every key and text event on stderr, to see what the
// platform delivers for a shortcut.
// Part of Tier 3 Application Shell (src/app/term/*).

import "core:fmt"
import "core:os"
import "vendor:sdl3"
import telemetry "../../features/telemetry"

Diagnostics :: struct {
	tel:           telemetry.Telemetry,
	grid_dump_dir: string,
	dump_seq:      int,
	debug_keys:    bool,
}

diagnostics_init :: proc(d: ^Diagnostics, opts: Cli_Options) {
	if len(opts.telemetry_path) > 0 && !telemetry.telemetry_open(&d.tel, opts.telemetry_path) {
		fmt.eprintfln("warning: cannot open telemetry file %q", opts.telemetry_path)
	}
	d.debug_keys = os.get_env("TERM_DEBUG_KEYS", context.temp_allocator) == "1"
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
			_ = telemetry.grid_dump_write(d.grid_dump_dir, d.dump_seq, pane.id, &pane.session.term, pane.surface_id)
		}
	}
}

// diagnostics_shutdown writes final grid snapshots and the telemetry summary.
// Must run before panes are destroyed.
diagnostics_shutdown :: proc(app: ^Term_App) {
	diagnostics_dump_grids(app)
	telemetry.telemetry_close(&app.diag.tel)
}

// diagnostics_key logs a key event (TERM_DEBUG_KEYS=1).
diagnostics_key :: proc(d: ^Diagnostics, what: string, ev: sdl3.KeyboardEvent) {
	if !d.debug_keys do return
	fmt.eprintfln("term: %s key=0x%x (%q) scancode=%v mod=0x%x repeat=%v", what, u32(ev.key), sdl3.GetKeyName(ev.key), ev.scancode, transmute(u16)ev.mod, ev.repeat)
}

// diagnostics_text logs a text input event (TERM_DEBUG_KEYS=1).
diagnostics_text :: proc(d: ^Diagnostics, text: string) {
	if d.debug_keys do fmt.eprintfln("term: text %q", text)
}

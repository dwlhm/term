package feature_telemetry

// Plain-text snapshots of the visible terminal grid (and its scrollback),
// written on SIGUSR1 and at exit so external stress runners can verify
// rendered content, not just liveness.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import core_terminal "../../core/terminal"
import grid "../../core/terminal/grid"

// Set from the async signal handler; the only state a handler may safely touch.
@(private = "file")
_dump_requested: bool

@(private = "file")
_on_sigusr1 :: proc "c" (_: posix.Signal) {
	intrinsics.atomic_store(&_dump_requested, true)
}

grid_dump_install_signal :: proc() -> bool {
	act: posix.sigaction_t
	act.sa_handler = _on_sigusr1
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {.RESTART}
	return posix.sigaction(.SIGUSR1, &act, nil) == .OK
}

// grid_dump_take_request reports and clears a pending SIGUSR1 dump request.
grid_dump_take_request :: proc() -> bool {
	return intrinsics.atomic_exchange(&_dump_requested, false)
}

// grid_dump_format renders the visible grid as a header line followed by one
// line per row (trailing blanks trimmed). Allocates from `allocator`.
grid_dump_format :: proc(t: ^core_terminal.Terminal, allocator := context.allocator, surface_id: u16 = 0) -> string {
	if t == nil do return ""
	g, _, p := core_terminal.terminal_surface_parts(t, surface_id)
	if g == nil || p == nil do return ""
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"# rows=%d cols=%d cursor=%d,%d alt=%v history=%d\n",
		g.row_count,
		g.col_count,
		p.cursor.row,
		p.cursor.col,
		core_terminal.terminal_in_alt_screen(t) if surface_id == 0 else true,
		core_terminal.terminal_history_count(t) if surface_id == 0 else 0,
	)
	for r in 0 ..< g.row_count do _write_grid_row(&b, t, g, r)
	return strings.to_string(b)
}

// grid_dump_history_format renders the scrollback, oldest row first, one line
// per row (trailing blanks trimmed). Allocates from `allocator`.
grid_dump_history_format :: proc(t: ^core_terminal.Terminal, allocator := context.allocator) -> string {
	if t == nil do return ""
	b := strings.builder_make(allocator)
	for r in -core_terminal.terminal_history_count(t) ..< 0 do _write_row(&b, t, r)
	return strings.to_string(b)
}

@(private = "file")
_write_grid_row :: proc(b: ^strings.Builder, t: ^core_terminal.Terminal, g: ^grid.Grid, r: int) {
	content_end := strings.builder_len(b^)
	for c in 0 ..< g.col_count {
		sc := grid.grid_get_cell(g, r, c)
		if .Wide_Continuation in sc.flags do continue
		if .Has_Egc in sc.flags {
			for rn in core_terminal.terminal_get_egc_runes(t, sc.char) do strings.write_rune(b, rn)
		} else if sc.char > ' ' {
			strings.write_rune(b, sc.char)
		} else {
			strings.write_byte(b, ' ')
			continue
		}
		content_end = strings.builder_len(b^)
	}
	resize(&b.buf, content_end)
	strings.write_byte(b, '\n')
}

@(private = "file")
_write_row :: proc(b: ^strings.Builder, t: ^core_terminal.Terminal, r: int) {
	content_end := strings.builder_len(b^)
	for c in 0 ..< t.cols {
		sc := core_terminal.terminal_get_cell(t, r, c)
		if .Wide_Continuation in sc.flags do continue
		if .Has_Egc in sc.flags {
			for rn in core_terminal.terminal_get_egc_runes(t, sc.char) do strings.write_rune(b, rn)
		} else if sc.char > ' ' {
			strings.write_rune(b, sc.char)
		} else {
			strings.write_byte(b, ' ')
			continue
		}
		content_end = strings.builder_len(b^)
	}
	resize(&b.buf, content_end)
	strings.write_byte(b, '\n')
}

// grid_dump_write writes `<dir>/grid-<seq>-pane<id>.txt` (the screen) and
// `grid-<seq>-pane<id>-history.txt` (the scrollback).
grid_dump_write :: proc(dir: string, seq: int, pane_id: u32, t: ^core_terminal.Terminal, surface_id: u16 = 0) -> bool {
	if len(dir) == 0 || t == nil do return false
	_ = os.make_directory_all(dir)
	screen := grid_dump_format(t, context.allocator, surface_id)
	defer delete(screen)
	history := grid_dump_history_format(t) if surface_id == 0 else ""
	defer if surface_id == 0 do delete(history)
	return _write(fmt.tprintf("%s/grid-%04d-pane%d.txt", dir, seq, pane_id), screen) &&
		_write(fmt.tprintf("%s/grid-%04d-pane%d-history.txt", dir, seq, pane_id), history)
}

@(private = "file")
_write :: proc(path, text: string) -> bool {
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

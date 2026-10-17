package feature_telemetry

// Plain-text snapshots of the visible terminal grid, written on SIGUSR1 and at
// exit so external stress runners can verify rendered content, not just liveness.

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import core_terminal "../../core/terminal"

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
grid_dump_format :: proc(t: ^core_terminal.Terminal, allocator := context.allocator) -> string {
	if t == nil do return ""
	b := strings.builder_make(allocator)
	cur_r, cur_c := core_terminal.terminal_cursor_pos(t)
	fmt.sbprintf(
		&b,
		"# rows=%d cols=%d cursor=%d,%d alt=%v history=%d\n",
		t.rows,
		t.cols,
		cur_r,
		cur_c,
		core_terminal.terminal_in_alt_screen(t),
		core_terminal.terminal_history_count(t),
	)
	for r in 0 ..< t.rows {
		row_start := strings.builder_len(b)
		content_end := row_start
		for c in 0 ..< t.cols {
			sc := core_terminal.terminal_get_cell(t, r, c)
			if .Wide_Continuation in sc.flags do continue
			if .Has_Egc in sc.flags {
				for rn in core_terminal.terminal_get_egc_runes(t, sc.char) do strings.write_rune(&b, rn)
			} else if sc.char > ' ' {
				strings.write_rune(&b, sc.char)
			} else {
				strings.write_byte(&b, ' ')
				continue
			}
			content_end = strings.builder_len(b)
		}
		resize(&b.buf, content_end)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// grid_dump_write writes `<dir>/grid-<seq>-pane<id>.txt`.
grid_dump_write :: proc(dir: string, seq: int, pane_id: u32, t: ^core_terminal.Terminal) -> bool {
	if len(dir) == 0 || t == nil do return false
	_ = os.make_directory_all(dir)
	text := grid_dump_format(t)
	defer delete(text)
	path := fmt.aprintf("%s/grid-%04d-pane%d.txt", dir, seq, pane_id)
	defer delete(path)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

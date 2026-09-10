package app_test

// REAL end-to-end tests: scripted shell sessions through the actual app
// path (input -> pty -> shell -> drain -> parse -> grid -> compile),
// headless: nil window, nil-backend renderer (present skipped by existing
// guards), REAL pty + REAL shell. No SDL, no GPU. Asserts on GRID only,
// never pixels. Failing assertions dump the grid excerpt for diagnosis.

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import posix "core:sys/posix"

import app "../"
import termgrid "../../terminal"
import input "../../platform/input"
import pty "../../platform/pty"

// _e2e_run_until pumps bounded frames (200x5ms convention) until pred
// holds. Returns whether pred held within budget.
_e2e_run_until :: proc(a: ^app.App, pred: proc(a: ^app.App) -> bool, max_frames: int) -> bool {
	for _ in 0..<max_frames {
		_ = app.app_frame(a)
		if pred(a) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return pred(a)
}

// _e2e_grid_contains reports whether any row holds want as a contiguous
// substring (ASCII fast path: content handle stores the rune directly).
_e2e_grid_contains :: proc(t: ^termgrid.Terminal, want: string) -> bool {
	if len(want) == 0 {
		return false
	}
	for r in 0..<t.grid.row_count {
		for start in 0..=(t.grid.col_count - len(want)) {
			ok := true
			for i in 0..<len(want) {
				cell := termgrid.terminal_get_cell(t, r, start + i)
				if u32(cell.content) != u32(want[i]) {
					ok = false
					break
				}
			}
			if ok {
				return true
			}
		}
	}
	return false
}

// _e2e_cursor_advanced reports whether the cursor left the origin.
_e2e_cursor_advanced :: proc(t: ^termgrid.Terminal) -> bool {
	cur := termgrid.terminal_get_cursor(t)
	return cur.row != 0 || cur.col != 0
}

// _e2e_grid_blank reports whether every cell is blank (content == 0).
_e2e_grid_blank :: proc(t: ^termgrid.Terminal) -> bool {
	for r in 0..<t.grid.row_count {
		for cc in 0..<t.grid.col_count {
			if termgrid.terminal_get_cell(t, r, cc).content != 0 {
				return false
			}
		}
	}
	return true
}

// _e2e_grid_nonblank reports whether any cell is non-blank.
_e2e_grid_nonblank :: proc(t: ^termgrid.Terminal) -> bool {
	for r in 0..<t.grid.row_count {
		for cc in 0..<t.grid.col_count {
			if termgrid.terminal_get_cell(t, r, cc).content != 0 {
				return true
			}
		}
	}
	return false
}

// _e2e_styled_red_at finds a consecutive R,E,D triple with non-default
// style. Returns row/col of R and false when absent.
_e2e_styled_red_at :: proc(t: ^termgrid.Terminal) -> (row, col: int, found: bool) {
	for r in 0..<t.grid.row_count {
		for cc in 0..=(t.grid.col_count - 3) {
			c0 := termgrid.terminal_get_cell(t, r, cc)
			c1 := termgrid.terminal_get_cell(t, r, cc + 1)
			c2 := termgrid.terminal_get_cell(t, r, cc + 2)
			if u32(c0.content) != u32('R') { continue }
			if u32(c1.content) != u32('E') { continue }
			if u32(c2.content) != u32('D') { continue }
			if c0.style == 0 || c1.style == 0 || c2.style == 0 {
				continue
			}
			return r, cc, true
		}
	}
	return 0, 0, false
}

// _e2e_exit_banner_present reports whether the bottom row carries the
// exit banner prefix with the given code text.
_e2e_exit_banner_present :: proc(t: ^termgrid.Terminal, code_text: string) -> bool {
	last := t.grid.row_count - 1
	if last < 0 {
		return false
	}
	prefix := "[ process exited ("
	if !_row_matches(t, last, prefix) {
		// Banner may have scrolled if output was long; scan all rows.
		return _e2e_grid_contains(t, code_text)
	}
	return _e2e_grid_contains(t, code_text)
}

// _e2e_dump_grid prints the live grid excerpt (row strings) for diagnosis.
// Blank cells render as spaces; trailing spaces trimmed per row.
_e2e_dump_grid :: proc(t: ^termgrid.Terminal) {
	for r in 0..<t.grid.row_count {
		line := make([]u8, t.grid.col_count)
		defer delete(line)
		for cc in 0..<t.grid.col_count {
			ch := termgrid.terminal_get_cell(t, r, cc).content
			if ch == 0 {
				line[cc] = ' '
			} else if ch < 128 {
				line[cc] = u8(ch)
			} else {
				line[cc] = '?'
			}
		}
		end := len(line)
		for end > 0 && line[end - 1] == ' ' {
			end -= 1
		}
		fmt.printf("e2e grid row %2d: %q\n", r, string(line[:end]))
	}
	cur := termgrid.terminal_get_cursor(t)
	fmt.printf("e2e cursor: row=%d col=%d visible=%v\n", cur.row, cur.col, cur.visible)
}

// _e2e_teardown kills the child, reaps it, and closes the master fd.
// Safe after any spawn (Running or already Exited).
_e2e_teardown :: proc(p: ^pty.Pty) {
	if p.pid > 0 {
		posix.kill(posix.pid_t(p.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(p.pid), &status, posix.Wait_Flags{})
		p.pid = -1
	}
	if p.master >= 0 {
		pty.pty_close(p)
	}
}

// Predicates for _e2e_run_until (no captures; one per condition).
_e2e_pred_hello :: proc(a: ^app.App) -> bool {
	return _e2e_grid_contains(&a.terminal, "hello") && _e2e_cursor_advanced(&a.terminal)
}

_e2e_pred_abc :: proc(a: ^app.App) -> bool {
	return _e2e_grid_contains(&a.terminal, "ABC")
}

_e2e_pred_styled_red :: proc(a: ^app.App) -> bool {
	// SGR colors are live: the proof is a styled R,E,D triple
	// (shell output at col 0). Echo rows carry literal "RED" text
	// with style 0 and never match.
	_, _, found := _e2e_styled_red_at(&a.terminal)
	return found
}

_e2e_pred_blank :: proc(a: ^app.App) -> bool {
	// Interactive sh reprints its prompt after ED, so "all blank" never
	// holds; the ED proof is the fill content gone.
	return !_e2e_grid_contains(&a.terminal, "fillmarker")
}

_e2e_pred_fillmarker :: proc(a: ^app.App) -> bool {
	return _e2e_grid_contains(&a.terminal, "fillmarker")
}

_e2e_pred_x :: proc(a: ^app.App) -> bool {
	return _e2e_grid_contains(&a.terminal, "x")
}

_e2e_pred_exit42 :: proc(a: ^app.App) -> bool {
	return a.pty.state == .Exited && _e2e_exit_banner_present(&a.terminal, "process exited (42")
}

_e2e_pred_nonblank :: proc(a: ^app.App) -> bool {
	return _e2e_grid_nonblank(&a.terminal)
}

@(test)
test_e2e_echo_hello_session :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {}) {
		testing.expect(t, false, "pty_spawn(/bin/sh) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !pty.pty_write(&a.pty, transmute([]u8)string("echo hello\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(echo hello) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_hello, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "grid must spell hello with cursor advanced after echo hello")
	}
}

@(test)
test_e2e_prompt_roundtrip :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {}) {
		testing.expect(t, false, "pty_spawn(/bin/sh) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !pty.pty_write(&a.pty, transmute([]u8)string("printf 'ABC'\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(printf ABC) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_abc, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "grid must contain ABC after printf ABC")
	}
}

@(test)
test_e2e_colored_output :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {}) {
		testing.expect(t, false, "pty_spawn(/bin/sh) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !pty.pty_write(&a.pty, transmute([]u8)string("printf '\\x1b[31mRED\\x1b[0m'\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(colored printf) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_styled_red, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "grid must hold RED with SGR consumed after SGR printf")
		return
	}
	// Output row starts with RED (execution, not echo); that row must
	// not carry the SGR params (consumed, not printed).
	found_out := false
	for r in 0..<a.terminal.grid.row_count {
		if _row_matches(&a.terminal, r, "RED") {
			found_out = true
			// Same row must not contain the literal param text.
			row_has_param := false
			// Scan this row only for "[31m".
			for cc in 0..=(a.terminal.grid.col_count - 4) {
				if u32(termgrid.terminal_get_cell(&a.terminal, r, cc).content) != u32('[') { continue }
				if u32(termgrid.terminal_get_cell(&a.terminal, r, cc + 1).content) != u32('3') { continue }
				if u32(termgrid.terminal_get_cell(&a.terminal, r, cc + 2).content) != u32('1') { continue }
				if u32(termgrid.terminal_get_cell(&a.terminal, r, cc + 3).content) != u32('m') { continue }
				row_has_param = true
				break
			}
			if row_has_param {
				_e2e_dump_grid(&a.terminal)
				testing.expect(t, false, "output RED row must not leak SGR params")
			}
			break
		}
	}
	if !found_out {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "no RED output row found")
	}
	r, cc, red_found := _e2e_styled_red_at(&a.terminal)
	if !red_found {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "RED triple must carry non-default style")
		return
	}
	// R,E,D cells must carry the red-fg style (xterm red 31).
	for k in 0..<3 {
		cell := termgrid.terminal_get_cell(&a.terminal, r, cc + k)
		st := termgrid.style_table_get(&a.terminal.grid.style_table, cell.style)
		testing.expect(t, st.fg == u32(0xFFCD0000), "RED cell fg must be xterm red")
	}
}

@(test)
test_e2e_clear_screen :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {}) {
		testing.expect(t, false, "pty_spawn(/bin/sh) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !pty.pty_write(&a.pty, transmute([]u8)string("echo fillmarker\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(fill) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_fillmarker, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "setup must fill grid with fillmarker before clear")
		return
	}
	if !pty.pty_write(&a.pty, transmute([]u8)string("printf '\\x1b[2J'\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(ED clear) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_blank, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "fillmarker must be gone after ED Entire through the real path")
	}
}

@(test)
test_e2e_typing_roundtrip :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/cat", {}) {
		testing.expect(t, false, "pty_spawn(/bin/cat) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	buf: [input.INPUT_ENCODE_MAX]u8
	n := input.input_encode(input.Input_Event{kind = .Printable, rune = 'x'}, buf[:])
	if n <= 0 {
		testing.expect(t, false, "input_encode('x') must emit bytes")
		return
	}
	if !pty.pty_write(&a.pty, buf[:n]) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(encoded x) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_x, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "grid must contain x after encoded input roundtrip through cat")
	}
}

@(test)
test_e2e_shell_exit_banner :: proc(t: ^testing.T) {
	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, "/bin/sh", {"-c", "exit 42"}) {
		testing.expect(t, false, "pty_spawn(exit 42) must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !_e2e_run_until(&a, _e2e_pred_exit42, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty must reach Exited with exit banner for code 42")
		return
	}
	testing.expect(t, a.pty.state == .Exited, "pty state must be Exited after quick exit")
	if !_e2e_exit_banner_present(&a.terminal, "process exited (42") {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "banner row must be present for exit 42")
	}
}

@(test)
test_e2e_login_shell_smoke :: proc(t: ^testing.T) {
	shell_val, shell_found := os.lookup_env_alloc("SHELL", context.allocator)
	if !shell_found || len(shell_val) == 0 {
		if shell_found {
			delete(shell_val)
		}
		testing.expect(t, true, "SKIP: $SHELL unset or empty; infra env, not a code defect")
		return
	}
	defer delete(shell_val)

	a: app.App
	_bare_app(&a)
	defer _bare_destroy(&a)
	if !pty.pty_spawn(&a.pty, APP_TEST_ROWS, APP_TEST_COLS, shell_val, {}) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "$SHELL spawn must succeed")
		return
	}
	defer _e2e_teardown(&a.pty)

	if !pty.pty_write(&a.pty, transmute([]u8)string("echo $0\n")) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "pty_write(echo $0) must succeed")
		return
	}
	if !_e2e_run_until(&a, _e2e_pred_nonblank, 200) {
		_e2e_dump_grid(&a.terminal)
		testing.expect(t, false, "grid must be non-blank after echo $0 on login shell")
	}
}

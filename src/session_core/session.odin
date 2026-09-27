package session_core

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"
import "core:thread"
import "core:time"

import parser "../parser"
import pty "../platform/pty"
import termgrid "../terminal"

CANARY_PREFIX :: "__TERM_MCP_DONE_"
CANARY_SUFFIX :: "__"

BOOTSTRAP_PREAMBLE :: "stty -echo 2>/dev/null; export PROMPT='' RPROMPT='' PS1=''; precmd_functions=(); chpwd_functions=(); precmd() {}; unsetopt zle 2>/dev/null\n"

// Core_Session encapsulates an isolated PTY, virtual terminal grid, VT parser, and observer port.
// It runs a background drain thread streaming child PTY output into the virtual grid.
Core_Session :: struct {
	id:                      string,
	pty_handle:              pty.Pty,
	term:                    termgrid.Terminal,
	vt_parser:               parser.Parser,
	observer:                Terminal_Observer_Port,
	mode:                    Session_Mode,
	thread:                  ^thread.Thread,
	is_running:              bool,
	lock:                    sync.Mutex,
	last_exit_code:          int,
	command_finished_signal: sync.Cond,

	// Command execution tracking
	has_active_command:      bool,
	command_done:            bool,
	command_exit_code:       int,
	osc_133_detected:        bool,
	start_doc_row:           int,
	cmd_seq:                 int,
	canary_tag_buf:          [64]u8,
	canary_tag_len:          int,
}

// session_create initializes a new PTY session, terminal grid, and VT parser according to config.
session_create :: proc(id: string, cfg: Session_Config) -> (^Core_Session, bool) {
	r := cfg.rows if cfg.rows > 0 else pty.PTY_DEFAULT_ROWS
	c_cols := cfg.cols if cfg.cols > 0 else pty.PTY_DEFAULT_COLS

	prog := cfg.shell
	if len(prog) == 0 {
		if env_shell, has_shell := os.lookup_env("SHELL", context.temp_allocator); has_shell && len(env_shell) > 0 {
			prog = env_shell
		} else if os.exists("/bin/zsh") {
			prog = "/bin/zsh"
		} else {
			prog = "/bin/sh"
		}
	}

	argv := []string{"-l"}
	s := new(Core_Session)
	s.id = strings.clone(id)
	s.mode = cfg.mode
	s.observer = cfg.observer

	if !pty.pty_spawn(&s.pty_handle, r, c_cols, prog, argv, cfg.cwd) {
		delete(s.id)
		free(s)
		return nil, false
	}

	termgrid.terminal_init(&s.term, r, c_cols)
	parser.parser_init(&s.vt_parser)

	s.last_exit_code = 0
	s.has_active_command = false
	s.command_done = false
	s.command_exit_code = 0
	s.osc_133_detected = false
	s.start_doc_row = 0

	if cfg.mode == .Fast_Headless {
		pty.pty_write(&s.pty_handle, transmute([]u8)string(BOOTSTRAP_PREAMBLE))
		// Briefly drain startup echo / prompt from PTY
		drain_buf: [4096]u8
		for _ in 0 ..< 3 {
			if pty.pty_wait_readable(&s.pty_handle, 5) {
				n, _ := pty.pty_drain(&s.pty_handle, drain_buf[:], len(drain_buf))
				if n <= 0 do break
			} else {
				break
			}
		}
		termgrid.terminal_reset(&s.term)
	}

	session_start_drain_loop(s)
	return s, true
}

// session_start_drain_loop launches the background thread reading PTY output.
session_start_drain_loop :: proc(s: ^Core_Session) {
	if s == nil || s.thread != nil {
		return
	}
	s.is_running = true
	s.thread = thread.create(session_drain_worker)
	if s.thread != nil {
		s.thread.data = s
		thread.start(s.thread)
	}
}

// session_drain_worker is the background pump reading child output into the virtual grid.
session_drain_worker :: proc(t: ^thread.Thread) {
	s := (^Core_Session)(t.data)
	if s == nil {
		return
	}

	drain_buf: [64 * 1024]u8

	for sync.atomic_load(&s.is_running) {
		if s.pty_handle.master >= 0 && s.pty_handle.state == .Running {
			if pty.pty_wait_readable(&s.pty_handle, 5) {
				sync.mutex_lock(&s.lock)
				n, eof := pty.pty_drain(&s.pty_handle, drain_buf[:], len(drain_buf))
				if n > 0 {
					parser.parse_chunk(&s.vt_parser, &s.term, drain_buf[:n])

					// Observer notifications: damage
					if s.observer.on_damage != nil {
						min_r := -1
						max_r := -1
						for r in 0 ..< s.term.damage.row_count {
							if r < len(s.term.damage.dirty_rows) {
								dr := &s.term.damage.dirty_rows[r]
								if dr.full || dr.span_count > 0 {
									if min_r == -1 do min_r = r
									max_r = r
								}
							}
						}
						if min_r != -1 {
							s.observer.on_damage(s.observer.user_data, min_r, 0, max_r, s.term.grid.col_count - 1)
						}
					}

					// Observer notifications: title change
					if s.observer.on_title_change != nil && s.term.title_dirty {
						title := termgrid.terminal_take_title(&s.term)
						s.observer.on_title_change(s.observer.user_data, title)
					}

					// Observer notifications: bell
					if s.observer.on_bell != nil && s.term.bell_event {
						s.term.bell_event = false
						s.observer.on_bell(s.observer.user_data)
					}

					if s.has_active_command {
						_check_command_completion(s, drain_buf[:n])
					}
				}

				if eof {
					_ = pty.pty_poll_exit(&s.pty_handle)
					s.last_exit_code = s.pty_handle.exit_code
					if s.observer.on_exit != nil {
						s.observer.on_exit(s.observer.user_data, s.last_exit_code)
					}
					if s.has_active_command {
						s.command_done = true
						s.command_exit_code = s.pty_handle.exit_code
						sync.cond_broadcast(&s.command_finished_signal)
					}
				}
				sync.mutex_unlock(&s.lock)
			} else {
				sync.mutex_lock(&s.lock)
				if pty.pty_poll_exit(&s.pty_handle) {
					s.last_exit_code = s.pty_handle.exit_code
					if s.observer.on_exit != nil {
						s.observer.on_exit(s.observer.user_data, s.last_exit_code)
					}
					if s.has_active_command {
						s.command_done = true
						s.command_exit_code = s.pty_handle.exit_code
						sync.cond_broadcast(&s.command_finished_signal)
					}
				}
				sync.mutex_unlock(&s.lock)
			}
		} else {
			time.sleep(5 * time.Millisecond)
		}
	}
}

// _extract_canary_exit_code parses integer exit code from canary string, rejecting echoed unexpanded $?
@(private="file")
_extract_canary_exit_code :: proc(s: string, tag: string) -> (exit_code: int, ok: bool) {
	if len(tag) == 0 do return 0, false
	idx := strings.index(s, tag)
	if idx == -1 do return 0, false
	tail := s[idx + len(tag):]
	if len(tail) == 0 do return 0, false
	if tail[0] < '0' || tail[0] > '9' {
		// Not a digit (e.g. '$?' from command echo), ignore!
		return 0, false
	}
	end_idx := strings.index(tail, CANARY_SUFFIX)
	if end_idx == -1 do return 0, false
	for i in 0 ..< end_idx {
		if tail[i] < '0' || tail[i] > '9' {
			return 0, false
		}
	}
	v, parse_ok := strconv.parse_int(tail[:end_idx])
	if !parse_ok do return 0, false
	return int(v), true
}

// _check_command_completion checks chunk bytes and grid cells for OSC 133 or canary sentinel.
@(private="file")
_check_command_completion :: proc(s: ^Core_Session, chunk: []u8) {
	// Track OSC 133 D event
	if strings.contains(string(chunk), "\x1b]133;D") {
		s.osc_133_detected = true
	}

	tag := string(s.canary_tag_buf[:s.canary_tag_len])

	// 1. Check canary token in chunk (ignoring input echo)
	if code, ok := _extract_canary_exit_code(string(chunk), tag); ok {
		s.command_exit_code = code
		s.command_done = true
		sync.cond_broadcast(&s.command_finished_signal)
		return
	}

	// 2. Check canary token in current / recent grid rows
	cols := s.term.grid.col_count
	cur_row := s.term.cursor.row
	min_check_row := max(0, cur_row - 2)

	row_buf: [256]u8
	for r := min_check_row; r <= cur_row; r += 1 {
		len_row := 0
		for c := 0; c < cols && len_row < len(row_buf) - 1; c += 1 {
			cell := termgrid.grid_get_cell(&s.term.grid, r, c)
			if cell.content == 0 || (u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation)) != 0 {
				continue
			}
			if !termgrid.content_is_grapheme(cell.content) {
				rn := rune(cell.content)
				if rn >= 32 && rn < 127 {
					row_buf[len_row] = u8(rn)
					len_row += 1
				}
			}
		}
		row_str := string(row_buf[:len_row])
		if code, ok := _extract_canary_exit_code(row_str, tag); ok {
			s.command_exit_code = code
			s.command_done = true
			sync.cond_broadcast(&s.command_finished_signal)
			return
		}
	}
}

// session_stop halts the drain thread and terminates the child process group.
session_stop :: proc(s: ^Core_Session) {
	if s == nil {
		return
	}

	sync.atomic_store(&s.is_running, false)

	// Wake up any thread waiting on command completion
	sync.cond_broadcast(&s.command_finished_signal)

	// Terminate child process group
	if s.pty_handle.pid > 1 && s.pty_handle.state == .Running {
		posix.kill(posix.pid_t(-s.pty_handle.pid), .SIGTERM)
	}

	// Close PTY master to break any blocking read
	pty.pty_close(&s.pty_handle)

	// Join background thread
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}

	// Final reap child if still alive
	if s.pty_handle.pid > 1 {
		posix.kill(posix.pid_t(-s.pty_handle.pid), .SIGKILL)
		status: c.int
		posix.waitpid(posix.pid_t(s.pty_handle.pid), &status, posix.Wait_Flags{.NOHANG})
	}
}

// session_destroy dismantles all terminal and parser resources.
session_destroy :: proc(s: ^Core_Session) {
	if s == nil {
		return
	}
	session_stop(s)
	termgrid.terminal_destroy(&s.term)
	parser.parser_destroy(&s.vt_parser)
	delete(s.id)
}

// session_extract_screen captures a clean 2D visual viewport snapshot from the virtual grid.
session_extract_screen :: proc(s: ^Core_Session, scrollback_lines: int = 0, allocator := context.allocator) -> string {
	if s == nil {
		return ""
	}
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)

	b := strings.builder_make(allocator)
	sb_len := termgrid.scrollback_len(&s.term.scrollback)
	cols := s.term.grid.col_count
	rows := s.term.grid.row_count

	start_row := sb_len
	if scrollback_lines > 0 {
		start_row = max(0, sb_len - scrollback_lines)
	}
	end_row := sb_len + rows - 1

	for r := start_row; r <= end_row; r += 1 {
		if r > start_row {
			strings.write_rune(&b, '\n')
		}
		last_col := -1
		for c := cols - 1; c >= 0; c -= 1 {
			cell := termgrid.terminal_view_get_document_cell(&s.term, termgrid.Terminal_Point{row = r, col = c})
			if cell.content != 0 && cell.content != termgrid.Content_Handle(' ') {
				last_col = c
				break
			}
		}
		for c := 0; c <= last_col; c += 1 {
			cell := termgrid.terminal_view_get_document_cell(&s.term, termgrid.Terminal_Point{row = r, col = c})
			if cell.content == 0 || (u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation)) != 0 {
				continue
			}
			if !termgrid.content_is_grapheme(cell.content) {
				strings.write_rune(&b, rune(cell.content))
			} else {
				idx := int(cell.content - termgrid.CONTENT_GRAPHEME_BASE)
				if idx >= 0 && idx < termgrid.GRAPHEME_STORE_CAP {
					cluster := s.term.grapheme_store.entries[idx]
					count := min(int(cluster.rune_count), termgrid.GRAPHEME_INLINE_CAP)
					for i in 0 ..< count {
						strings.write_rune(&b, cluster.runes[i])
					}
				} else {
					strings.write_rune(&b, termgrid.grapheme_resolve_base(cell.content, &s.term.grapheme_store))
				}
			}
		}
	}
	return strings.to_string(b)
}

// session_send_input writes raw bytes directly into the child PTY master.
session_send_input :: proc(s: ^Core_Session, text: string) -> (int, bool) {
	if s == nil || len(text) == 0 {
		return 0, false
	}
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)

	ok := pty.pty_write(&s.pty_handle, transmute([]u8)text)
	return len(text) if ok else 0, ok
}

// session_send_key sends an interactive control keypress sequence.
session_send_key :: proc(s: ^Core_Session, key: string) -> bool {
	seq := ""
	switch key {
	case "Enter":     seq = "\r"
	case "Tab":       seq = "\t"
	case "Backspace": seq = "\x7f"
	case "Escape":    seq = "\x1b"
	case "Ctrl+C":    seq = "\x03"
	case "Ctrl+D":    seq = "\x04"
	case "Ctrl+Z":    seq = "\x1a"
	case "Up":        seq = "\x1b[A"
	case "Down":      seq = "\x1b[B"
	case "Right":     seq = "\x1b[C"
	case "Left":      seq = "\x1b[D"
	case:             return false
	}
	_, ok := session_send_input(s, seq)
	return ok
}

// session_resize updates both the PTY window size and terminal grid dimensions.
session_resize :: proc(s: ^Core_Session, rows, cols: int) -> bool {
	if s == nil || rows <= 0 || cols <= 0 {
		return false
	}
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)

	pty_ok := pty.pty_set_winsize(&s.pty_handle, rows, cols)
	termgrid.terminal_resize(&s.term, rows, cols)
	return pty_ok
}

// session_run_command executes a command synchronously, detecting completion via OSC 133 or canary sentinel.
session_run_command :: proc(s: ^Core_Session, command: string, timeout_ms: int = 30000, allocator := context.allocator) -> (output: string, exit_code: int, completed: bool) {
	if s == nil {
		return "", -1, false
	}

	sync.mutex_lock(&s.lock)

	// Record start document position
	sb_len := termgrid.scrollback_len(&s.term.scrollback)
	start_doc_row := sb_len + s.term.cursor.row
	s.start_doc_row = start_doc_row

	s.has_active_command = true
	s.command_done = false
	s.command_exit_code = 0
	s.osc_133_detected = false

	s.cmd_seq += 1
	seq := s.cmd_seq
	tag_str := fmt.tprintf("%s%d_", CANARY_PREFIX, seq)
	copy(s.canary_tag_buf[:], tag_str)
	s.canary_tag_len = len(tag_str)
	tag := string(s.canary_tag_buf[:s.canary_tag_len])

	// Transmit command with sentinel suffix
	cmd_payload := fmt.tprintf("%s ; echo \"%s\"$?\"%s\"\n", command, tag, CANARY_SUFFIX)
	pty.pty_write(&s.pty_handle, transmute([]u8)cmd_payload)

	// Wait for completion or timeout
	deadline := time.now()
	timeout_dur := time.Duration(timeout_ms) * time.Millisecond
	deadline = time.time_add(deadline, timeout_dur)

	for !s.command_done {
		now := time.now()
		remaining := time.diff(now, deadline)
		if remaining <= 0 {
			break
		}
		// Wait with 50ms intervals so we don't hang if condition wasn't fired
		wait_chunk := min(remaining, 50 * time.Millisecond)
		sync.cond_wait_with_timeout(&s.command_finished_signal, &s.lock, wait_chunk)
	}

	completed = s.command_done
	exit_code = s.command_exit_code
	s.has_active_command = false

	if !completed {
		// Send SIGINT / Ctrl+C to abort hanging child
		pty.pty_write(&s.pty_handle, []u8{0x03})
	}

	// Extract lines between start_doc_row and end of document
	current_sb_len := termgrid.scrollback_len(&s.term.scrollback)
	total_rows := current_sb_len + s.term.grid.row_count
	cols := s.term.grid.col_count

	// Adjust start_doc_row if scrollback evicted rows
	clamped_start := clamp(start_doc_row, 0, total_rows - 1)

	out_b := strings.builder_make(allocator)
	line_count := 0

	for r := clamped_start; r < total_rows; r += 1 {
		last_col := -1
		for c := cols - 1; c >= 0; c -= 1 {
			cell := termgrid.terminal_view_get_document_cell(&s.term, termgrid.Terminal_Point{row = r, col = c})
			if cell.content != 0 && cell.content != termgrid.Content_Handle(' ') {
				last_col = c
				break
			}
		}

		line_b := strings.builder_make(context.temp_allocator)
		for c := 0; c <= last_col; c += 1 {
			cell := termgrid.terminal_view_get_document_cell(&s.term, termgrid.Terminal_Point{row = r, col = c})
			if cell.content == 0 || (u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation)) != 0 {
				continue
			}
			if !termgrid.content_is_grapheme(cell.content) {
				strings.write_rune(&line_b, rune(cell.content))
			} else {
				idx := int(cell.content - termgrid.CONTENT_GRAPHEME_BASE)
				if idx >= 0 && idx < termgrid.GRAPHEME_STORE_CAP {
					cluster := s.term.grapheme_store.entries[idx]
					count := min(int(cluster.rune_count), termgrid.GRAPHEME_INLINE_CAP)
					for i in 0 ..< count {
						strings.write_rune(&line_b, cluster.runes[i])
					}
				} else {
					strings.write_rune(&line_b, termgrid.grapheme_resolve_base(cell.content, &s.term.grapheme_store))
				}
			}
		}

		line := strings.to_string(line_b)

		// Sentinel line encountered: finish
		if code, ok := _extract_canary_exit_code(line, tag); ok {
			if completed {
				exit_code = code
			}
			break
		}

		// Skip echoed command line or prompt containing unexpanded canary prefix
		if strings.contains(line, command) || strings.contains(line, CANARY_PREFIX) {
			continue
		}

		if line_count > 0 {
			strings.write_rune(&out_b, '\n')
		}
		strings.write_string(&out_b, line)
		line_count += 1
	}

	sync.mutex_unlock(&s.lock)

	output = strings.trim_right_space(strings.to_string(out_b))
	return output, exit_code, completed
}

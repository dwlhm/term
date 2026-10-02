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

HEADLESS_BOOTSTRAP_TIMEOUT_MS :: 5000
HEADLESS_READY_MARKER :: "\x1e__TERM_MCP_READY__\x1f"
BOOTSTRAP_PREAMBLE :: "stty -echo 2>/dev/null && export PROMPT='' RPROMPT='' PS1='' PS2='' PROMPT_COMMAND=''"
BOOTSTRAP_ZSH_PREAMBLE :: " && precmd_functions=() && chpwd_functions=() && precmd() {} && unsetopt zle"

Command_Record :: struct {
	id:           int,
	command:      string,
	started_at:   time.Time,
	duration_ms:  int,
	exit_code:    int,
	completed:    bool,
	total_lines:  int,
	summary:      string,
	output_lines: [dynamic]string,
}

// Core_Session encapsulates an isolated PTY, virtual terminal grid, VT parser, and observer port.
// It runs a background drain thread streaming child PTY output into the virtual grid.
Core_Session :: struct {
	id:                      string,
	cwd:                     string,
	gui_tab_id:              u32,
	// GUI launch arguments retain the Backend's borrowed lifetime contract.
	gui_prog:                string,
	gui_argv:                []string,
	title_buf:               [128]u8,
	title_len:               int,
	title_override_buf:      [128]u8,
	title_override_len:      int,
	is_busy:                 bool,
	active_cmd:              string,
	command_history:         [dynamic]Command_Record,
	pty_handle:              pty.Pty,
	term:                    termgrid.Terminal,
	vt_parser:               parser.Parser,
	observer:                Terminal_Observer_Port,
	mode:                    Session_Mode,
	thread:                  ^thread.Thread,
	is_running:              bool,
	is_detached:             bool,
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

	argv: []string
	if cfg.mode == .Fast_Headless {
		if strings.contains(prog, "zsh") {
			argv = []string{"--no-rcs"}
		} else if strings.contains(prog, "bash") {
			argv = []string{"--norc", "--noprofile"}
		}
	} else {
		argv = []string{"-l"}
	}
	s := new(Core_Session)
	s.id = strings.clone(id)
	if len(cfg.cwd) > 0 {
		s.cwd = strings.clone(cfg.cwd)
	} else {
		curr_dir, err := os.get_working_directory(context.allocator)
		if err == nil && len(curr_dir) > 0 {
			s.cwd = curr_dir
		} else {
			s.cwd = strings.clone(".")
		}
	}
	s.is_busy = false
	s.active_cmd = ""
	s.command_history = make([dynamic]Command_Record)
	s.mode = cfg.mode
	s.observer = cfg.observer

	if !pty.pty_spawn(&s.pty_handle, r, c_cols, prog, argv, cfg.cwd) {
		delete(s.id)
		delete(s.cwd)
		delete(s.command_history)
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
		if !_session_bootstrap_headless(s, prog) {
			session_destroy(s)
			free(s)
			return nil, false
		}
		termgrid.terminal_reset(&s.term)
	}

	if !session_start_drain_loop(s) {
		session_destroy(s)
		free(s)
		return nil, false
	}
	return s, true
}

// Acknowledge shell configuration before exposing the PTY to command execution.
// The marker is assembled by printf so terminal input echo cannot acknowledge readiness.
@(private="file")
_session_bootstrap_headless :: proc(s: ^Core_Session, prog: string) -> bool {
	shell_preamble := BOOTSTRAP_ZSH_PREAMBLE if strings.contains(prog, "zsh") else ""
	payload := fmt.tprintf("%s%s && printf '\\036%%s%%s\\037' '__TERM_MCP_' 'READY__'\n", BOOTSTRAP_PREAMBLE, shell_preamble)
	deadline := time.time_add(time.now(), HEADLESS_BOOTSTRAP_TIMEOUT_MS * time.Millisecond)
	if !pty.pty_write(&s.pty_handle, transmute([]u8)payload) do return false

	drain_buf: [4096]u8
	marker := string(HEADLESS_READY_MARKER)
	matched := 0
	for {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 do return false
		wait_ms := max(1, int(time.duration_milliseconds(remaining)))
		if !pty.pty_wait_readable(&s.pty_handle, wait_ms) {
			if pty.pty_poll_exit(&s.pty_handle) do return false
			continue
		}
		n, eof := pty.pty_drain(&s.pty_handle, drain_buf[:], len(drain_buf))
		ready := false
		for byte in drain_buf[:n] {
			if byte == marker[matched] {
				matched += 1
				if matched == len(marker) {
					ready = true
					break
				}
			} else {
				// The initial control byte occurs nowhere else in the marker.
				matched = 1 if byte == marker[0] else 0
			}
		}
		if eof || pty.pty_poll_exit(&s.pty_handle) do return false
		if ready do return true
	}
}

@(private="file", thread_local)
_session_response_owner: ^Core_Session

@(private="file")
_session_response_cb :: proc(data: []u8) {
	s := _session_response_owner
	if s != nil && s.pty_handle.master >= 0 && s.pty_handle.state == .Running {
		_ = pty.pty_write(&s.pty_handle, data)
	}
}

// session_start_drain_loop launches the background thread reading PTY output.
session_start_drain_loop :: proc(s: ^Core_Session) -> bool {
	if s == nil do return false
	if s.thread != nil do return sync.atomic_load(&s.is_running)
	s.vt_parser.response_cb = _session_response_cb
	if s.is_detached {
		// A transferred parser must never call the former GUI backend or clipboard.
		s.vt_parser.clipboard_cb = nil
		s.vt_parser.clipboard_read_cb = nil
		s.vt_parser.clipboard_read_user_data = nil
	}
	s.thread = thread.create(session_drain_worker)
	if s.thread == nil {
		sync.atomic_store(&s.is_running, false)
		return false
	}
	s.thread.data = s
	sync.atomic_store(&s.is_running, true)
	thread.start(s.thread)
	return true
}

// session_drain_worker is the background pump reading child output into the virtual grid.
session_drain_worker :: proc(t: ^thread.Thread) {
	s := (^Core_Session)(t.data)
	if s == nil {
		return
	}
	_session_response_owner = s
	defer _session_response_owner = nil

	drain_buf: [64 * 1024]u8

	for sync.atomic_load(&s.is_running) {
		if s.pty_handle.master >= 0 && s.pty_handle.state == .Running {
			if pty.pty_wait_readable(&s.pty_handle, 5) {
				sync.mutex_lock(&s.lock)
				n, eof := pty.pty_drain(&s.pty_handle, drain_buf[:], len(drain_buf))
				if n > 0 {
					parser.parse_chunk(&s.vt_parser, &s.term, drain_buf[:n])

					// Observer notifications: damage
					if !s.is_detached && s.observer.on_damage != nil {
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
					if !s.is_detached && s.observer.on_title_change != nil && s.term.title_dirty {
						title := termgrid.terminal_take_title(&s.term)
						s.observer.on_title_change(s.observer.user_data, title)
					}

					// Observer notifications: bell
					if !s.is_detached && s.observer.on_bell != nil && s.term.bell_event {
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
					if !s.is_detached && s.observer.on_exit != nil {
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
					if !s.is_detached && s.observer.on_exit != nil {
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
	rem := s
	for {
		idx := strings.index(rem, tag)
		if idx == -1 do return 0, false
		tail := rem[idx + len(tag):]
		if len(tail) > 0 && tail[0] >= '0' && tail[0] <= '9' {
			end_idx := strings.index(tail, CANARY_SUFFIX)
			if end_idx != -1 {
				all_digits := true
				for i in 0 ..< end_idx {
					if tail[i] < '0' || tail[i] > '9' {
						all_digits = false
						break
					}
				}
				if all_digits {
					if v, parse_ok := strconv.parse_int(tail[:end_idx]); parse_ok {
						return int(v), true
					}
				}
			}
		}
		rem = tail
	}
	return 0, false
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
	min_check_row := max(0, cur_row - 4)

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

// session_stop_drain_loop halts the background thread while preserving PTY fd and grid state.
session_stop_drain_loop :: proc(s: ^Core_Session) {
	if s == nil || s.thread == nil {
		return
	}
	sync.atomic_store(&s.is_running, false)
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
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
		posix.waitpid(posix.pid_t(s.pty_handle.pid), &status, posix.Wait_Flags{})
		s.pty_handle.state = .Exited
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
	if len(s.cwd) > 0 {
		delete(s.cwd)
		s.cwd = ""
	}
	if len(s.active_cmd) > 0 {
		delete(s.active_cmd)
		s.active_cmd = ""
	}
	for &rec in s.command_history {
		delete(rec.command)
		if len(rec.summary) > 0 {
			delete(rec.summary)
		}
		for line in rec.output_lines {
			delete(line)
		}
		delete(rec.output_lines)
	}
	delete(s.command_history)
	s.command_history = nil
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

// session_filter_output_noise strips leading/trailing empty lines, compacts blank lines,
// deduplicates consecutive identical lines, and truncates head/tail if > max_lines.
session_filter_output_noise :: proc(lines: []string, max_lines: int = 250, allocator := context.allocator) -> (output: string, total_lines: int, truncated: bool) {
	if len(lines) == 0 {
		return "", 0, false
	}

	// 1. Strip leading and trailing empty lines
	start := 0
	for start < len(lines) && len(strings.trim_space(lines[start])) == 0 {
		start += 1
	}
	if start >= len(lines) {
		return "", 0, false
	}

	end := len(lines) - 1
	for end >= start && len(strings.trim_space(lines[end])) == 0 {
		end -= 1
	}

	stripped := lines[start : end + 1]

	// 2. Compact runs of consecutive empty lines to at most 1 empty line
	compacted := make([dynamic]string, context.temp_allocator)
	prev_empty := false
	for l in stripped {
		is_empty := len(strings.trim_space(l)) == 0
		if is_empty {
			if !prev_empty {
				append(&compacted, "")
				prev_empty = true
			}
		} else {
			append(&compacted, l)
			prev_empty = false
		}
	}

	// 3. Deduplicate consecutive identical lines (if repeated > 2 times, output original + [... repeated N times ...])
	deduped := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(compacted) {
		curr := compacted[i]
		is_empty := len(strings.trim_space(curr)) == 0
		if is_empty {
			append(&deduped, curr)
			i += 1
			continue
		}

		run_count := 1
		for i + run_count < len(compacted) && compacted[i + run_count] == curr {
			run_count += 1
		}

		repeat_times := run_count - 1
		if repeat_times > 2 {
			append(&deduped, curr)
			marker := fmt.tprintf("[... repeated %d times ...]", repeat_times)
			append(&deduped, marker)
		} else {
			for k in 0 ..< run_count {
				append(&deduped, curr)
			}
		}
		i += run_count
	}

	total_lines = len(deduped)

	// 4. Head/Tail truncation: if total lines > max_lines (default 250), keep first 125 and last 125 lines
	b := strings.builder_make(allocator)
	if max_lines > 0 && total_lines > max_lines {
		truncated = true
		head_count := max_lines / 2
		tail_count := max_lines - head_count
		trunc_count := total_lines - (head_count + tail_count)

		for j in 0 ..< head_count {
			if j > 0 do strings.write_rune(&b, '\n')
			strings.write_string(&b, deduped[j])
		}

		strings.write_string(&b, fmt.tprintf("\n[... %d lines truncated to save tokens ...]\n", trunc_count))

		tail_start := total_lines - tail_count
		for j in tail_start ..< total_lines {
			strings.write_string(&b, deduped[j])
			if j < total_lines - 1 do strings.write_rune(&b, '\n')
		}
	} else {
		truncated = false
		for j in 0 ..< total_lines {
			if j > 0 do strings.write_rune(&b, '\n')
			strings.write_string(&b, deduped[j])
		}
	}

	output = strings.to_string(b)
	return output, total_lines, truncated
}

// session_run_command executes a command synchronously, detecting completion via OSC 133 or canary sentinel.
session_run_command :: proc(s: ^Core_Session, command: string, timeout_ms: int = 30000, allocator := context.allocator) -> (output: string, exit_code: int, completed: bool, total_lines: int, truncated: bool) {
	if s == nil {
		return "", -1, false, 0, false
	}

	sync.mutex_lock(&s.lock)

	start_time := time.now()
	s.is_busy = true
	if len(s.active_cmd) > 0 {
		delete(s.active_cmd)
	}
	s.active_cmd = strings.clone(command)

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

	raw_lines := make([dynamic]string, context.allocator)

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

		// Skip unexpanded canary prefix
		if strings.contains(line, CANARY_PREFIX) {
			continue
		}

		append(&raw_lines, strings.clone(line, context.allocator))
	}

	duration_ms := int(time.duration_milliseconds(time.diff(start_time, time.now())))

	summary_str := ""
	for l in raw_lines {
		trimmed := strings.trim_space(l)
		if len(trimmed) > 0 {
			max_len := min(len(trimmed), 80)
			summary_str = strings.clone(trimmed[:max_len], context.allocator)
			break
		}
	}

	rec: Command_Record
	rec.id = s.cmd_seq
	rec.command = strings.clone(command, context.allocator)
	rec.started_at = start_time
	rec.duration_ms = duration_ms
	rec.exit_code = exit_code
	rec.completed = completed
	rec.total_lines = len(raw_lines)
	rec.summary = summary_str
	rec.output_lines = raw_lines
	append(&s.command_history, rec)

	output, total_lines, truncated = session_filter_output_noise(raw_lines[:], 250, allocator)

	s.is_busy = false
	if len(s.active_cmd) > 0 {
		delete(s.active_cmd)
		s.active_cmd = ""
	}

	sync.mutex_unlock(&s.lock)

	return output, exit_code, completed, total_lines, truncated
}

// session_get_command_output retrieves buffered raw output lines with offset, limit, and grep filtering.
session_get_command_output :: proc(s: ^Core_Session, cmd_id: int, offset: int, limit: int, grep_filter: string, allocator := context.allocator) -> (output: string, total_matched: int, total_lines: int, ok: bool) {
	if s == nil {
		return "", 0, 0, false
	}
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)

	if len(s.command_history) == 0 {
		return "", 0, 0, false
	}

	rec_idx := -1
	if cmd_id <= 0 {
		rec_idx = len(s.command_history) - 1
	} else {
		for i in 0 ..< len(s.command_history) {
			if s.command_history[i].id == cmd_id {
				rec_idx = i
				break
			}
		}
	}

	if rec_idx == -1 {
		return "", 0, 0, false
	}

	rec := &s.command_history[rec_idx]
	total_lines = len(rec.output_lines)

	eff_limit := limit if limit > 0 else 200

	if len(grep_filter) > 0 {
		matched := make([dynamic]string, context.temp_allocator)
		grep_lower := strings.to_lower(grep_filter, context.temp_allocator)
		for line in rec.output_lines {
			line_lower := strings.to_lower(line, context.temp_allocator)
			if strings.contains(line_lower, grep_lower) {
				append(&matched, line)
			}
		}
		total_matched = len(matched)
		start := clamp(offset, 0, total_matched)
		end := min(start + eff_limit, total_matched)

		b := strings.builder_make(allocator)
		for i in start ..< end {
			if i > start do strings.write_rune(&b, '\n')
			strings.write_string(&b, matched[i])
		}
		output = strings.to_string(b)
		return output, total_matched, total_lines, true
	} else {
		total_matched = total_lines
		start := clamp(offset, 0, total_matched)
		end := min(start + eff_limit, total_matched)

		b := strings.builder_make(allocator)
		for i in start ..< end {
			if i > start do strings.write_rune(&b, '\n')
			strings.write_string(&b, rec.output_lines[i])
		}
		output = strings.to_string(b)
		return output, total_matched, total_lines, true
	}
}

// Session_Registry provides thread-safe storage and tracking for persistent Core_Session instances.
Session_Registry :: struct {
	sessions:       map[string]^Core_Session,
	detached_order: [dynamic]string,
	lock:           sync.Mutex,
}

// session_registry_init initializes the registry map and dynamic tracking slice.
session_registry_init :: proc(reg: ^Session_Registry) {
	if reg == nil do return
	reg.sessions = make(map[string]^Core_Session)
	reg.detached_order = make([dynamic]string)
}

// session_registry_clear keeps the registry reusable, including the global singleton.
session_registry_clear :: proc(reg: ^Session_Registry) {
	if reg == nil do return
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)
	for _, s in reg.sessions {
		session_destroy(s)
		free(s)
	}
	clear(&reg.sessions)
	for id in reg.detached_order {
		delete(id)
	}
	clear(&reg.detached_order)
}

// session_registry_destroy frees all tracked sessions and internal structures.
session_registry_destroy :: proc(reg: ^Session_Registry) {
	if reg == nil do return
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	for _, s in reg.sessions {
		session_destroy(s)
		free(s)
	}
	delete(reg.sessions)
	reg.sessions = nil
	for id in reg.detached_order {
		delete(id)
	}
	delete(reg.detached_order)
	reg.detached_order = nil
}

// session_registry_register registers a Core_Session into the registry thread-safely.
session_registry_register :: proc(reg: ^Session_Registry, session: ^Core_Session) -> bool {
	if reg == nil || session == nil || len(session.id) == 0 {
		return false
	}
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	if session.id in reg.sessions {
		return false
	}
	reg.sessions[session.id] = session
	if session.is_detached {
		append(&reg.detached_order, strings.clone(session.id))
	}
	return true
}

// session_registry_unregister removes and returns a session by ID without destroying it.
session_registry_unregister :: proc(reg: ^Session_Registry, id: string) -> ^Core_Session {
	if reg == nil || len(id) == 0 {
		return nil
	}
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	s, ok := reg.sessions[id]
	if !ok do return nil
	delete_key(&reg.sessions, id)

	for i := 0; i < len(reg.detached_order); i += 1 {
		if reg.detached_order[i] == id {
			delete(reg.detached_order[i])
			ordered_remove(&reg.detached_order, i)
			break
		}
	}
	return s
}

// session_registry_lookup returns an active session by ID without unregistering it.
session_registry_lookup :: proc(reg: ^Session_Registry, id: string) -> ^Core_Session {
	if reg == nil || len(id) == 0 {
		return nil
	}
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	s, ok := reg.sessions[id]
	return s if ok else nil
}

// session_registry_detached_count reports the full count without a fixed output capacity.
session_registry_detached_count :: proc(reg: ^Session_Registry) -> int {
	if reg == nil do return 0
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)
	count := 0
	for _, s in reg.sessions {
		if s.is_detached do count += 1
	}
	return count
}

// session_registry_list_detached writes IDs of detached sessions into out, returning the count.
session_registry_list_detached :: proc(reg: ^Session_Registry, out: []string) -> int {
	if reg == nil || len(out) == 0 {
		return 0
	}
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	count := 0
	for i := len(reg.detached_order) - 1; i >= 0 && count < len(out); i -= 1 {
		id := reg.detached_order[i]
		if s, ok := reg.sessions[id]; ok && s.is_detached {
			out[count] = s.id
			count += 1
		}
	}
	return count
}

// session_registry_pop_latest_detached unregisters and returns the most recently detached session.
session_registry_pop_latest_detached :: proc(reg: ^Session_Registry) -> ^Core_Session {
	if reg == nil {
		return nil
	}
	sync.mutex_lock(&reg.lock)
	defer sync.mutex_unlock(&reg.lock)

	for len(reg.detached_order) > 0 {
		id := pop(&reg.detached_order)
		defer delete(id)
		if s, ok := reg.sessions[id]; ok {
			delete_key(&reg.sessions, id)
			s.is_detached = false
			return s
		}
	}
	return nil
}

@(private="file")
_global_session_registry: Session_Registry
@(private="file")
_global_session_registry_init_once: bool
@(private="file")
_global_session_registry_lock: sync.Mutex

// session_registry_default returns the singleton session registry instance.
session_registry_default :: proc() -> ^Session_Registry {
	if !sync.atomic_load(&_global_session_registry_init_once) {
		sync.mutex_lock(&_global_session_registry_lock)
		if !_global_session_registry_init_once {
			session_registry_init(&_global_session_registry)
			sync.atomic_store(&_global_session_registry_init_once, true)
		}
		sync.mutex_unlock(&_global_session_registry_lock)
	}
	return &_global_session_registry
}

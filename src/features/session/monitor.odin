package feature_session

// Session Telemetry & Operational Status Monitor
// Feature Composition Layer (src/features/session/*).
//
// Invariant: Pure domain observation provider with zero GUI/WGPU dependencies.
// Seamlessly reusable by macOS Menu Bar, Headless IPC, and Safety Dialogs.

import "base:runtime"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import extension "../../core/terminal/extension"
import terminal "../../core/terminal"
import pty "../../platform/pty"

Session_Snapshot :: struct {
	session_id:      u32,
	tab_index:       int,
	pane_id:         u32,
	title:           string,
	process_name:    string,
	pid:             int,
	cwd:             string,
	is_active_job:   bool,
	program_state:   extension.Program_State,
	status_msg:      string,
	elapsed_seconds: f32,
}

session_peek_last_line :: proc(sess: ^Terminal_Session, out_buf: []u8) -> string {
	if sess == nil || len(out_buf) == 0 do return ""
	cur_r, _ := terminal.terminal_cursor_pos(&sess.term)
	start_r := clamp(cur_r, 0, sess.term.rows - 1)

	for r := start_r; r >= 0; r -= 1 {
		row := terminal.terminal_get_row(&sess.term, r)
		if row == nil do continue
		non_empty := false
		for c in 0..<min(sess.term.cols, len(row.cells)) {
			if row.cells[c].char > ' ' {
				non_empty = true
				break
			}
		}
		if non_empty {
			idx := 0
			for c in 0..<min(sess.term.cols, len(row.cells)) {
				ch := row.cells[c].char
				if ch == 0 do ch = ' '
				buf, n := utf8.encode_rune(ch)
				if idx + n > len(out_buf) do break
				copy(out_buf[idx:], buf[:n])
				idx += n
			}
			return strings.trim_space(string(out_buf[:idx]))
		}
	}
	return ""
}

session_snapshot_make :: proc(
	sess: ^Terminal_Session,
	tab_idx: int,
	pane_id: u32,
	allocator := context.temp_allocator,
) -> Session_Snapshot {
	if sess == nil do return {}

	snap := Session_Snapshot{
		session_id    = pane_id,
		tab_index     = tab_idx,
		pane_id       = pane_id,
		is_active_job = session_is_running_job(sess),
		program_state = sess.program_status.state,
	}

	// 1. Process name & PID
	scratch_proc: [128]u8
	proc_str := pty.pty_get_foreground_process_name(sess.pty, scratch_proc[:])
	if len(proc_str) > 0 {
		snap.process_name = strings.clone(proc_str, allocator)
	} else if sess.program_status.app_len > 0 {
		snap.process_name = strings.clone(extension.program_status_app(&sess.program_status), allocator)
	} else {
		snap.process_name = "shell"
	}
	if sess.pty != nil do snap.pid = int(sess.pty.child_pid)

	// 2. Working directory
	scratch_cwd: [512]u8
	cwd_str := ""
	if sess.cwd_len > 0 {
		cwd_str = string(sess.cwd_buf[:sess.cwd_len])
	} else if sess.pty != nil {
		cwd_str = pty.pty_get_foreground_cwd(sess.pty, scratch_cwd[:])
	}
	if len(cwd_str) > 0 do snap.cwd = strings.clone(cwd_str, allocator)

	// 3. Title
	scratch_title: [256]u8
	title_str := session_resolve_title(sess, scratch_title[:], snap.process_name)
	if len(title_str) > 0 do snap.title = strings.clone(title_str, allocator)

	// 4. Elapsed runtime
	if sess.command_running && time.to_unix_nanoseconds(sess.command_start_time) > 0 {
		snap.elapsed_seconds = f32(time.duration_seconds(time.since(sess.command_start_time)))
	}

	// 5. Status Message (OSC 7501 explicit msg or line peeker fallback)
	if sess.program_status.msg_len > 0 {
		snap.status_msg = strings.clone(extension.program_status_msg(&sess.program_status), allocator)
	} else {
		scratch_line: [256]u8
		line := session_peek_last_line(sess, scratch_line[:])
		if len(line) > 0 do snap.status_msg = strings.clone(line, allocator)
	}

	return snap
}

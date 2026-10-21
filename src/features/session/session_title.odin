package feature_session

import "core:strings"
import pty "../../platform/pty"

// session_is_shell_process returns true if the process name represents a standard interactive shell.
session_is_shell_process :: proc(proc_name: string) -> bool {
	switch proc_name {
	case "zsh", "bash", "sh", "fish", "csh", "tcsh", "dash", "ksh":
		return true
	case "-zsh", "-bash", "-sh", "-fish", "-csh", "-tcsh", "-dash", "-ksh":
		return true
	}
	return false
}

// session_get_foreground_process returns the active foreground process name from PTY.
session_get_foreground_process :: proc(sess: ^Terminal_Session, out_buf: []u8) -> string {
	if sess == nil || sess.pty == nil do return ""
	return pty.pty_get_foreground_process_name(sess.pty, out_buf)
}

// session_get_current_cwd returns the working directory (preferring OSC 7, falling back to PTY OS query).
session_get_current_cwd :: proc(sess: ^Terminal_Session, out_buf: []u8) -> string {
	if sess == nil do return ""

	// 1. OSC 7 path if reported by shell
	osc7_path := session_get_cwd_path(sess)
	if len(osc7_path) > 0 {
		copy_len := min(len(osc7_path), len(out_buf))
		copy(out_buf[:copy_len], osc7_path[:copy_len])
		return string(out_buf[:copy_len])
	}

	// 2. Query OS via PTY
	if sess.pty != nil {
		return pty.pty_get_foreground_cwd(sess.pty, out_buf)
	}

	return ""
}

// session_resolve_title determines the effective tab title using:
// 1. Dynamic OSC 0 / OSC 2 title if present
// 2. Foreground process name if running a non-shell command (e.g. nvim, top, git, python)
// 3. Current working directory (from OSC 7 or PTY OS query) when idle at shell prompt
// 4. Fallback default
session_resolve_title :: proc(sess: ^Terminal_Session, out_buf: []u8, default_fallback: string = "Shell") -> string {
	if sess == nil || len(out_buf) == 0 do return default_fallback

	// 1. Explicit OSC 0/2 title
	osc_title := session_get_title(sess)
	if len(osc_title) > 0 {
		copy_len := min(len(osc_title), len(out_buf))
		copy(out_buf[:copy_len], osc_title[:copy_len])
		return string(out_buf[:copy_len])
	}

	// 2. Foreground process name
	scratch_proc: [128]u8
	proc_name := session_get_foreground_process(sess, scratch_proc[:])
	has_custom_proc := len(proc_name) > 0 && !session_is_shell_process(proc_name)

	// 3. Working directory
	scratch_cwd: [1024]u8
	cwd := session_get_current_cwd(sess, scratch_cwd[:])

	if has_custom_proc {
		copy_len := min(len(proc_name), len(out_buf))
		copy(out_buf[:copy_len], proc_name[:copy_len])
		return string(out_buf[:copy_len])
	}

	if len(cwd) > 0 {
		copy_len := min(len(cwd), len(out_buf))
		copy(out_buf[:copy_len], cwd[:copy_len])
		return string(out_buf[:copy_len])
	}

	if len(proc_name) > 0 {
		copy_len := min(len(proc_name), len(out_buf))
		copy(out_buf[:copy_len], proc_name[:copy_len])
		return string(out_buf[:copy_len])
	}

	return default_fallback
}

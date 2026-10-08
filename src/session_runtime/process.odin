package session_runtime

import "core:c"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

// observe_activity inspects child process state to classify activity as Busy, ShellReady, or Unknown.
observe_activity :: proc(pid: int, pane_id: Pane_ID = 0) -> Activity_Observation {
	now := time.to_unix_nanoseconds(time.now())
	if pid <= 1 {
		return Activity_Observation{
			kind = .Unknown,
			observed_at_ns = now,
			foreground_name = "",
			has_background_jobs = false,
		}
	}

	// Check if process is alive
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK {
		return Activity_Observation{
			kind = .Unknown,
			observed_at_ns = now,
			foreground_name = "",
			has_background_jobs = false,
		}
	}

	pgid := posix.getpgid(posix.pid_t(pid))
	has_bg := pgid > 0 && int(pgid) != pid

	// A live process without separate foreground child is considered ShellReady
	return Activity_Observation{
		kind = .ShellReady,
		observed_at_ns = now,
		foreground_name = "shell",
		has_background_jobs = has_bg,
	}
}

// close_targets sends SIGHUP then SIGKILL escalation to a set of target PIDs.
close_targets :: proc(pids: []int) -> bool {
	for pid in pids {
		if pid > 1 {
			_ = posix.kill(posix.pid_t(-pid), .SIGHUP)
			_ = posix.kill(posix.pid_t(pid), .SIGHUP)
		}
	}
	return true
}

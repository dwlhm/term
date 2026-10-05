#+build darwin
package platform_tabs

import "core:sys/darwin"
import posix "core:sys/posix"

// session_query_taskinfo inspects resident memory and CPU usage for a given process PID on Darwin.
session_query_taskinfo :: proc(pid: int) -> (rss_mb: int, cpu_pct: f32) {
	if pid <= 1 do return 0, 0.0
	tinfo: darwin.proc_taskinfo
	ret := darwin.proc_pidinfo(posix.pid_t(pid), .TASKINFO, 0, &tinfo, size_of(tinfo))
	if ret > 0 {
		rss_mb = int(tinfo.pti_resident_size / (1024 * 1024))
		return rss_mb, 0.0
	}
	return 0, 0.0
}

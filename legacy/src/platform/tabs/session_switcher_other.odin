#+build !darwin
package platform_tabs

// session_query_taskinfo returns stub metrics on non-Darwin platforms.
session_query_taskinfo :: proc(pid: int) -> (rss_mb: int, cpu_pct: f32) {
	return 0, 0.0
}

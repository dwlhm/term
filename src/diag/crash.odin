package diag

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"

diag_install_crash_handler :: proc() {
	context.assertion_failure_proc = term_assertion_failure
}

term_assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	snapshot := diag_get_snapshot()

	now := time.now()
	y, m, d := time.date(now)
	h, min, s := time.clock(now)

	uptime_ms: i64 = 0
	if _diag_state.initialized {
		uptime_ms = i64(time.duration_milliseconds(time.since(_diag_state.start_time)))
	}

	report := fmt.tprintf(
		"\n" +
		"=================== TERM CRASH REPORT ===================\n" +
		"Timestamp:   %04d-%02d-%02d %02d:%02d:%02d\n" +
		"Version:     %s\n" +
		"Uptime:      %d ms\n" +
		"Location:    %s:%d:%d (%s)\n" +
		"Assertion:   %s: %s\n" +
		"--- Terminal State Snapshot ---\n" +
		"Strategy:    %s\n" +
		"Tabs Active: %d\n" +
		"Grid Size:   %dx%d\n" +
		"=========================================================\n\n",
		y, int(m), d, h, min, s,
		_diag_state.cfg.app_version,
		uptime_ms,
		loc.file_path, loc.line, loc.column, loc.procedure,
		prefix, message,
		snapshot.strategy,
		snapshot.tab_count,
		snapshot.grid_rows, snapshot.grid_cols,
	)

	_, _ = os.write_string(os.stderr, report)
	_ = os.flush(os.stderr)

	if _diag_state.initialized && _diag_state.cfg.log_to_file {
		file_sink_write(&_diag_state.file_sink, report)
		file_sink_flush(&_diag_state.file_sink)
	}

	diag_flush()

	runtime.default_assertion_failure_proc(prefix, message, loc)
}

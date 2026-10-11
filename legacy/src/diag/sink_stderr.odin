package diag

import "core:fmt"
import "core:os"

stderr_sink_write :: proc(level: Log_Level, line: string) {
	_ = level
	_, _ = os.write_string(os.stderr, line)
	_ = os.flush(os.stderr)
}

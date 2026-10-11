package diag

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

File_Sink :: struct {
	handle: ^os.File,
	path:   string,
	active: bool,
	mutex:  sync.Mutex,
}

file_sink_init :: proc(sink: ^File_Sink, log_dir: string, app_version: string) -> bool {
	if sink == nil do return false
	sink^ = {}

	target_dir := log_dir
	if len(target_dir) == 0 {
		home, ok := os.lookup_env("HOME", context.temp_allocator)
		if ok && len(home) > 0 {
			target_dir, _ = filepath.join({home, ".local", "share", "term", "logs"}, context.temp_allocator)
		} else {
			target_dir = "/tmp/term_logs"
		}
	}

	if !os.exists(target_dir) {
		if err := os.make_directory_all(target_dir); err != nil {
			return false
		}
	}

	now := time.now()
	y, m, d := time.date(now)
	h, min, s := time.clock(now)

	filename := fmt.tprintf("term-%04d%02d%02d-%02d%02d%02d.log", y, int(m), d, h, min, s)
	full_path, _ := filepath.join({target_dir, filename}, context.temp_allocator)

	handle, err := os.open(full_path, {.Write, .Create, .Append})
	if err != nil {
		return false
	}

	sink.handle = handle
	sink.path = strings.clone(full_path)
	sink.active = true

	header := fmt.tprintf("# Term Log - Version: %s\n", app_version)
	_, _ = os.write(sink.handle, transmute([]byte)header)
	_ = os.flush(sink.handle)

	return true
}

file_sink_write :: proc(sink: ^File_Sink, line: string) {
	if sink == nil || !sink.active || sink.handle == nil do return

	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)

	_, _ = os.write(sink.handle, transmute([]byte)line)
}

file_sink_flush :: proc(sink: ^File_Sink) {
	if sink == nil || !sink.active || sink.handle == nil do return

	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)

	_ = os.flush(sink.handle)
}

file_sink_destroy :: proc(sink: ^File_Sink) {
	if sink == nil do return

	sync.mutex_lock(&sink.mutex)
	defer sync.mutex_unlock(&sink.mutex)

	if sink.active && sink.handle != nil {
		_ = os.flush(sink.handle)
		_ = os.close(sink.handle)
		sink.handle = nil
	}
	if len(sink.path) > 0 {
		delete(sink.path)
		sink.path = ""
	}
	sink.active = false
}

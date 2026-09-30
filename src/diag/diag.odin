package diag

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

Log_Level :: enum u8 {
	Debug = 0,
	Info  = 1,
	Warn  = 2,
	Error = 3,
	Fatal = 4,
}

Diag_Config :: struct {
	app_version:   string,
	log_to_stderr: bool,
	log_to_file:   bool,
	log_dir:       string, // empty string falls back to ~/.local/share/term/logs
	min_level:     Log_Level,
}

@(private)
_diag_state: struct {
	cfg:         Diag_Config,
	initialized: bool,
	mutex:       sync.Mutex,
	file_sink:   File_Sink,
	start_time:  time.Time,
}

diag_init :: proc(cfg: Diag_Config) -> bool {
	sync.mutex_lock(&_diag_state.mutex)
	defer sync.mutex_unlock(&_diag_state.mutex)

	_diag_state.cfg = cfg
	_diag_state.start_time = time.now()

	if cfg.log_to_file {
		_ = file_sink_init(&_diag_state.file_sink, cfg.log_dir, cfg.app_version)
	}
	_diag_state.initialized = true
	return true
}

diag_destroy :: proc() {
	sync.mutex_lock(&_diag_state.mutex)
	defer sync.mutex_unlock(&_diag_state.mutex)

	if !_diag_state.initialized do return

	if _diag_state.cfg.log_to_file {
		file_sink_destroy(&_diag_state.file_sink)
	}
	_diag_state.initialized = false
}

diag_flush :: proc() {
	sync.mutex_lock(&_diag_state.mutex)
	defer sync.mutex_unlock(&_diag_state.mutex)

	if !_diag_state.initialized do return

	if _diag_state.cfg.log_to_file {
		file_sink_flush(&_diag_state.file_sink)
	}
}

diag_log :: proc(level: Log_Level, fmt_str: string, args: ..any) {
	if !_diag_state.initialized do return
	if level < _diag_state.cfg.min_level do return

	msg := fmt.tprintf(fmt_str, ..args)
	now := time.now()
	y, m, d := time.date(now)
	h, min, s := time.clock(now)

	level_str := "INFO"
	switch level {
	case .Debug: level_str = "DEBUG"
	case .Info:  level_str = "INFO"
	case .Warn:  level_str = "WARN"
	case .Error: level_str = "ERROR"
	case .Fatal: level_str = "FATAL"
	}

	line := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d [%s] %s\n", y, int(m), d, h, min, s, level_str, msg)

	if _diag_state.cfg.log_to_stderr {
		stderr_sink_write(level, line)
	}
	if _diag_state.cfg.log_to_file {
		file_sink_write(&_diag_state.file_sink, line)
	}
}

diag_debug :: proc(fmt_str: string, args: ..any) {
	diag_log(.Debug, fmt_str, ..args)
}

diag_info :: proc(fmt_str: string, args: ..any) {
	diag_log(.Info, fmt_str, ..args)
}

diag_warn :: proc(fmt_str: string, args: ..any) {
	diag_log(.Warn, fmt_str, ..args)
}

diag_error :: proc(fmt_str: string, args: ..any) {
	diag_log(.Error, fmt_str, ..args)
}

diag_fatal :: proc(fmt_str: string, args: ..any) {
	diag_log(.Fatal, fmt_str, ..args)
}

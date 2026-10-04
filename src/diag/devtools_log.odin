package diag

// Machine-readable DevTools telemetry log (JSON Lines).
//
// This is the fourth consumer of Devtools_State, alongside the on-screen panel
// (render.devtools_panel_draw), the end-of-run summary (devtools_log_summary)
// and the crash report (term_assertion_failure in crash.odin). All of them
// read the same aggregate view, so they cannot report different numbers.
//
// FORMAT
//   One complete, self-contained JSON object per line, newline terminated.
//   No wrapping array, no trailing comma: a consumer may be handed the file
//   after the process was killed mid-write, and every line that is present
//   must parse on its own. Keys are the Odin field names of
//   Devtools_Snapshot, verbatim, so a reader needs no lookup table.
//
// NULLABILITY
//   A value that was not measured is JSON null, never 0. "Not sampled" and
//   "measured as zero" are different facts and an offline analysis must be
//   able to tell them apart. gpu_valid carries that distinction for the GPU
//   fields; metrics_valid carries it for the CPU fields; sample_count == 0
//   carries it for the frame-derived fields. Numeric fields are emitted as
//   JSON numbers, gpu_valid and metrics_valid as JSON booleans, never quoted.
//
// COST
//   The write happens on the frame/present thread, at the shared cadence
//   (devtools_cadence_due), never per frame. One format into a module-owned
//   scratch buffer and one write(2) of that buffer: no allocation, no fsync,
//   no close/reopen per line. The handle is opened lazily on the first sample
//   and kept open for the rest of the run.
//
// SIZE POLICY
//   At the cadence rate this file grows without bound, so it is capped at
//   DEVTOOLS_LOG_MAX_BYTES. The cap is enforced by refusing to write and
//   disabling the writer, NEVER by truncating, rotating or deleting: the path
//   came from the user's own configuration (config.Config.devtools_log_path or
//   TERM_DEVTOOLS_LOG) and the user owns its contents. A file that already
//   sits at the cap when the writer opens is reported once and left exactly as
//   it is; a file that reaches the cap during the run is reported once and the
//   writer goes quiet.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// DEVTOOLS_LOG_MAX_BYTES is the hard ceiling on the telemetry log size. At the
// cadence this is roughly 32 MB of JSONL; see the size policy above.
DEVTOOLS_LOG_MAX_BYTES :: 32 * 1024 * 1024

// DEVTOOLS_LOG_LINE_CAP bounds one formatted line. It is sized with margin
// over the largest possible line (25 keys plus a nanosecond timestamp); a
// line that does not fit is treated as a formatting failure rather than
// silently truncated, because a truncated line is not parseable JSON.
DEVTOOLS_LOG_LINE_CAP :: 2048

// DEVTOOLS_LOG_NUM_CAP bounds one formatted scalar.
DEVTOOLS_LOG_NUM_CAP :: 24

// DEVTOOLS_LOG_F64_LIMIT is the largest magnitude a float metric may have
// before it is reported as null. JSON has no infinity and no NaN, and both
// are possible output of a rate computed from a degenerate denominator.
DEVTOOLS_LOG_F64_LIMIT :: 1e12

@(private)
_devtools_log_state: struct {
	path:    string,   // owned clone of the configured path
	handle:  ^os.File, // nil until the first sample opens it
	armed:   bool,     // a usable path was accepted by devtools_log_open
	open:    bool,     // handle is valid
	disabled: bool,    // permanently off after a reported failure
	bytes:   i64,      // bytes written this run, for the size cap
	samples: u64,
	first_ns: u64,
	last_ns:  u64,
	mutex:    sync.Mutex,
}

// _devtools_log_line is the reusable format buffer. Module owned, written only
// under _devtools_log_state.mutex, so the frame path never allocates.
@(private)
_devtools_log_line: [DEVTOOLS_LOG_LINE_CAP]u8

// _Devtools_Log_Num_Bufs gives every integer field its own scratch buffer.
//
// These cannot share one buffer. Each _devtools_log_num_u64 call renders into
// its buffer and returns a view of that buffer, and all of them are handed to
// the formatter as arguments before it writes a single byte. With a shared
// buffer the later calls overwrite the earlier views, so every integer field
// in the emitted line collapses onto a prefix of whichever value happened to
// be rendered last. The float and f32 fields already carry their own buffers
// for this reason.
@(private)
_Devtools_Log_Num_Bufs :: struct {
	p50:       [DEVTOOLS_LOG_NUM_CAP]u8,
	p95:       [DEVTOOLS_LOG_NUM_CAP]u8,
	p99:       [DEVTOOLS_LOG_NUM_CAP]u8,
	frame_max: [DEVTOOLS_LOG_NUM_CAP]u8,
	resident:  [DEVTOOLS_LOG_NUM_CAP]u8,
	threads:   [DEVTOOLS_LOG_NUM_CAP]u8,
	gpu_mean:  [DEVTOOLS_LOG_NUM_CAP]u8,
	gpu_p95:   [DEVTOOLS_LOG_NUM_CAP]u8,
	present:   [DEVTOOLS_LOG_NUM_CAP]u8,
	inst:      [DEVTOOLS_LOG_NUM_CAP]u8,
	compute:   [DEVTOOLS_LOG_NUM_CAP]u8,
	fullscreen:[DEVTOOLS_LOG_NUM_CAP]u8,
	dirty:     [DEVTOOLS_LOG_NUM_CAP]u8,
	upload:    [DEVTOOLS_LOG_NUM_CAP]u8,
	pty_bytes: [DEVTOOLS_LOG_NUM_CAP]u8,
	parse:     [DEVTOOLS_LOG_NUM_CAP]u8,
	samples:   [DEVTOOLS_LOG_NUM_CAP]u8,
	presented: [DEVTOOLS_LOG_NUM_CAP]u8,
	dropped:   [DEVTOOLS_LOG_NUM_CAP]u8,
}

// devtools_log_open points the writer at path. It does not touch the
// filesystem: the file is opened lazily by the first sample, which is what
// keeps a run that never reaches the cadence from creating an empty file.
//
// Returns false when the writer is already armed or the path is empty.
// Idempotent in the sense that a second call changes nothing.
devtools_log_open :: proc(path: string) -> bool {
	sync.mutex_lock(&_devtools_log_state.mutex)
	defer sync.mutex_unlock(&_devtools_log_state.mutex)

	if _devtools_log_state.armed {
		return false
	}
	if len(path) == 0 {
		return false
	}
	_devtools_log_state.path = strings.clone(path)
	_devtools_log_state.armed = true
	_devtools_log_state.disabled = false
	return true
}

// devtools_log_active reports whether the writer is armed and has not been
// disabled by a reported failure. It is the guard for the call site: when it
// is false nothing is opened, nothing is formatted and nothing is allocated.
devtools_log_active :: proc() -> bool {
	sync.mutex_lock(&_devtools_log_state.mutex)
	defer sync.mutex_unlock(&_devtools_log_state.mutex)
	return _devtools_log_state.armed && !_devtools_log_state.disabled
}

// devtools_log_write_sample appends one JSON line describing snap at now_ns.
//
// Returns true when a complete line reached the file. It is the only place the
// log is written; it must be called at the shared cadence, never per frame.
// Every failure mode disables the writer after exactly one diag_warn: a
// writer that keeps failing would otherwise turn the instrumentation into the
// performance problem it exists to measure.
devtools_log_write_sample :: proc(snap: ^Devtools_Snapshot, now_ns: u64) -> bool {
	if snap == nil {
		return false
	}

	sync.mutex_lock(&_devtools_log_state.mutex)
	defer sync.mutex_unlock(&_devtools_log_state.mutex)

	if !_devtools_log_state.armed || _devtools_log_state.disabled {
		return false
	}
	if !_devtools_log_state.open && !_devtools_log_open_locked() {
		return false
	}

	line := _devtools_log_format(snap, now_ns)
	// sbprintf silently truncates on overflow, so completeness is proved by
	// the terminator rather than by a return value.
	if len(line) == 0 || line[len(line) - 1] != '\n' {
		_devtools_log_disable_locked("devtools: formatted line exceeded %d bytes; telemetry log is disabled", DEVTOOLS_LOG_LINE_CAP)
		return false
	}

	written, err := os.write(_devtools_log_state.handle, transmute([]byte)line)
	if err != nil || written != len(line) {
		// A short write is a real error, not a cosmetic one: it would leave a
		// truncated line that no consumer could parse.
		_devtools_log_disable_locked("devtools: short write to %s (%d of %d bytes); telemetry log is disabled", _devtools_log_state.path, written, len(line))
		return false
	}

	_devtools_log_state.bytes += i64(written)
	_devtools_log_state.samples += 1
	if _devtools_log_state.first_ns == 0 {
		_devtools_log_state.first_ns = now_ns
	}
	_devtools_log_state.last_ns = now_ns

	if _devtools_log_state.bytes >= DEVTOOLS_LOG_MAX_BYTES {
		// Reported once and disabled; the file is left exactly as written.
		_devtools_log_disable_locked("devtools: %s reached the %d byte limit; telemetry log is disabled", _devtools_log_state.path, DEVTOOLS_LOG_MAX_BYTES)
		return false
	}
	return true
}

// devtools_log_close flushes and closes the writer and releases the path.
//
// Idempotent, and safe on a writer that was never armed or never opened. It
// resets the run counters, so a close followed by an open starts a new file's
// accounting from zero.
devtools_log_close :: proc() {
	sync.mutex_lock(&_devtools_log_state.mutex)
	defer sync.mutex_unlock(&_devtools_log_state.mutex)

	if _devtools_log_state.open && _devtools_log_state.handle != nil {
		// One flush at teardown, never per line: fsync on the frame thread
		// would cost more than the instrumentation.
		_ = os.flush(_devtools_log_state.handle)
		_ = os.close(_devtools_log_state.handle)
	}
	_devtools_log_state.handle = nil
	_devtools_log_state.open = false
	_devtools_log_state.armed = false
	_devtools_log_state.disabled = false
	_devtools_log_state.bytes = 0
	_devtools_log_state.samples = 0
	_devtools_log_state.first_ns = 0
	_devtools_log_state.last_ns = 0
	if len(_devtools_log_state.path) > 0 {
		delete(_devtools_log_state.path)
		_devtools_log_state.path = ""
	}
}

// devtools_log_summary emits the end-of-run DevTools summary through
// diag_log at info level: samples written, the window they cover, the frames
// the collector saw, dropped frames, mean and worst frame time, and where the
// telemetry went. Call it before devtools_log_close, which releases the path.
//
// The frame figures come from the same Devtools_State the panel, the JSONL
// file and the crash report read, so all four report one set of numbers.
devtools_log_summary :: proc() {
	samples, first_ns, last_ns: u64
	destination: string
	{
		sync.mutex_lock(&_devtools_log_state.mutex)
		samples = _devtools_log_state.samples
		first_ns = _devtools_log_state.first_ns
		last_ns = _devtools_log_state.last_ns
		// Borrowed, not cloned: the path is released by devtools_log_close,
		// which the caller runs after this returns.
		destination = _devtools_log_state.path if _devtools_log_state.bytes > 0 else "disabled"
		sync.mutex_unlock(&_devtools_log_state.mutex)
	}

	snap := devtools_snapshot()
	covered_ms := 0.0
	if last_ns > first_ns {
		covered_ms = f64(last_ns - first_ns) / 1_000_000.0
	}
	diag_info(
		"[devtools] samples=%d duration_ms=%.1f frames=%d dropped=%d frame_mean_ms=%.2f frame_worst_ms=%.2f log=%s",
		samples,
		covered_ms,
		snap.sample_count,
		snap.dropped_count,
		f64(snap.present_mean_ns) / 1_000_000.0,
		f64(snap.frame_max_ns) / 1_000_000.0,
		destination,
	)
}

// _devtools_log_open_locked opens the file on the first sample, appending.
//
// The size cap is checked here, before a single byte is written: a file that
// is already at or above the limit is reported once and the writer is left
// disabled. It is never truncated.
@(private)
_devtools_log_open_locked :: proc() -> bool {
	handle, err := os.open(_devtools_log_state.path, {.Write, .Create, .Append})
	if err != nil {
		_devtools_log_disable_locked("devtools: cannot open %s for append; telemetry log is disabled", _devtools_log_state.path)
		return false
	}

	size, size_err := os.file_size(handle)
	if size_err == nil && size >= DEVTOOLS_LOG_MAX_BYTES {
		_ = os.close(handle)
		_devtools_log_state.disabled = true
		diag_warn("devtools: %s is %d bytes, at or above the %d byte limit; telemetry log is disabled and the file was left untouched", _devtools_log_state.path, size, DEVTOOLS_LOG_MAX_BYTES)
		return false
	}

	_devtools_log_state.handle = handle
	_devtools_log_state.open = true
	if size_err == nil {
		_devtools_log_state.bytes = size
	}
	return true
}

// _devtools_log_disable_locked reports one failure, through the caller-supplied
// format string, and turns the writer off
// for good. Caller holds the log mutex. Exactly one warning per writer: a
// repeatedly failing writer must not itself become a performance problem.
@(private)
_devtools_log_disable_locked :: proc(format: string, args: ..any) {
	if _devtools_log_state.open && _devtools_log_state.handle != nil {
		_ = os.close(_devtools_log_state.handle)
	}
	_devtools_log_state.handle = nil
	_devtools_log_state.open = false
	if _devtools_log_state.disabled {
		return
	}
	_devtools_log_state.disabled = true
	diag_warn(format, ..args)
}

// _devtools_log_format renders snap as one JSON line into the module-owned
// scratch buffer. Caller holds the log mutex. It allocates nothing.
@(private)
_devtools_log_format :: proc(snap: ^Devtools_Snapshot, now_ns: u64) -> string {
	has_frames := snap.sample_count > 0
	has_cpu := snap.metrics_valid
	has_gpu := snap.gpu_valid
	// A parse time of zero means no frame carried one: parse_ns is only
	// pushed into the ring when it is non-zero.
	has_parse := snap.parse_p95_ns > 0
	// present_count is implied by a non-zero mean; a presented frame whose
	// measured time rounds to zero is not distinguishable and is reported as
	// measured, which is the conservative direction.
	has_present := snap.present_mean_ns > 0

	fps_b: [DEVTOOLS_LOG_NUM_CAP]u8
	drop_b: [DEVTOOLS_LOG_NUM_CAP]u8
	cpu_b: [DEVTOOLS_LOG_NUM_CAP]u8
	sys_cpu_b: [DEVTOOLS_LOG_NUM_CAP]u8
	// Distinct buffer per integer field; see _Devtools_Log_Num_Bufs.
	num: _Devtools_Log_Num_Bufs
	line_buf := _devtools_log_line[:]

	return fmt.bprintf(
		line_buf,
		// The opening brace is emitted through %c, never written literally:
		// Odin's fmt treats a '{' in the format string as the start of a verb
		// block, and an unbalanced one replaces itself with
		// "%!(MISSING CLOSE BRACE)" instead of printing a brace.
		"%c\"t_ns\":%d," +
			"\"fps\":%s,\"drop_pct\":%s," +
			"\"frame_p50_ns\":%s,\"frame_p95_ns\":%s,\"frame_p99_ns\":%s,\"frame_max_ns\":%s," +
			"\"cpu_pct\":%s,\"system_cpu_pct\":%s,\"resident_bytes\":%s,\"thread_count\":%s,\"metrics_valid\":%s," +
			"\"gpu_mean_ns\":%s,\"gpu_p95_ns\":%s,\"gpu_valid\":%s," +
			"\"present_mean_ns\":%s," +
			"\"strategy_instance\":%s,\"strategy_compute\":%s,\"strategy_fullscreen\":%s," +
			"\"dirty_cells\":%s,\"upload_bytes\":%s,\"pty_bytes\":%s," +
			"\"parse_p95_ns\":%s,\"sample_count\":%s,\"present_count\":%s,\"dropped_count\":%s}\n",
		u8('{'),
		now_ns,
		_devtools_log_num_f64(&fps_b, snap.fps, has_cpu),
		_devtools_log_num_f64(&drop_b, snap.drop_pct, has_frames),
		_devtools_log_num_u64(&num.p50, snap.frame_p50_ns, has_frames),
		_devtools_log_num_u64(&num.p95, snap.frame_p95_ns, has_frames),
		_devtools_log_num_u64(&num.p99, snap.frame_p99_ns, has_frames),
		_devtools_log_num_u64(&num.frame_max, snap.frame_max_ns, has_frames),
		_devtools_log_num_f32(&cpu_b, snap.cpu_pct, has_cpu),
		_devtools_log_num_f32(&sys_cpu_b, snap.system_cpu_pct, has_cpu),
		_devtools_log_num_u64(&num.resident, snap.resident_bytes, has_cpu),
		_devtools_log_num_u64(&num.threads, u64(snap.thread_count), has_cpu),
		bool_to_json(snap.metrics_valid),
		_devtools_log_num_u64(&num.gpu_mean, snap.gpu_mean_ns, has_gpu),
		_devtools_log_num_u64(&num.gpu_p95, snap.gpu_p95_ns, has_gpu),
		bool_to_json(snap.gpu_valid),
		_devtools_log_num_u64(&num.present, snap.present_mean_ns, has_present),
		_devtools_log_num_u64(&num.inst, snap.strategy_instance, has_frames),
		_devtools_log_num_u64(&num.compute, snap.strategy_compute, has_frames),
		_devtools_log_num_u64(&num.fullscreen, snap.strategy_fullscreen, has_frames),
		_devtools_log_num_u64(&num.dirty, snap.dirty_cells, has_frames),
		_devtools_log_num_u64(&num.upload, snap.upload_bytes, has_frames),
		_devtools_log_num_u64(&num.pty_bytes, snap.pty_bytes, has_frames),
		_devtools_log_num_u64(&num.parse, snap.parse_p95_ns, has_parse),
		_devtools_log_num_u64(&num.samples, snap.sample_count, true),
		_devtools_log_num_u64(&num.presented, snap.present_count, true),
		_devtools_log_num_u64(&num.dropped, snap.dropped_count, has_frames),
	)
}

// _devtools_log_num_f64 renders a finite float as a JSON number, or null.
// NaN compares unequal to itself; infinities fall outside the limit. Neither
// is representable in JSON.
@(private)
_devtools_log_num_f64 :: proc(buf: ^[DEVTOOLS_LOG_NUM_CAP]u8, v: f64, meaningful: bool) -> string {
	if !meaningful || !(v == v) || v > DEVTOOLS_LOG_F64_LIMIT || v < -DEVTOOLS_LOG_F64_LIMIT {
		return "null"
	}
	return _devtools_log_num_text(fmt.bprintf(buf[:], "%.4f", v))
}

// _devtools_log_num_f32 is the f32 twin of _devtools_log_num_f64.
@(private)
_devtools_log_num_f32 :: proc(buf: ^[DEVTOOLS_LOG_NUM_CAP]u8, v: f32, meaningful: bool) -> string {
	if !meaningful || !(v == v) || v > f32(DEVTOOLS_LOG_F64_LIMIT) || v < f32(-DEVTOOLS_LOG_F64_LIMIT) {
		return "null"
	}
	return _devtools_log_num_text(fmt.bprintf(buf[:], "%.4f", v))
}

// _devtools_log_num_u64 renders an integer metric as a JSON number, or null
// when the metric was never measured.
@(private)
_devtools_log_num_u64 :: proc(buf: ^[DEVTOOLS_LOG_NUM_CAP]u8, v: u64, meaningful: bool) -> string {
	if !meaningful {
		return "null"
	}
	return _devtools_log_num_text(fmt.bprintf(buf[:], "%d", v))
}

// _devtools_log_num_text turns a failed format into null. bprintf returns ""
// when the underlying builder write fails, which for these fields can only
// mean the value did not fit in DEVTOOLS_LOG_NUM_CAP.
@(private)
_devtools_log_num_text :: proc(text: string) -> string {
	return text if len(text) > 0 else "null"
}

// bool_to_json renders a JSON boolean.
@(private)
bool_to_json :: proc(v: bool) -> string {
	return "true" if v else "false"
}

// bool_to_json renders a JSON boolean.
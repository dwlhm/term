package diag_test

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import diag "../"
import platform "../../platform"

@(test)
test_diag_lifecycle_and_levels :: proc(t: ^testing.T) {
	cfg := diag.Diag_Config{
		app_version   = "0.3.0-test",
		log_to_stderr = false,
		log_to_file   = false,
		min_level     = .Warn,
	}

	ok := diag.diag_init(cfg)
	testing.expect(t, ok, "diag_init should succeed")

	diag.diag_debug("Debug message %d", 1)
	diag.diag_info("Info message %s", "test")
	diag.diag_warn("Warn message %f", 3.14)
	diag.diag_error("Error message %v", true)
	diag.diag_flush()

	diag.diag_destroy()
}

@(test)
test_diag_file_sink :: proc(t: ^testing.T) {
	test_dir := "/tmp/term_diag_unit_test"
	_ = os.remove_all(test_dir)
	defer {
		_ = os.remove_all(test_dir)
	}

	cfg := diag.Diag_Config{
		app_version   = "0.3.0-test",
		log_to_stderr = false,
		log_to_file   = true,
		log_dir       = test_dir,
		min_level     = .Debug,
	}

	ok := diag.diag_init(cfg)
	testing.expect(t, ok, "diag_init with file sink should succeed")

	diag.diag_debug("Debug probe: value=%d", 42)
	diag.diag_info("Info probe: system=%s", "ready")
	diag.diag_flush()
	diag.diag_destroy()

	fd, err := os.open(test_dir)
	testing.expect(t, err == nil, "open test dir should succeed")
	if err == nil {
		file_infos, read_err := os.read_dir(fd, -1, context.allocator)
		_ = os.close(fd)
		testing.expect(t, read_err == nil, "read_dir should succeed")
		defer {
			for fi in file_infos {
				os.file_info_delete(fi, context.allocator)
			}
			delete(file_infos)
		}

		found_log := false
		for fi in file_infos {
			if strings.has_prefix(fi.name, "term-") && strings.has_suffix(fi.name, ".log") {
				found_log = true
				full_file_path, _ := filepath.join({test_dir, fi.name}, context.temp_allocator)
				data, read_file_err := os.read_entire_file(full_file_path, context.allocator)
				testing.expect(t, read_file_err == nil, "reading log file should succeed")
				if read_file_err == nil {
					defer delete(data)
					content := string(data)
					testing.expect(t, strings.contains(content, "Debug probe: value=42"), "log file contains debug probe")
					testing.expect(t, strings.contains(content, "Info probe: system=ready"), "log file contains info probe")
					testing.expect(t, strings.contains(content, "# Term Log - Version: 0.3.0-test"), "log file contains header")
				}
				_ = os.remove(full_file_path)
			}
		}
		testing.expect(t, found_log, "expected at least one term-*.log file in test dir")
	}
}

@(test)
test_diag_snapshot :: proc(t: ^testing.T) {
	snap := diag.Diag_Snapshot{
		strategy  = "ComputeTile",
		tab_count = 3,
		grid_rows = 48,
		grid_cols = 120,
	}

	diag.diag_set_snapshot(snap)
	retrieved := diag.diag_get_snapshot()

	testing.expect_value(t, retrieved.strategy, "ComputeTile")
	testing.expect_value(t, retrieved.tab_count, 3)
	testing.expect_value(t, retrieved.grid_rows, 48)
	testing.expect_value(t, retrieved.grid_cols, 120)
}

// --- DevTools JSONL telemetry log -------------------------------------------
//
// devtools_log_write_sample is exercised directly against a real file: the
// tests below read the bytes back off disk and parse them with the Odin
// standard library's JSON implementation (core:encoding/json), so a claim
// about the format cannot be satisfied by the formatter agreeing with itself.

Devtools_Log_Line :: struct {
	t_ns:                u64,
	fps:                 f64,
	drop_pct:            f64,
	frame_p50_ns:        u64,
	frame_p95_ns:        u64,
	frame_p99_ns:        u64,
	frame_max_ns:        u64,
	cpu_pct:             f32,
	system_cpu_pct:      f32,
	resident_bytes:      u64,
	thread_count:        u32,
	metrics_valid:       bool,
	gpu_mean_ns:         u64,
	gpu_p95_ns:          u64,
	gpu_valid:           bool,
	present_mean_ns:     u64,
	strategy_instance:   u64,
	strategy_compute:    u64,
	strategy_fullscreen: u64,
	dirty_cells:         u64,
	upload_bytes:        u64,
	pty_bytes:           u64,
	parse_p95_ns:        u64,
	sample_count:        u64,
	present_count:       u64,
	dropped_count:       u64,
}

// devtools_log_jsonl_lines splits JSONL content into its records and proves the
// format contract instead of assuming it: the content must end with a newline
// (no missing final terminator), must not contain a blank record (no blank line
// between samples), and split_lines' trailing empty element, which it reports
// even for correctly terminated content, is removed only after the terminator
// has been proved. Returns a slice the caller owns.
devtools_log_jsonl_lines :: proc(t: ^testing.T, content: string) -> []string {
	testing.expect(t, len(content) > 0, "the log must contain at least one record")
	testing.expect(t, strings.has_suffix(content, "\n"), "the last record must be newline terminated")
	lines := strings.split_lines(content)
	testing.expect(t, len(lines) > 0 && lines[len(lines) - 1] == "", "newline terminated content ends with an empty element")
	if len(lines) > 0 {
		lines = lines[:len(lines) - 1]
	}
	for line, index in lines {
		testing.expect(t, len(line) > 0, fmt.tprintf("record %d is blank; records must not be separated by blank lines", index))
	}
	return lines
}

// devtools_log_test_setup arms the writer on path and makes sure diag logging
// is live, so a warning emitted by a failure path is a real one.
devtools_log_test_setup :: proc(t: ^testing.T, path: string) {
	diag.devtools_log_close()
	cfg := diag.Diag_Config{
		app_version   = "0.3.0-test",
		log_to_stderr = false,
		log_to_file   = false,
		min_level     = .Debug,
	}
	testing.expect(t, diag.diag_init(cfg), "diag_init should succeed")
	testing.expect(t, diag.devtools_log_open(path), "devtools_log_open should accept a usable path")
	testing.expect(t, diag.devtools_log_active(), "armed writer should be active")
}

// devtools_log_full_snapshot is a snapshot with every field measured, so the
// expected byte sequence below contains numbers and no nulls.
devtools_log_full_snapshot :: proc() -> diag.Devtools_Snapshot {
	return diag.Devtools_Snapshot{
		fps                 = 120.0,
		drop_pct            = 1.5,
		frame_p50_ns        = 8_000_000,
		frame_p95_ns        = 9_500_000,
		frame_p99_ns        = 12_000_000,
		frame_max_ns        = 20_000_000,
		cpu_pct             = 3.5,
		system_cpu_pct      = 11.25,
		resident_bytes      = 52_428_800,
		thread_count        = 9,
		gpu_mean_ns         = 1_500_000,
		gpu_p95_ns          = 2_500_000,
		gpu_valid           = true,
		present_mean_ns     = 8_100_000,
		strategy_instance   = 3,
		strategy_compute    = 2,
		strategy_fullscreen = 1,
		dirty_cells         = 42,
		upload_bytes        = 4096,
		pty_bytes           = 2048,
		parse_p95_ns        = 300_000,
		sample_count        = 120,
		present_count       = 118,
		dropped_count       = 2,
		metrics_valid       = true,
	}
}

@(test)
test_devtools_log_line_is_exact_valid_json :: proc(t: ^testing.T) {
	test_dir := "/tmp/term_devtools_log_test"
	_ = os.remove_all(test_dir)
	defer os.remove_all(test_dir)
	testing.expect(t, os.make_directory_all(test_dir) == nil, "test dir should be creatable")

	// The path is joined into the temp allocator, which owns it for the
	// duration of the test: devtools_log_open clones it, so freeing the
	// caller's copy is never the caller's job.
	path, _ := filepath.join({test_dir, "telemetry.jsonl"}, context.temp_allocator)

	devtools_log_test_setup(t, path)

	snap := devtools_log_full_snapshot()
	testing.expect(t, diag.devtools_log_write_sample(&snap, 1_234_567_890), "first sample should be written")
	// The handle is opened on the first sample and kept open: a second call
	// must append, not truncate and not reopen.
	snap.sample_count = 240
	snap.present_count = 238
	testing.expect(t, diag.devtools_log_write_sample(&snap, 1_484_567_890), "second sample should be appended")

	diag.devtools_log_close()

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "reading the telemetry log should succeed")
	if err != nil do return
	defer delete(data)

	lines := devtools_log_jsonl_lines(t, string(data))
	defer delete(lines)
	testing.expect_value(t, len(lines), 2)

	// Exact byte sequence for the first line. This is the format contract.
	expected_first := `{"t_ns":1234567890,"fps":120.0000,"drop_pct":1.5000,` +
		`"frame_p50_ns":8000000,"frame_p95_ns":9500000,"frame_p99_ns":12000000,"frame_max_ns":20000000,` +
		`"cpu_pct":3.5000,"system_cpu_pct":11.2500,"resident_bytes":52428800,"thread_count":9,"metrics_valid":true,` +
		`"gpu_mean_ns":1500000,"gpu_p95_ns":2500000,"gpu_valid":true,` +
		`"present_mean_ns":8100000,` +
		`"strategy_instance":3,"strategy_compute":2,"strategy_fullscreen":1,` +
		`"dirty_cells":42,"upload_bytes":4096,"pty_bytes":2048,` +
		`"parse_p95_ns":300000,"sample_count":120,"present_count":118,"dropped_count":2}`
	testing.expect_value(t, lines[0], expected_first)
	testing.expect_value(t, lines[1], `{"t_ns":1484567890,"fps":120.0000,"drop_pct":1.5000,` +
		`"frame_p50_ns":8000000,"frame_p95_ns":9500000,"frame_p99_ns":12000000,"frame_max_ns":20000000,` +
		`"cpu_pct":3.5000,"system_cpu_pct":11.2500,"resident_bytes":52428800,"thread_count":9,"metrics_valid":true,` +
		`"gpu_mean_ns":1500000,"gpu_p95_ns":2500000,"gpu_valid":true,` +
		`"present_mean_ns":8100000,` +
		`"strategy_instance":3,"strategy_compute":2,"strategy_fullscreen":1,` +
		`"dirty_cells":42,"upload_bytes":4096,"pty_bytes":2048,` +
		`"parse_p95_ns":300000,"sample_count":240,"present_count":238,"dropped_count":2}`)

	// Independent parse with the Odin standard library JSON implementation.
	testing.expect(t, json.is_valid(transmute([]u8)lines[0]), "line 0 should be valid JSON")
	decoded: Devtools_Log_Line
	unmarshal_err := json.unmarshal(transmute([]u8)lines[0], &decoded)
	testing.expect(t, unmarshal_err == nil, "line 0 should unmarshal")
	testing.expect_value(t, decoded.fps, 120.0)
	testing.expect_value(t, decoded.frame_max_ns, 20_000_000)
	testing.expect_value(t, decoded.thread_count, 9)
	testing.expect_value(t, decoded.gpu_mean_ns, 1_500_000)
	testing.expect(t, decoded.gpu_valid, "gpu_valid should decode as true")
	testing.expect(t, decoded.metrics_valid, "metrics_valid should decode as true")
	testing.expect_value(t, decoded.t_ns, 1_234_567_890)
	testing.expect_value(t, decoded.sample_count, 120)

	decoded_second: Devtools_Log_Line
	testing.expect(t, json.unmarshal(transmute([]u8)lines[1], &decoded_second) == nil, "line 1 should unmarshal")
	testing.expect_value(t, decoded_second.sample_count, 240)
}

@(test)
test_devtools_log_emits_null_for_unavailable_metrics :: proc(t: ^testing.T) {
	test_dir := "/tmp/term_devtools_log_null_test"
	_ = os.remove_all(test_dir)
	defer os.remove_all(test_dir)
	testing.expect(t, os.make_directory_all(test_dir) == nil, "test dir should be creatable")

	path, _ := filepath.join({test_dir, "null.jsonl"}, context.temp_allocator)

	devtools_log_test_setup(t, path)

	// gpu_valid false with a zeroed GPU figure is the exact shape a real
	// snapshot has before the first command buffer has completed. Emitting 0
	// here would be a lie the consumer cannot detect.
	snap := devtools_log_full_snapshot()
	snap.gpu_valid = false
	snap.gpu_mean_ns = 0
	snap.gpu_p95_ns = 0
	snap.metrics_valid = false
	snap.cpu_pct = 0
	snap.system_cpu_pct = 0
	snap.resident_bytes = 0
	snap.thread_count = 0
	snap.parse_p95_ns = 0
	snap.sample_count = 0
	snap.present_count = 0
	snap.dropped_count = 0
	snap.present_mean_ns = 0
	snap.fps = 0
	snap.drop_pct = 0

	testing.expect(t, diag.devtools_log_write_sample(&snap, 42), "sample with nulls should be written")
	diag.devtools_log_close()

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "reading the telemetry log should succeed")
	if err != nil do return
	defer delete(data)

	expected := `{"t_ns":42,"fps":null,"drop_pct":null,` +
		`"frame_p50_ns":null,"frame_p95_ns":null,"frame_p99_ns":null,"frame_max_ns":null,` +
		`"cpu_pct":null,"system_cpu_pct":null,"resident_bytes":null,"thread_count":null,"metrics_valid":false,` +
		`"gpu_mean_ns":null,"gpu_p95_ns":null,"gpu_valid":false,` +
		`"present_mean_ns":null,` +
		`"strategy_instance":null,"strategy_compute":null,"strategy_fullscreen":null,` +
		`"dirty_cells":null,"upload_bytes":null,"pty_bytes":null,` +
		`"parse_p95_ns":null,"sample_count":0,"present_count":0,"dropped_count":null}`
	testing.expect_value(t, strings.trim_space(string(data)), expected)

	// Not just textually null: the JSON parser must accept it.
	testing.expect(t, json.is_valid(transmute([]u8)strings.trim_space(string(data))), "null-bearing line should be valid JSON")
	decoded: Devtools_Log_Line
	testing.expect(t, json.unmarshal(transmute([]u8)strings.trim_space(string(data)), &decoded) == nil, "null-bearing line should unmarshal")
	testing.expect_value(t, decoded.gpu_mean_ns, u64(0))
	testing.expect(t, !decoded.gpu_valid, "gpu_valid should decode as false")
	testing.expect(t, !decoded.metrics_valid, "metrics_valid should decode as false")
	testing.expect_value(t, decoded.sample_count, u64(0))
}

@(test)
test_devtools_log_open_failure_warns_once_and_does_not_retry :: proc(t: ^testing.T) {
	// A path whose parent directory does not exist cannot be opened.
	missing_dir := "/tmp/term_devtools_log_missing_dir"
	_ = os.remove_all(missing_dir)
	defer os.remove_all(missing_dir)
	path, _ := filepath.join({missing_dir, "telemetry.jsonl"}, context.temp_allocator)

	devtools_log_test_setup(t, path)

	snap := devtools_log_full_snapshot()
	testing.expect(t, !diag.devtools_log_write_sample(&snap, 1), "write into a missing directory should fail")
	testing.expect(t, !diag.devtools_log_active(), "a failed open must disable the writer")

	// Prove the failure is not retried: create the directory that was missing
	// and try again. A writer that retried would now succeed.
	testing.expect(t, os.make_directory_all(missing_dir) == nil, "recovery directory should be creatable")
	testing.expect(t, !diag.devtools_log_write_sample(&snap, 2), "a disabled writer must not retry the open")
	testing.expect(t, !os.exists(path), "a disabled writer must not create the file")

	diag.devtools_log_close()
	testing.expect(t, !diag.devtools_log_active(), "close should leave the writer inactive")
}

@(test)
test_devtools_log_close_is_idempotent :: proc(t: ^testing.T) {
	// Never opened.
	diag.devtools_log_close()
	diag.devtools_log_close()
	testing.expect(t, !diag.devtools_log_active(), "close without open must be a no-op")

	test_dir := "/tmp/term_devtools_log_close_test"
	_ = os.remove_all(test_dir)
	defer os.remove_all(test_dir)
	testing.expect(t, os.make_directory_all(test_dir) == nil, "test dir should be creatable")
	path, _ := filepath.join({test_dir, "close.jsonl"}, context.temp_allocator)

	devtools_log_test_setup(t, path)
	snap := devtools_log_full_snapshot()
	testing.expect(t, diag.devtools_log_write_sample(&snap, 1), "sample should be written")
	diag.devtools_log_close()
	// Twice in a row after a real write, and once more for good measure.
	diag.devtools_log_close()
	diag.devtools_log_close()
	testing.expect(t, !diag.devtools_log_active(), "close must leave the writer inactive")

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "the closed log should still be readable")
	if err == nil {
		defer delete(data)
		lines := devtools_log_jsonl_lines(t, string(data))
		defer delete(lines)
		testing.expect_value(t, len(lines), 1)
	}
}

@(test)
test_devtools_log_disabled_writer_does_not_allocate :: proc(t: ^testing.T) {
	snap := devtools_log_full_snapshot()

	tm: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tm, context.allocator)
	previous := context.allocator
	context.allocator = mem.tracking_allocator(&tm)
	defer {
		context.allocator = previous
		mem.tracking_allocator_destroy(&tm)
	}

	// Never opened: the guard must return before any formatting, so the frame
	// path pays a mutex-protected boolean read and nothing else.
	mem.tracking_allocator_reset(&tm)
	testing.expect(t, !diag.devtools_log_write_sample(&snap, 1), "an unarmed writer writes nothing")
	testing.expect_value(t, tm.total_allocation_count, i64(0))

	// Armed but disabled: same early return, and no retry of the open.
	test_dir := "/tmp/term_devtools_log_alloc_test"
	_ = os.remove_all(test_dir)
	defer os.remove_all(test_dir)
	testing.expect(t, os.make_directory_all(test_dir) == nil, "test dir should be creatable")
	// Joined into the temp allocator, which is not swapped by the tracking
	// allocator installed above, so both paths stay owned by it.
	path, _ := filepath.join({test_dir, "alloc.jsonl"}, context.temp_allocator)
	testing.expect(t, diag.devtools_log_open(path), "writer should arm")
	bad_path, _ := filepath.join({"/tmp/term_devtools_log_alloc_missing", "alloc.jsonl"}, context.temp_allocator)
	diag.devtools_log_close()
	testing.expect(t, diag.devtools_log_open(bad_path), "writer should re-arm on a bad path")
	testing.expect(t, !diag.devtools_log_write_sample(&snap, 2), "bad path should fail")
	testing.expect(t, !diag.devtools_log_active(), "writer should be disabled")

	// The writer still owns its cloned path allocation. Release it before
	// resetting the tracking allocator: reset forgets outstanding allocations,
	// so freeing one afterwards is reported as a bad free rather than a real
	// free, and both the pointer and the tracker header are reported as leaks.
	diag.devtools_log_close()

	mem.tracking_allocator_reset(&tm)
	testing.expect(t, !diag.devtools_log_write_sample(&snap, 3), "an inactive writer writes nothing")
	testing.expect_value(t, tm.total_allocation_count, i64(0))

	diag.devtools_log_close()
}

@(test)
test_devtools_cadence_is_the_single_clock :: proc(t: ^testing.T) {
	diag.devtools_init(true)
	defer diag.devtools_init(false)

	diag.devtools_set_active(true)

	// A clock-less caller is always due, so it can never be handed stale data.
	testing.expect(t, diag.devtools_cadence_due(0), "now_ns == 0 must always be due")

	diag.devtools_reset()
	now_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	testing.expect(t, diag.devtools_cadence_due(now_ns), "a fresh cadence is due")

	// One tick, then the anchor it landed on is the instant the cadence is
	// measured from. The assertions below are relative to that anchor, which is
	// what devtools_cadence_tick returns, not to a separately sampled clock
	// reading: the two differ by however long the tick itself took, so timing
	// assertions made against the earlier reading would race by microseconds.
	anchor := diag.devtools_cadence_tick()
	testing.expect(t, anchor > 0, "the tick must advance the cadence off zero")
	// The contract, stated exactly: not due before one full interval has
	// elapsed since the anchor, due the moment it has.
	testing.expect(t, !diag.devtools_cadence_due(anchor), "the cadence must not be due again at its own anchor")
	testing.expect(
		t,
		!diag.devtools_cadence_due(anchor + diag.DEVTOOLS_SAMPLE_INTERVAL_NS - 1),
		"the cadence must not be due one nanosecond short of a full interval",
	)
	testing.expect(t, diag.devtools_cadence_due(anchor + diag.DEVTOOLS_SAMPLE_INTERVAL_NS), "the cadence must be due one interval later")

	// Idle suppression: the app reports no work, so the cadence goes silent
	// for both the panel and the log.
	diag.devtools_set_active(false)
	testing.expect(t, !diag.devtools_cadence_due(0), "an inactive cadence is never due")
	diag.devtools_set_active(true)
	testing.expect(t, diag.devtools_cadence_due(anchor + diag.DEVTOOLS_SAMPLE_INTERVAL_NS), "activity resumes the cadence")
}

// Delayed consumers must divide counter deltas by actual sample time, not
// the preceding scheduling anchor. Exercise the public production path.
@(test)
test_devtools_delayed_sample_interval :: proc(t: ^testing.T) {
	diag.devtools_init(true)
	defer diag.devtools_init(false)
	first_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	first := diag.devtools_snapshot()
	testing.expect(t, first.fps == 0, "first sample establishes a baseline")
	diag.devtools_cadence_tick()
	time.sleep(time.Duration(diag.DEVTOOLS_SAMPLE_INTERVAL_NS * 3))
	frame := diag.Frame_Sample{frame_ns = 1, presented = true}
	diag.devtools_record_frame(&frame)
	next := diag.devtools_snapshot()
	last_ns := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	expected := 1_000_000_000.0 / f64(last_ns - first_ns)
	testing.expect(t, next.fps > expected * 0.9 && next.fps < expected * 1.1,
	               "delayed FPS must use the actual elapsed sample interval")
	diag.devtools_record_frame(&frame)
	duplicate := diag.devtools_snapshot()
	testing.expect(t, duplicate.fps == next.fps && duplicate.cpu_pct == next.cpu_pct,
	               "another consumer in the same cadence must reuse metrics")
	diag.devtools_reset()
	reset := diag.devtools_snapshot()
	testing.expect(t, reset.fps == 0 && reset.cpu_pct == 0,
	               "reset must discard the previous interval baseline")
}

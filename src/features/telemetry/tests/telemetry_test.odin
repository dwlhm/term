package feature_telemetry_tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import core_terminal "../../../core/terminal"
import telemetry "../"

TMP_PATH :: "/tmp/term-telemetry-test.ndjson"

@(test)
test_percentiles_and_summary :: proc(t: ^testing.T) {
	tel := new(telemetry.Telemetry)
	defer free(tel)
	testing.expect(t, telemetry.telemetry_open(tel, TMP_PATH))

	// 1000 frames: 1..1000 µs.
	for i in 1 ..= 1000 {
		telemetry.telemetry_add_drain(tel, 10)
		telemetry.telemetry_add_pane(tel, 5, "Instance")
		telemetry.telemetry_end_frame(tel, u64(i) * 1000)
	}
	testing.expect_value(t, tel.frames, 1000)
	testing.expect_value(t, tel.total_bytes, 10_000)
	// Percentiles report the 10 µs bucket upper bound, clamped to the observed max.
	testing.expect_value(t, telemetry.telemetry_percentile_ns(tel, 0.50), 510_000)
	testing.expect_value(t, telemetry.telemetry_percentile_ns(tel, 0.95), 960_000)
	testing.expect_value(t, telemetry.telemetry_percentile_ns(tel, 0.999), 1_000_000)
	telemetry.telemetry_close(tel)

	data, err := os.read_entire_file(TMP_PATH, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	text := string(data)
	testing.expect_value(t, strings.count(text, "\n"), 1001)
	testing.expect(t, strings.contains(text, `"strategy":"Instance"`))
	testing.expect(t, strings.contains(text, `"summary":true`))
	testing.expect(t, strings.contains(text, `"p50_us":510`))
}

@(test)
test_record_frame_zero_alloc :: proc(t: ^testing.T) {
	tel := new(telemetry.Telemetry)
	defer free(tel)
	testing.expect(t, telemetry.telemetry_open(tel, TMP_PATH))
	defer telemetry.telemetry_close(tel)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	for i in 0 ..< 20_000 { 	// forces several buffer flushes
		telemetry.telemetry_add_drain(tel, 4096)
		telemetry.telemetry_add_pane(tel, 1920, "Compute_Tiles")
		telemetry.telemetry_end_frame(tel, u64(i % 50) * 100_000)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

@(test)
test_inactive_is_noop :: proc(t: ^testing.T) {
	tel := new(telemetry.Telemetry)
	defer free(tel)
	telemetry.telemetry_add_drain(tel, 100)
	telemetry.telemetry_end_frame(tel, 1000)
	telemetry.telemetry_close(tel)
	testing.expect_value(t, tel.frames, 0)
}

@(test)
test_grid_dump_format :: proc(t: ^testing.T) {
	term: core_terminal.Terminal
	core_terminal.terminal_init(&term, 3, 10)
	defer core_terminal.terminal_destroy(&term)
	core_terminal.terminal_feed_string(&term, "hello\r\n  wo世界")

	text := telemetry.grid_dump_format(&term)
	defer delete(text)
	lines := strings.split(text, "\n", context.temp_allocator)
	testing.expect(t, strings.has_prefix(lines[0], "# rows=3 cols=10 cursor=1,8 alt=false"), lines[0])
	testing.expect_value(t, lines[1], "hello")
	testing.expect_value(t, lines[2], "  wo世界")
	testing.expect_value(t, lines[3], "")
}

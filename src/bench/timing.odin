package bench

import "../platform"

// Timer provides high-resolution timing measurements.
// All internal storage is in nanoseconds after conversion from platform ticks.
Timer :: struct {
	start_time: i64, // Platform ticks at start
	end_time:   i64, // Platform ticks at end
}

// timer_start records the current platform time as the timer's start time.
timer_start :: proc(t: ^Timer) {
	t.start_time = platform.platform_now()
	t.end_time = 0
}

// timer_stop records the current platform time as the timer's end time.
timer_stop :: proc(t: ^Timer) {
	t.end_time = platform.platform_now()
}

// timer_delta_ns returns the elapsed time between start and stop in nanoseconds.
// Returns 0 if the timer was not properly started/stopped.
timer_delta_ns :: proc(t: ^Timer) -> i64 {
	if t.end_time <= t.start_time {
		return 0
	}
	return platform.platform_ticks_to_ns(t.end_time - t.start_time)
}

// timer_delta_us returns the elapsed time in microseconds.
timer_delta_us :: proc(t: ^Timer) -> f64 {
	return f64(timer_delta_ns(t)) / 1000.0
}

// timer_delta_ms returns the elapsed time in milliseconds.
timer_delta_ms :: proc(t: ^Timer) -> f64 {
	return f64(timer_delta_ns(t)) / 1_000_000.0
}

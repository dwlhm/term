package platform

// Platform-specific timing using mach_absolute_time on macOS.
// Provides high-resolution timing for benchmark measurements.

foreign import system "system:system"

Mach_Timebase_Info :: struct {
	numer: u32,
	denom: u32,
}

foreign system {
	mach_absolute_time :: proc() -> u64 ---
	mach_timebase_info :: proc(info: ^Mach_Timebase_Info) -> i32 ---
}

// Cached timebase values for tick-to-nanosecond conversion.
_timebase_initialized: bool = false
_timebase_numer:      u32  = 0
_timebase_denom:      u32  = 0

_ensure_timebase :: proc() {
	if !_timebase_initialized {
		info: Mach_Timebase_Info
		mach_timebase_info(&info)
		_timebase_numer = info.numer
		_timebase_denom = info.denom
		_timebase_initialized = true
	}
}

// platform_now returns the current platform-specific timestamp in ticks.
// Use platform_ticks_to_ns to convert the delta between two calls to nanoseconds.
platform_now :: proc() -> i64 {
	return i64(mach_absolute_time())
}

// platform_ticks_to_ns converts a duration in platform ticks to nanoseconds.
// The conversion uses the mach timebase info for accurate results.
platform_ticks_to_ns :: proc(ticks: i64) -> i64 {
	_ensure_timebase()
	// ticks * numer / denom = nanoseconds
	// Use i128-style math to avoid overflow: split into quotient and remainder
	t := u64(ticks)
	quot := t / u64(_timebase_denom)
	rem := t % u64(_timebase_denom)
	ns := quot * u64(_timebase_numer) + (rem * u64(_timebase_numer)) / u64(_timebase_denom)
	return i64(ns)
}

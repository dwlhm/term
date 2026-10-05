package platform

import "core:time"

// Platform-specific high-resolution timing.
// On macOS: uses mach_absolute_time.
// On Linux/other: uses core:time tick_now.

when ODIN_OS == .Darwin {
	foreign import system "system:system"

	Mach_Timebase_Info :: struct {
		numer: u32,
		denom: u32,
	}

	foreign system {
		mach_absolute_time :: proc() -> u64 ---
		mach_timebase_info :: proc(info: ^Mach_Timebase_Info) -> i32 ---
	}

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

	platform_now :: proc() -> i64 {
		return i64(mach_absolute_time())
	}

	platform_ticks_to_ns :: proc(ticks: i64) -> i64 {
		_ensure_timebase()
		t := u64(ticks)
		quot := t / u64(_timebase_denom)
		rem := t % u64(_timebase_denom)
		ns := quot * u64(_timebase_numer) + (rem * u64(_timebase_numer)) / u64(_timebase_denom)
		return i64(ns)
	}
} else {
	platform_now :: proc() -> i64 {
		return time.tick_now()._nsec
	}

	platform_ticks_to_ns :: proc(ticks: i64) -> i64 {
		return ticks
	}
}

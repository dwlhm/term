package diag

// macOS process and machine CPU metrics.
//
// Process counters come from the Mach task API (task_info with
// MACH_TASK_BASIC_INFO for resident size and TASK_THREAD_TIMES_INFO for
// accumulated CPU time), machine load comes from host_statistics with
// HOST_CPU_LOAD_INFO.
// Everything is read-only: no Mach port is created, owned, or leaked by this
// file, and the thread-list buffer used to count threads is static storage
// reused for the life of the process.
//
// Only the sampling lives here. Turning two samples into a utilisation
// percentage is metrics_cpu_pct, which is pure and separately testable.

import "core:sync"
import "core:sys/darwin"

when ODIN_OS == .Darwin {

foreign import libsystem "system:System"

@(default_calling_convention = "c")
foreign libsystem {
	mach_host_self  :: proc() -> darwin.mach_port_t ---
	host_statistics :: proc(host: darwin.mach_port_t, flavor: i32, info: rawptr, count: ^u32) -> darwin.Kern_Return ---
}

// Bindings below are absent from the vendored core:sys/darwin collection
// (which provides mach_task_self, task_info and task_threads, but neither
// mach_host_self, host_statistics nor the task info structs). They are
// transcribed verbatim from <mach/task_info.h> and <mach/mach_host.h> and
// declared here rather than in the toolchain vendor tree, so that
// `make build` never depends on a patched Odin installation. Moving them into
// core:sys/darwin is a mechanical follow-up that this file does not require.

_METRICS_KERN_SUCCESS :: darwin.Kern_Return(0)

// Info flavors and natural_t counts, from <mach/task_info.h> and
// <mach/mach_host.h>. These are the preprocessor values of MACH_TASK_BASIC_INFO
// (20), TASK_THREAD_TIMES_INFO (3) and HOST_CPU_LOAD_INFO (3) on LP64.
_MACH_TASK_BASIC_INFO_FLAVOR    :: 20
_MACH_TASK_BASIC_INFO_COUNT    :: 12
_TASK_THREAD_TIMES_INFO_FLAVOR :: 3
_TASK_THREAD_TIMES_INFO_COUNT  :: 4
_HOST_CPU_LOAD_INFO_FLAVOR     :: 3
_HOST_CPU_LOAD_INFO_COUNT      :: 4

// Index into host_cpu_load_info.cpu_ticks.
_HOST_TICK_USER   :: 0
_HOST_TICK_SYSTEM :: 1
_HOST_TICK_IDLE   :: 2
_HOST_TICK_NICE   :: 3

// Static capacity of the task_threads buffer. A terminal emulator runs a
// handful of threads; a task with more threads than this reports the capped
// count rather than allocating.
_METRICS_THREADS_CAP :: 512

// _Mach_Task_Info aliases the vendored `info` parameter type so the cast at
// the call site does not have to spell out the qualified distinct type.
_Mach_Task_Info :: darwin.task_info_t

// _Time_Value mirrors C `time_value_t`: two 32-bit fields, ticks of 1us.
_Time_Value :: struct {
	seconds:      i32,
	microseconds: i32,
}

// _Mach_Task_Basic_Info mirrors C `struct mach_task_basic_info`, the flavour
// the SDK header tells callers to prefer over the legacy packed
// `struct task_basic_info`. Every field is naturally aligned, so the Odin
// layout is byte-identical to the C one (48 bytes, 12 natural_t words).
_Mach_Task_Basic_Info :: struct {
	virtual_size:      u64,
	resident_size:     u64,
	resident_size_max: u64,
	user_time:         _Time_Value,
	system_time:       _Time_Value,
	policy:            i32,
	suspend_count:     i32,
}

// _Task_Thread_Times_Info mirrors C `struct task_thread_times_info`: two
// consecutive 8-byte time values, also naturally aligned.
_Task_Thread_Times_Info :: struct {
	user_time:   _Time_Value,
	system_time: _Time_Value,
}

// _Host_Cpu_Load_Info mirrors C `struct host_cpu_load_info`.
_Host_Cpu_Load_Info :: struct {
	cpu_ticks: [_HOST_CPU_LOAD_INFO_COUNT]i32,
}

// Metric_Sample is one instantaneous reading of the process counters.
// cpu_user_ns and cpu_system_ns are cumulative microsecond-resolution Mach
// counters widened to nanoseconds, so they must be differenced before use.
// system_cpu_pct is the only field that is already a rate.
Metric_Sample :: struct {
	cpu_user_ns:    u64,
	cpu_system_ns:  u64,
	resident_bytes: u64,
	thread_count:   u32,
	system_cpu_pct: f32,
}

_Host_Ticks :: struct {
	valid: bool,
	ticks: [_HOST_CPU_LOAD_INFO_COUNT]i32,
}

@(private)
_metrics_mutex: sync.Mutex

// Previous HOST_CPU_LOAD_INFO reading. host_statistics reports cumulative
// per-state tick counters, never an instantaneous percentage, so the machine
// load number is the delta between two readings.
@(private)
_metrics_host_prev: _Host_Ticks

// Static storage backing the task_threads listing: no allocation, no leak.
@(private)
_metrics_thread_buf: [_METRICS_THREADS_CAP]darwin.thread_act_t

// _metrics_time_value_ns widens a Mach time_value_t to nanoseconds.
@(private)
_metrics_time_value_ns :: proc(tv: _Time_Value) -> u64 {
	if tv.seconds < 0 || tv.microseconds < 0 {
		return 0
	}
	return u64(tv.seconds) * 1_000_000_000 + u64(tv.microseconds) * 1_000
}

// _metrics_tick_delta returns the difference between two cumulative tick
// counters, clamped at zero so a counter reset cannot underflow.
@(private)
_metrics_tick_delta :: proc(curr, prev: i32) -> i64 {
	d := i64(curr) - i64(prev)
	if d < 0 {
		return 0
	}
	return d
}

// _metrics_machine_cpu_pct turns two HOST_CPU_LOAD_INFO readings into a
// machine-wide utilisation percentage in [0, 100].
//
// Because the four counters are cumulative mach ticks, the percentage is the
// busy share of the window: busy = user + system + nice, total = busy + idle.
// Numerator and denominator both scale with the window, so the ratio needs
// neither a clock nor a core count. Returns 0 on the very first call, which
// means "no previous sample yet" and not "the machine is idle".
@(private)
_metrics_machine_cpu_pct :: proc(curr: _Host_Cpu_Load_Info) -> f32 {
	sync.mutex_lock(&_metrics_mutex)
	defer sync.mutex_unlock(&_metrics_mutex)

	prev := _metrics_host_prev
	_metrics_host_prev.ticks = curr.cpu_ticks
	_metrics_host_prev.valid = true
	if !prev.valid {
		return 0
	}

	busy := _metrics_tick_delta(curr.cpu_ticks[_HOST_TICK_USER], prev.ticks[_HOST_TICK_USER]) +
	        _metrics_tick_delta(curr.cpu_ticks[_HOST_TICK_SYSTEM], prev.ticks[_HOST_TICK_SYSTEM]) +
	        _metrics_tick_delta(curr.cpu_ticks[_HOST_TICK_NICE], prev.ticks[_HOST_TICK_NICE])
	idle := _metrics_tick_delta(curr.cpu_ticks[_HOST_TICK_IDLE], prev.ticks[_HOST_TICK_IDLE])
	total := busy + idle
	if total <= 0 {
		return 0
	}
	return f32(busy) * 100.0 / f32(total)
}

// _metrics_thread_count returns the number of threads in a task, or 0 when
// the kernel refuses the query. The listing buffer is static storage; a task
// with more threads than the buffer holds reports the capped count.
@(private)
_metrics_thread_count :: proc(task: darwin.task_t) -> u32 {
	list := cast(^darwin.thread_list_t)(raw_data(&_metrics_thread_buf))
	count: u32 = u32(_METRICS_THREADS_CAP)
	if darwin.task_threads(task, list, &count) != _METRICS_KERN_SUCCESS {
		return 0
	}
	return min(count, u32(_METRICS_THREADS_CAP))
}

// metrics_sample_cpu reads process CPU time, resident size, thread count and
// machine-wide CPU load in one call.
//
// Returns a fully populated Metric_Sample; any counter the kernel declines to
// report is left at zero rather than guessed. Safe to call from any thread,
// including a Metal completion handler: it takes a mutex only for the
// machine-load window, holds no Mach port, and never allocates.
metrics_sample_cpu :: proc() -> Metric_Sample {
	sample: Metric_Sample
	task := darwin.mach_task_self()

	basic: _Mach_Task_Basic_Info
	basic_count := u32(_MACH_TASK_BASIC_INFO_COUNT)
	if darwin.task_info(task, _MACH_TASK_BASIC_INFO_FLAVOR, cast(_Mach_Task_Info)(rawptr(&basic)), &basic_count) == _METRICS_KERN_SUCCESS {
		sample.resident_bytes = basic.resident_size
		// TASK_THREAD_TIMES_INFO is the authoritative accumulated time for
		// live threads, but it is only accurate while the task is suspended,
		// so the basic-info times are the fallback, not the primary source.
		thread_times: _Task_Thread_Times_Info
		thread_count := u32(_TASK_THREAD_TIMES_INFO_COUNT)
		if darwin.task_info(task, _TASK_THREAD_TIMES_INFO_FLAVOR, cast(_Mach_Task_Info)(rawptr(&thread_times)), &thread_count) == _METRICS_KERN_SUCCESS {
			sample.cpu_user_ns = _metrics_time_value_ns(thread_times.user_time)
			sample.cpu_system_ns = _metrics_time_value_ns(thread_times.system_time)
		} else {
			sample.cpu_user_ns = _metrics_time_value_ns(basic.user_time)
			sample.cpu_system_ns = _metrics_time_value_ns(basic.system_time)
		}
	}

	sample.thread_count = _metrics_thread_count(task)

	host_load: _Host_Cpu_Load_Info
	host_count := u32(_HOST_CPU_LOAD_INFO_COUNT)
	if host_statistics(mach_host_self(), _HOST_CPU_LOAD_INFO_FLAVOR, rawptr(&host_load), &host_count) == _METRICS_KERN_SUCCESS {
		sample.system_cpu_pct = _metrics_machine_cpu_pct(host_load)
	}

	return sample
}

// metrics_cpu_pct converts two cumulative CPU samples into process
// utilisation over the wall-clock window between them.
//
// CPU% = (delta_user_ns + delta_system_ns) / elapsed_ns * 100
//
// The value is deliberately not clamped to 100: a multi-threaded process
// legitimately consumes several cores' worth of CPU, and a terminal emulator
// running a PTY reader, a raster worker and the render loop reads well above
// 100% while it is busy. Clamping would hide exactly the cost this
// instrumentation exists to expose.
//
// Returns 0 when elapsed_ns is zero (no measurable window) or when prev is
// nil. Both deltas are clamped at zero so a counter reset cannot wrap.
metrics_cpu_pct :: proc(prev: ^Metric_Sample, curr: Metric_Sample, elapsed_ns: u64) -> f32 {
	if prev == nil || elapsed_ns == 0 {
		return 0
	}
	user := curr.cpu_user_ns - min(curr.cpu_user_ns, prev.cpu_user_ns)
	sys := curr.cpu_system_ns - min(curr.cpu_system_ns, prev.cpu_system_ns)
	return f32(user + sys) * 100.0 / f32(elapsed_ns)
}

// metrics_system_cpu_pct returns the machine-wide CPU load carried by a
// sample. It exists so callers never need to know that the percentage was
// already computed during sampling; it is a pure accessor and takes no locks.
metrics_system_cpu_pct :: proc(s: Metric_Sample) -> f32 {
	return s.system_cpu_pct
}

}

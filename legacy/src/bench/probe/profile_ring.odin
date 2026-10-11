package bench_probe

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import platform "../../platform"

Profile_Phase :: enum {
	Idle,
	Running,
	Complete,
	Failed,
}

Profile_Record_Kind :: enum {
	Scenario_Phase,
	Resize_Begin,
	Resize_End,
	Resize_Stage,
	Frame_Begin,
	Frame_End,
	Dropped_Records,
	Grid_Surface,
	Pixels_Only,
	Noop,
	Restore,
	Width_Step,
	Height_Step,
}

Profile_Record :: struct {
	timestamp_ns:      u64,
	sequence:          u64,
	phase:             Profile_Phase,
	kind:              Profile_Record_Kind,
	requested_pixel_w: i32,
	requested_pixel_h: i32,
	actual_pixel_w:    i32,
	actual_pixel_h:    i32,
	requested_rows:    i32,
	requested_cols:    i32,
	actual_rows:       i32,
	actual_cols:       i32,
	duration_ns:       u64,
	mode_threaded:     bool,
}

PROFILE_RECORD_CAP :: 8192

Profile_Ring :: struct {
	records:  [PROFILE_RECORD_CAP]Profile_Record,
	head:     u32,
	tail:     u32,
	count:    u32,
	dropped:  u64,
	stopping: bool,
	mutex:    sync.Mutex,
	thread:   ^thread.Thread,
}

_profile_ring:          Profile_Ring
_profile_enabled:       b32
_profile_sequence:      u64
_profile_export_failed: b32
_profile_phase_value:   u32

profile_phase_publish :: proc(phase: Profile_Phase) {
	sync.atomic_store(&_profile_phase_value, u32(phase))
}

profile_clock_ns :: proc() -> u64 {
	if !sync.atomic_load(&_profile_enabled) do return 0
	return u64(platform.platform_ticks_to_ns(platform.platform_now()))
}

profile_elapsed_ns :: proc(start_ns: u64) -> u64 {
	if start_ns == 0 do return 0
	return profile_clock_ns() - start_ns
}

profile_ring_init :: proc(r: ^Profile_Ring) -> bool {
	if r == nil do return false
	r^ = {}
	sync.atomic_store(&_profile_export_failed, false)
	path, ok := os.lookup_env("TERM_PROFILE_RESIZE_TELEMETRY_FILE", context.temp_allocator)
	if !ok || len(path) == 0 do return false
	if os.write_entire_file(path, "timestamp_ns,sequence,phase,kind,requested_pixel_w,requested_pixel_h,actual_pixel_w,actual_pixel_h,requested_rows,requested_cols,actual_rows,actual_cols,duration_ns,threaded\n") != nil {
		return false
	}
	r.thread = thread.create(profile_export_proc)
	if r.thread == nil do return false
	r.thread.data = r
	thread.start(r.thread)
	return true
}

profile_try_record :: proc(r: ^Profile_Ring, record: Profile_Record) -> bool {
	if r == nil do return false
	if !sync.mutex_try_lock(&r.mutex) {
		_ = sync.atomic_add(&r.dropped, 1)
		return false
	}
	if r.count >= PROFILE_RECORD_CAP || r.stopping {
		sync.mutex_unlock(&r.mutex)
		_ = sync.atomic_add(&r.dropped, 1)
		return false
	}
	r.records[r.tail] = record
	r.tail = (r.tail + 1) % PROFILE_RECORD_CAP
	r.count += 1
	sync.mutex_unlock(&r.mutex)
	return true
}

profile_export_proc :: proc(t: ^thread.Thread) {
	r := (^Profile_Ring)(t.data)
	if r == nil do return
	path, ok := os.lookup_env("TERM_PROFILE_RESIZE_TELEMETRY_FILE", context.temp_allocator)
	if !ok || len(path) == 0 {
		sync.atomic_store(&_profile_export_failed, true)
		return
	}
	file, err := os.open(path, {.Write, .Create, .Append})
	if err != nil {
		sync.atomic_store(&_profile_export_failed, true)
		return
	}
	for {
		if !sync.mutex_try_lock(&r.mutex) {
			time.sleep(time.Millisecond)
			continue
		}
		if r.count == 0 {
			stopping := r.stopping
			sync.mutex_unlock(&r.mutex)
			if stopping do break
			time.sleep(time.Millisecond)
			continue
		}
		record := r.records[r.head]
		r.head = (r.head + 1) % PROFILE_RECORD_CAP
		r.count -= 1
		sync.mutex_unlock(&r.mutex)
		line := fmt.tprintf("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", record.timestamp_ns, record.sequence, record.phase, record.kind, record.requested_pixel_w, record.requested_pixel_h, record.actual_pixel_w, record.actual_pixel_h, record.requested_rows, record.requested_cols, record.actual_rows, record.actual_cols, record.duration_ns, 1 if record.mode_threaded else 0)
		written, write_err := os.write(file, transmute([]byte)line)
		if write_err != nil || written != len(line) {
			sync.atomic_store(&_profile_export_failed, true)
		}
		free_all(context.temp_allocator)
	}
	dropped := sync.atomic_load(&r.dropped)
	line := fmt.tprintf("0,0,%d,%d,0,0,0,0,0,0,0,0,%d,0\n", Profile_Phase.Failed, Profile_Record_Kind.Dropped_Records, dropped)
	written, write_err := os.write(file, transmute([]byte)line)
	if write_err != nil || written != len(line) {
		sync.atomic_store(&_profile_export_failed, true)
	}
	free_all(context.temp_allocator)
	if os.close(file) != nil {
		sync.atomic_store(&_profile_export_failed, true)
	}
}

profile_ring_stop_and_join :: proc(r: ^Profile_Ring) {
	if r == nil || r.thread == nil do return
	sync.mutex_lock(&r.mutex)
	r.stopping = true
	sync.mutex_unlock(&r.mutex)
	thread.join(r.thread)
	thread.destroy(r.thread)
	r.thread = nil
}

profile_record :: proc(kind: Profile_Record_Kind, phase: Profile_Phase, pixel_w, pixel_h, rows, cols: i32, duration_ns: u64, threaded: bool) {
	if !sync.atomic_load(&_profile_enabled) do return
	sequence := sync.atomic_add(&_profile_sequence, 1) + 1
	now := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	stable_phase := Profile_Phase(sync.atomic_load(&_profile_phase_value))
	_ = profile_try_record(&_profile_ring, Profile_Record{timestamp_ns = now, sequence = sequence, phase = stable_phase, kind = kind, requested_pixel_w = pixel_w, requested_pixel_h = pixel_h, actual_pixel_w = pixel_w, actual_pixel_h = pixel_h, requested_rows = rows, requested_cols = cols, actual_rows = rows, actual_cols = cols, duration_ns = duration_ns, mode_threaded = threaded})
	_ = phase
}

profile_record_resize :: proc(phase: Profile_Phase, kind: Profile_Record_Kind, requested_w, requested_h, actual_w, actual_h, requested_rows, requested_cols, actual_rows, actual_cols: i32, duration_ns: u64, threaded: bool) {
	if !sync.atomic_load(&_profile_enabled) do return
	sequence := sync.atomic_add(&_profile_sequence, 1) + 1
	now := u64(platform.platform_ticks_to_ns(platform.platform_now()))
	stable_phase := Profile_Phase(sync.atomic_load(&_profile_phase_value))
	record := Profile_Record{timestamp_ns = now, sequence = sequence, phase = stable_phase, kind = kind, requested_pixel_w = requested_w, requested_pixel_h = requested_h, actual_pixel_w = actual_w, actual_pixel_h = actual_h, requested_rows = requested_rows, requested_cols = requested_cols, actual_rows = actual_rows, actual_cols = actual_cols, duration_ns = duration_ns, mode_threaded = threaded}
	_ = profile_try_record(&_profile_ring, record)
	_ = phase
}

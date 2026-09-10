package bench

import "base:runtime"
import "../platform"
import "core:os"

// Trace records a sequence of byte events with optional timestamps.
// Supports deterministic replay of recorded data.
Trace :: struct {
	name:           string,
	data:           []u8,
	timestamps:     []i64,
	has_timestamps: bool,
	capacity:       int,
	data_count:     int,
	time_count:     int,
}

// trace_init allocates a Trace with the given name and capacity.
// If with_timestamps is true, timestamps are recorded alongside data.
// The caller must call trace_destroy when done.
trace_init :: proc(name: string, capacity: int, with_timestamps: bool, allocator: runtime.Allocator = context.allocator) -> Trace {
	t := Trace{
		name           = name,
		data           = make([]u8, capacity, allocator),
		capacity       = capacity,
		data_count     = 0,
		has_timestamps = with_timestamps,
	}
	if with_timestamps {
		t.timestamps = make([]i64, capacity, allocator)
		t.time_count = 0
	}
	return t
}

// trace_destroy frees all memory used by the Trace.
trace_destroy :: proc(t: ^Trace) {
	if t.data != nil {
		delete(t.data)
		t.data = nil
	}
	if t.timestamps != nil {
		delete(t.timestamps)
		t.timestamps = nil
	}
	t.data_count = 0
	t.time_count = 0
	t.capacity = 0
}

// trace_record appends a byte to the trace data.
// If timestamps are enabled, the current platform time is also recorded.
trace_record :: proc(t: ^Trace, b: u8) {
	if t.data_count < t.capacity {
		t.data[t.data_count] = b
		t.data_count += 1
		if t.has_timestamps && t.time_count < t.capacity {
			t.timestamps[t.time_count] = platform.platform_now()
			t.time_count += 1
		}
	}
}

// trace_record_with_time appends a byte with an explicit timestamp.
// This is useful for replaying traces with their original timing.
trace_record_with_time :: proc(t: ^Trace, b: u8, timestamp: i64) {
	if t.data_count < t.capacity {
		t.data[t.data_count] = b
		t.data_count += 1
		if t.has_timestamps && t.time_count < t.capacity {
			t.timestamps[t.time_count] = timestamp
			t.time_count += 1
		}
	}
}

// Trace_Replay_Callback is the signature for trace replay callbacks.
Trace_Replay_Callback :: proc(b: u8, timestamp: i64)

// trace_replay iterates through all recorded data, calling the callback for each byte.
// If timestamps are available, the callback receives the timestamp as well.
// Returns the number of bytes replayed.
trace_replay :: proc(t: ^Trace, callback: Trace_Replay_Callback) -> int {
	count := 0
	for i in 0..<t.data_count {
		ts: i64 = 0
		if t.has_timestamps && i < t.time_count {
			ts = t.timestamps[i]
		}
		callback(t.data[i], ts)
		count += 1
	}
	return count
}

// Trace file format:
// [4 bytes] magic: "TRCE"
// [4 bytes] name length (u32)
// [N bytes] name
// [1 byte]  has_timestamps flag
// [4 bytes] data count (u32)
// [N bytes] data
// [4 bytes] timestamp count (u32) (only if has_timestamps)
// [N*8 bytes] timestamps (only if has_timestamps)

_TRACE_MAGIC :: "TRCE"

// trace_save writes the trace to a file in binary format.
// Returns true on success, false on failure.
trace_save :: proc(t: ^Trace, path: string) -> bool {
	// Calculate total size
	name_len := len(t.name)
	size := 4 + 4 + name_len + 1 + 4 + t.data_count
	if t.has_timestamps {
		size += 4 + t.time_count * 8
	}

	// Build the buffer
	buf := make([]u8, size)
	offset: int = 0

	// Magic
	copy(buf[offset:], _TRACE_MAGIC)
	offset += 4

	// Name length + name
	name_len_u32 := u32(name_len)
	buf[offset + 0] = u8(name_len_u32 & 0xFF)
	buf[offset + 1] = u8((name_len_u32 >> 8) & 0xFF)
	buf[offset + 2] = u8((name_len_u32 >> 16) & 0xFF)
	buf[offset + 3] = u8((name_len_u32 >> 24) & 0xFF)
	offset += 4
	copy(buf[offset:], t.name)
	offset += name_len

	// has_timestamps flag
	if t.has_timestamps {
		buf[offset] = 1
	} else {
		buf[offset] = 0
	}
	offset += 1

	// Data count
	data_count_u32 := u32(t.data_count)
	buf[offset + 0] = u8(data_count_u32 & 0xFF)
	buf[offset + 1] = u8((data_count_u32 >> 8) & 0xFF)
	buf[offset + 2] = u8((data_count_u32 >> 16) & 0xFF)
	buf[offset + 3] = u8((data_count_u32 >> 24) & 0xFF)
	offset += 4

	// Data
	copy(buf[offset:], t.data[:t.data_count])
	offset += t.data_count

	// Timestamps (if present)
	if t.has_timestamps {
		time_count_u32 := u32(t.time_count)
		buf[offset + 0] = u8(time_count_u32 & 0xFF)
		buf[offset + 1] = u8((time_count_u32 >> 8) & 0xFF)
		buf[offset + 2] = u8((time_count_u32 >> 16) & 0xFF)
		buf[offset + 3] = u8((time_count_u32 >> 24) & 0xFF)
		offset += 4

		for i in 0..<t.time_count {
			ts := t.timestamps[i]
			buf[offset + 0] = u8(u64(ts) & 0xFF)
			buf[offset + 1] = u8((u64(ts) >> 8) & 0xFF)
			buf[offset + 2] = u8((u64(ts) >> 16) & 0xFF)
			buf[offset + 3] = u8((u64(ts) >> 24) & 0xFF)
			buf[offset + 4] = u8((u64(ts) >> 32) & 0xFF)
			buf[offset + 5] = u8((u64(ts) >> 40) & 0xFF)
			buf[offset + 6] = u8((u64(ts) >> 48) & 0xFF)
			buf[offset + 7] = u8((u64(ts) >> 56) & 0xFF)
			offset += 8
		}
	}

	// Write to file
	f, err := os.open(path, {os.File_Flag.Write, os.File_Flag.Create, os.File_Flag.Trunc})
	if err != os.ERROR_NONE {
		delete(buf)
		return false
	}
	defer os.close(f)

	n, write_err := os.write_slice(f, buf)
	delete(buf)
	return write_err == os.ERROR_NONE && n == size
}

// trace_load reads a trace from a binary file.
// Returns the loaded Trace and true on success, or an empty Trace and false on failure.
// The caller must call trace_destroy on the returned Trace.
trace_load :: proc(path: string, allocator: runtime.Allocator = context.allocator) -> (Trace, bool) {
	// Get file size first
	file_info, stat_err := os.stat(path, allocator)
	if stat_err != os.ERROR_NONE {
		return Trace{}, false
	}
	file_size := int(file_info.size)
	if file_size < 13 { // Minimum: magic(4) + name_len(4) + name(0) + flag(1) + data_count(4)
		return Trace{}, false
	}

	f, err := os.open(path, {os.File_Flag.Read})
	if err != os.ERROR_NONE {
		return Trace{}, false
	}
	defer os.close(f)

	// Read entire file
	buf := make([]u8, file_size, allocator)
	n, read_err := os.read_slice(f, buf)
	if read_err != os.ERROR_NONE || n != file_size {
		delete(buf)
		return Trace{}, false
	}

	offset: int = 0

	// Verify magic
	if string(buf[offset:offset+4]) != _TRACE_MAGIC {
		delete(buf)
		return Trace{}, false
	}
	offset += 4

	// Name length
	name_len := int(u32(buf[offset]) | u32(buf[offset+1])<<8 | u32(buf[offset+2])<<16 | u32(buf[offset+3])<<24)
	offset += 4
	if offset + name_len > file_size {
		delete(buf)
		return Trace{}, false
	}

	// Name
	name := string(buf[offset:offset+name_len])
	offset += name_len

	// has_timestamps flag
	if offset >= file_size {
		delete(buf)
		return Trace{}, false
	}
	has_ts := buf[offset] != 0
	offset += 1

	// Data count
	if offset + 4 > file_size {
		delete(buf)
		return Trace{}, false
	}
	data_count := int(u32(buf[offset]) | u32(buf[offset+1])<<8 | u32(buf[offset+2])<<16 | u32(buf[offset+3])<<24)
	offset += 4

	if offset + data_count > file_size {
		delete(buf)
		return Trace{}, false
	}

	// Create trace with exact capacity
	t := trace_init(name, data_count, has_ts, allocator)

	// Copy data
	copy(t.data, buf[offset:offset+data_count])
	t.data_count = data_count
	offset += data_count

	// Timestamps
	if has_ts {
		if offset + 4 > file_size {
			trace_destroy(&t)
			delete(buf)
			return Trace{}, false
		}
		time_count := int(u32(buf[offset]) | u32(buf[offset+1])<<8 | u32(buf[offset+2])<<16 | u32(buf[offset+3])<<24)
		offset += 4

		if offset + time_count * 8 > file_size {
			trace_destroy(&t)
			delete(buf)
			return Trace{}, false
		}

		for i in 0..<time_count {
			ts := i64(
				u64(buf[offset + 0]) |
				u64(buf[offset + 1]) << 8 |
				u64(buf[offset + 2]) << 16 |
				u64(buf[offset + 3]) << 24 |
				u64(buf[offset + 4]) << 32 |
				u64(buf[offset + 5]) << 40 |
				u64(buf[offset + 6]) << 48 |
				u64(buf[offset + 7]) << 56,
			)
			t.timestamps[i] = ts
			offset += 8
		}
		t.time_count = time_count
	}

	delete(buf)
	return t, true
}

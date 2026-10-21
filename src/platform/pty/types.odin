package platform_pty

import "base:runtime"
import "core:sync"
import "core:thread"

Pty_Error :: enum {
	None,
	Spawn_Failed,
	Master_Open_Failed,
	Slave_Open_Failed,
	Pipe_Failed,
	Fork_Failed,
	Write_Failed,
	Closed,
}

Pty_Config :: struct {
	shell:  string,
	argv:   []string,
	env:    []string,
	cwd:    string,
	rows:   int,
	cols:   int,
	xpixel: int,
	ypixel: int,
}

PTY_INITIAL_RING_CAPACITY :: 256 * 1024 // 256 KiB initial buffer, grows on demand

Pty_Ring_Buffer :: struct {
	buf:       []u8,
	capacity:  int,
	head:      int, // write cursor
	tail:      int, // read cursor
	count:     int, // bytes currently stored
	mutex:     sync.Mutex,
	allocator: runtime.Allocator,
}

ring_init :: proc(r: ^Pty_Ring_Buffer, initial_capacity: int = PTY_INITIAL_RING_CAPACITY, allocator := context.allocator) {
	if r == nil do return
	r.allocator = allocator
	r.capacity = max(initial_capacity, 1024)
	r.buf = make([]u8, r.capacity, r.allocator)
	r.head = 0
	r.tail = 0
	r.count = 0
}

ring_destroy :: proc(r: ^Pty_Ring_Buffer) {
	if r == nil do return
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)
	if len(r.buf) > 0 {
		delete(r.buf, r.allocator)
		r.buf = nil
	}
	r.capacity = 0
	r.count = 0
	r.head = 0
	r.tail = 0
}

ring_available :: proc(r: ^Pty_Ring_Buffer) -> int {
	if r == nil do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)
	return r.count
}

ring_write :: proc(r: ^Pty_Ring_Buffer, data: []u8) -> int {
	if r == nil || len(data) == 0 do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)

	// Ensure buffer capacity grows dynamically without data loss
	needed := r.count + len(data)
	if needed > r.capacity {
		new_cap := max(r.capacity * 2, needed)
		new_buf := make([]u8, new_cap, r.allocator)
		if r.count > 0 {
			if r.head > r.tail {
				copy(new_buf[:r.count], r.buf[r.tail:r.head])
			} else {
				part1 := r.capacity - r.tail
				copy(new_buf[:part1], r.buf[r.tail:r.capacity])
				copy(new_buf[part1:r.count], r.buf[:r.head])
			}
		}
		if len(r.buf) > 0 do delete(r.buf, r.allocator)
		r.buf = new_buf
		r.capacity = new_cap
		r.tail = 0
		r.head = r.count
	}

	// Contiguous slice copy into circular buffer
	if r.head + len(data) <= r.capacity {
		copy(r.buf[r.head : r.head + len(data)], data)
		r.head = (r.head + len(data)) % r.capacity
	} else {
		part1 := r.capacity - r.head
		copy(r.buf[r.head:r.capacity], data[:part1])
		copy(r.buf[:len(data) - part1], data[part1:])
		r.head = len(data) - part1
	}
	r.count += len(data)
	return len(data)
}

ring_read :: proc(r: ^Pty_Ring_Buffer, out: []u8) -> int {
	if r == nil || len(out) == 0 do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)

	to_read := min(len(out), r.count)
	if to_read <= 0 do return 0

	if r.tail + to_read <= r.capacity {
		copy(out[:to_read], r.buf[r.tail : r.tail + to_read])
		r.tail = (r.tail + to_read) % r.capacity
	} else {
		part1 := r.capacity - r.tail
		copy(out[:part1], r.buf[r.tail:r.capacity])
		copy(out[part1:to_read], r.buf[:to_read - part1])
		r.tail = to_read - part1
	}
	r.count -= to_read
	return to_read
}

Pty_Handle :: struct {
	master_fd:    i32,
	child_pid:    i32,
	rows:         int,
	cols:         int,
	ring:         Pty_Ring_Buffer,
	is_running:   bool,
	exit_code:    int,
	drain_thread: ^thread.Thread,
}

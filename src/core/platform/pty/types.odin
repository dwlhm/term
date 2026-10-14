package platform_pty

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
	shell: string,
	argv:  []string,
	env:   []string,
	cwd:   string,
	rows:  int,
	cols:  int,
}

PTY_RING_CAPACITY :: 65536 // 64 KiB ring buffer

Pty_Ring_Buffer :: struct {
	buf:   [PTY_RING_CAPACITY]u8,
	head:  uint, // write cursor
	tail:  uint, // read cursor
	mutex: sync.Mutex,
}

ring_init :: proc(r: ^Pty_Ring_Buffer) {
	if r == nil do return
	r.head = 0
	r.tail = 0
}

ring_available :: proc(r: ^Pty_Ring_Buffer) -> int {
	if r == nil do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)

	h := r.head
	t := r.tail
	if h >= t {
		return int(h - t)
	}
	return int(PTY_RING_CAPACITY - (t - h))
}

ring_write :: proc(r: ^Pty_Ring_Buffer, data: []u8) -> int {
	if r == nil || len(data) == 0 do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)

	written := 0
	for b in data {
		next_head := (r.head + 1) % PTY_RING_CAPACITY
		if next_head == r.tail {
			// Buffer full: drop or advance tail (drop oldest)
			r.tail = (r.tail + 1) % PTY_RING_CAPACITY
		}
		r.buf[r.head] = b
		r.head = next_head
		written += 1
	}
	return written
}

ring_read :: proc(r: ^Pty_Ring_Buffer, out: []u8) -> int {
	if r == nil || len(out) == 0 do return 0
	sync.mutex_lock(&r.mutex)
	defer sync.mutex_unlock(&r.mutex)

	read_bytes := 0
	for read_bytes < len(out) && r.tail != r.head {
		out[read_bytes] = r.buf[r.tail]
		r.tail = (r.tail + 1) % PTY_RING_CAPACITY
		read_bytes += 1
	}
	return read_bytes
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

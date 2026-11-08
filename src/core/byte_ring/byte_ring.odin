package core_byte_ring

// Byte_Ring is a fixed-capacity FIFO of bytes; pushes are all-or-nothing.
Byte_Ring :: struct {
	buf:  []u8,
	head: int, // read position
	len:  int,
}

ring_push :: proc(r: ^Byte_Ring, parts: ..[]u8) -> bool {
	total := 0
	for p in parts do total += len(p)
	if total > len(r.buf) - r.len do return false
	for p in parts {
		tail := (r.head + r.len) % len(r.buf)
		first := min(len(p), len(r.buf) - tail)
		copy(r.buf[tail:tail + first], p[:first])
		copy(r.buf[:len(p) - first], p[first:])
		r.len += len(p)
	}
	return true
}

// ring_front is the contiguous readable run starting at head.
ring_front :: proc(r: ^Byte_Ring) -> []u8 {
	if r.len == 0 do return nil
	return r.buf[r.head:r.head + min(r.len, len(r.buf) - r.head)]
}

ring_consume :: proc(r: ^Byte_Ring, n: int) {
	k := min(n, r.len)
	r.len -= k
	r.head = 0 if r.len == 0 else (r.head + k) % len(r.buf)
}

ring_clear :: proc(r: ^Byte_Ring) { r.head, r.len = 0, 0 }

// ring_pop copies up to len(out) bytes out of the ring.
ring_pop :: proc(r: ^Byte_Ring, out: []u8) -> int {
	n := 0
	for n < len(out) && r.len > 0 {
		run := ring_front(r)
		k := copy(out[n:], run)
		ring_consume(r, k)
		n += k
	}
	return n
}

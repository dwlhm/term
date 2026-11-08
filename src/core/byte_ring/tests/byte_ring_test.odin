package core_byte_ring_tests

import "core:testing"
import ring "../"

@(test)
test_ring_push_pop_across_wrap :: proc(t: ^testing.T) {
	buf: [8]u8
	r := ring.Byte_Ring{buf = buf[:]}
	testing.expect(t, ring.ring_push(&r, transmute([]u8)string("12345")))
	out: [3]u8
	testing.expect_value(t, ring.ring_pop(&r, out[:]), 3)
	testing.expect_value(t, string(out[:]), "123")
	testing.expect(t, ring.ring_push(&r, transmute([]u8)string("67890")))
	out2: [7]u8
	testing.expect_value(t, ring.ring_pop(&r, out2[:]), 7)
	testing.expect_value(t, string(out2[:]), "4567890")
}

@(test)
test_ring_push_all_or_nothing :: proc(t: ^testing.T) {
	buf: [6]u8
	r := ring.Byte_Ring{buf = buf[:]}
	testing.expect(t, ring.ring_push(&r, transmute([]u8)string("abc")))
	testing.expect(t, !ring.ring_push(&r, transmute([]u8)string("defg")))
	testing.expect_value(t, r.len, 3)
	out: [4]u8
	testing.expect_value(t, ring.ring_pop(&r, out[:]), 3)
	testing.expect_value(t, string(out[:3]), "abc")
}

@(test)
test_ring_front_and_consume :: proc(t: ^testing.T) {
	buf: [8]u8
	r := ring.Byte_Ring{buf = buf[:]}
	testing.expect(t, ring.ring_push(&r, transmute([]u8)string("abcdef")))
	front := ring.ring_front(&r)
	testing.expect_value(t, string(front), "abcdef")
	ring.ring_consume(&r, 2)
	testing.expect_value(t, string(ring.ring_front(&r)), "cdef")
	ring.ring_clear(&r)
	testing.expect_value(t, r.len, 0)
	testing.expect(t, ring.ring_front(&r) == nil)
}

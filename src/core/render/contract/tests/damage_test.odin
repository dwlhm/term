package contract_tests

import "core:testing"
import contract "../"

@(test)
test_damage_rect_empty_union :: proc(t: ^testing.T) {
	empty := contract.damage_rect_make(0, 0, 0, 0)
	rect := contract.damage_rect_make(10, 20, 30, 40)

	// Union with empty rect (empty as first argument)
	u1 := contract.damage_rect_union(empty, rect)
	testing.expect_value(t, u1.x, 10)
	testing.expect_value(t, u1.y, 20)
	testing.expect_value(t, u1.w, 30)
	testing.expect_value(t, u1.h, 40)

	// Union with empty rect (empty as second argument)
	u2 := contract.damage_rect_union(rect, empty)
	testing.expect_value(t, u2.x, 10)
	testing.expect_value(t, u2.y, 20)
	testing.expect_value(t, u2.w, 30)
	testing.expect_value(t, u2.h, 40)

	// Union of two empty rects
	empty2 := contract.damage_rect_make(5, 5, 0, 100)
	u3 := contract.damage_rect_union(empty, empty2)
	testing.expect(t, contract.damage_rect_is_empty(u3))
}

@(test)
test_damage_rect_union_bounding_box :: proc(t: ^testing.T) {
	// Two disjoint rects:
	// r1 covers [10..30] x [10..30]
	// r2 covers [50..65] x [60..85]
	r1 := contract.damage_rect_make(10, 10, 20, 20)
	r2 := contract.damage_rect_make(50, 60, 15, 25)

	u := contract.damage_rect_union(r1, r2)
	testing.expect_value(t, u.x, 10)
	testing.expect_value(t, u.y, 10)
	testing.expect_value(t, u.w, 55)
	testing.expect_value(t, u.h, 75)
}

@(test)
test_damage_rect_overflow_guard :: proc(t: ^testing.T) {
	max_val := ~u32(0)

	// Extreme coordinates near ~u32(0) do not wrap around to zero
	r1 := contract.damage_rect_make(max_val - 10, max_val - 10, 20, 20)
	r2 := contract.damage_rect_make(0, 0, 10, 10)

	u := contract.damage_rect_union(r1, r2)
	testing.expect(t, !contract.damage_rect_is_empty(u))
	testing.expect_value(t, u.x, 0)
	testing.expect_value(t, u.y, 0)
	testing.expect_value(t, u.w, max_val)
	testing.expect_value(t, u.h, max_val)

	// Two rects both near max_val
	r3 := contract.damage_rect_make(max_val - 30, max_val - 30, 10, 10)
	r4 := contract.damage_rect_make(max_val - 20, max_val - 20, 50, 50)
	u2 := contract.damage_rect_union(r3, r4)
	testing.expect_value(t, u2.x, max_val - 30)
	testing.expect_value(t, u2.y, max_val - 30)
	testing.expect_value(t, u2.w, 30)
	testing.expect_value(t, u2.h, 30)

	// Expand near max_val
	r5 := contract.damage_rect_make(max_val - 20, max_val - 20, 10, 10)
	expanded := contract.damage_rect_expand(r5, 50, max_val, max_val)
	testing.expect(t, !contract.damage_rect_is_empty(expanded))
	testing.expect_value(t, expanded.x, max_val - 70)
	testing.expect_value(t, expanded.y, max_val - 70)
	testing.expect_value(t, expanded.w, 70)
	testing.expect_value(t, expanded.h, 70)
}

@(test)
test_damage_rect_expand_and_clamp :: proc(t: ^testing.T) {
	// Padding 2px on rect {10, 20, 30, 40} produces {8, 18, 34, 44}
	r := contract.damage_rect_make(10, 20, 30, 40)
	expanded := contract.damage_rect_expand(r, 2, 100, 100)
	testing.expect_value(t, expanded.x, 8)
	testing.expect_value(t, expanded.y, 18)
	testing.expect_value(t, expanded.w, 34)
	testing.expect_value(t, expanded.h, 44)

	// Padding at edge {0, 0, 10, 10} clamps x, y to 0
	edge := contract.damage_rect_make(0, 0, 10, 10)
	expanded_edge := contract.damage_rect_expand(edge, 5, 100, 100)
	testing.expect_value(t, expanded_edge.x, 0)
	testing.expect_value(t, expanded_edge.y, 0)
	testing.expect_value(t, expanded_edge.w, 15)
	testing.expect_value(t, expanded_edge.h, 15)

	// Expanding past max_w, max_h clamps to surface bounds
	bound := contract.damage_rect_make(90, 90, 20, 20)
	expanded_bound := contract.damage_rect_expand(bound, 5, 100, 100)
	testing.expect_value(t, expanded_bound.x, 85)
	testing.expect_value(t, expanded_bound.y, 85)
	testing.expect_value(t, expanded_bound.w, 15)
	testing.expect_value(t, expanded_bound.h, 15)

	// Expanding empty rect returns empty
	empty := contract.damage_rect_make(10, 10, 0, 0)
	expanded_empty := contract.damage_rect_expand(empty, 2, 100, 100)
	testing.expect(t, contract.damage_rect_is_empty(expanded_empty))
}

@(test)
test_damage_rect_is_full :: proc(t: ^testing.T) {
	// Rect covering 0, 0, W, H reports true
	r_full := contract.damage_rect_make(0, 0, 800, 600)
	testing.expect(t, contract.damage_rect_is_full(r_full, 800, 600))

	// Rect covering larger than W, H reports true
	r_larger := contract.damage_rect_make(0, 0, 1000, 800)
	testing.expect(t, contract.damage_rect_is_full(r_larger, 800, 600))

	// Rect offset from 0, 0 reports false
	r_offset := contract.damage_rect_make(1, 0, 800, 600)
	testing.expect(t, !contract.damage_rect_is_full(r_offset, 800, 600))

	r_offset_y := contract.damage_rect_make(0, 1, 800, 600)
	testing.expect(t, !contract.damage_rect_is_full(r_offset_y, 800, 600))

	// Rect smaller than W reports false
	r_smaller_w := contract.damage_rect_make(0, 0, 799, 600)
	testing.expect(t, !contract.damage_rect_is_full(r_smaller_w, 800, 600))

	// Rect smaller than H reports false
	r_smaller_h := contract.damage_rect_make(0, 0, 800, 599)
	testing.expect(t, !contract.damage_rect_is_full(r_smaller_h, 800, 600))
}

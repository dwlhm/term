package feature_session_core_tests

// Stitch geometry without a process: page alignment, scrollbar column, pinned
// header, top detection and unaligned pages.

import "core:fmt"
import "core:testing"
import core ".."

@(private = "file")
_num_a: [core.STITCH_MAX_ROWS][24]u8
@(private = "file")
_num_b: [core.STITCH_MAX_ROWS][24]u8

// numbered fills out with "L<from>"… rows that outlive the call.
@(private = "file")
numbered :: proc(out: []string, pool: [][24]u8, from, count: int) -> []string {
	for i in 0..<count {
		out[i] = fmt.bprintf(pool[i][:], "L%03d", from + i)
	}
	return out[:count]
}

// barred is a row with a scrollbar glyph in column 12.
@(private = "file")
barred :: proc(pool: [][24]u8, i: int, n: int, glyph: string) -> string {
	return fmt.bprintf(pool[i][:], "L%03d%-8s%s", n, "", glyph)
}

@(test)
test_stitch_shifted_pages :: proc(t: ^testing.T) {
	a, b: [32]string
	old := numbered(a[:], _num_a[:], 3, 24)
	next := numbered(b[:], _num_b[:], 0, 24) // the view scrolled up three lines
	testing.expect(t, !core.stitch_same(next, old, -1), "a scrolled page is not the same screen")
	d, ok := core.stitch_shift(next, old, -1)
	testing.expect(t, ok && d == 3, "the scroll distance is found")
	from, to := core.stitch_glue_range(next, old, -1, d)
	testing.expect_value(t, from, 0)
	testing.expect_value(t, to, 3)
	testing.expect_value(t, next[from], "L000")
	testing.expect_value(t, next[to - 1], "L002")
}

@(test)
test_stitch_pinned_header :: proc(t: ^testing.T) {
	a: [9]string = {"FIXED", "L010", "L011", "L012", "L013", "L014", "L015", "L016", "L017"}
	b: [9]string = {"FIXED", "L009", "L010", "L011", "L012", "L013", "L014", "L015", "L016"}
	testing.expect(t, !core.stitch_same(b[:], a[:], -1), "content moved under the header")
	d, ok := core.stitch_shift(b[:], a[:], -1)
	testing.expect(t, ok && d == 1, "one line scrolled")
	from, to := core.stitch_glue_range(b[:], a[:], -1, d)
	testing.expect_value(t, from, 1) // the header is chrome, not history
	testing.expect_value(t, to, 2)
	testing.expect_value(t, b[from], "L009")
}

@(test)
test_stitch_scrollbar_column :: proc(t: ^testing.T) {
	a, b: [16]string
	for i in 0..<10 {
		a[i] = barred(_num_a[:], i, 10 + i, "│")
		b[i] = barred(_num_b[:], i, 9 + i, "█" if i == 4 else "│") // the thumb moved
	}
	col := core.stitch_scrollbar_col(a[:10], b[:10])
	testing.expect_value(t, col, 12)
	testing.expect(t, core.stitch_key(a[0], col) != core.stitch_key(b[9], col), "content differs")
	testing.expect_value(t, core.stitch_key(a[1], col), "L011")
	d, ok := core.stitch_shift(b[:10], a[:10], col)
	testing.expect(t, ok && d == 1, "the scroll is found beside a scrollbar")
	from, to := core.stitch_glue_range(b[:10], a[:10], col, d)
	testing.expect_value(t, to - from, 1)
	testing.expect_value(t, core.stitch_key(b[from], col), "L009")
}

@(test)
test_stitch_unaligned_pages :: proc(t: ^testing.T) {
	a: [8]string = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"}
	b: [8]string = {"one", "two", "three", "four", "five", "six", "seven", "eight"}
	testing.expect(t, !core.stitch_same(b[:], a[:], -1), "different content")
	_, ok := core.stitch_shift(b[:], a[:], -1)
	testing.expect(t, !ok, "nothing can be trusted: stop")
}

@(test)
test_stitch_top_and_threshold :: proc(t: ^testing.T) {
	a, b: [16]string
	page := numbered(a[:], _num_a[:], 0, 16)
	same := numbered(b[:], _num_b[:], 0, 16)
	testing.expect(t, core.stitch_same(same, page, -1), "an unchanged page means the view is at the top")
	d, _ := core.stitch_shift(same, page, -1)
	testing.expect_value(t, d, 0)

	// One changed row in sixteen is still the same screen; eight are not.
	mixed := numbered(b[:], _num_b[:], 0, 16)
	mixed[3] = "changed"
	testing.expect(t, core.stitch_same(mixed, page, -1), "one differing row of sixteen")
	for i in 0..<8 do mixed[i] = fmt.bprintf(_num_b[i][:], "other %02d", i)
	testing.expect(t, !core.stitch_same(mixed, page, -1), "half the page differs")
}

@(test)
test_stitch_delta_both_directions :: proc(t: ^testing.T) {
	a, b: [16]string
	start := numbered(a[:], _num_a[:], 10, 12)
	up := numbered(b[:], _num_b[:], 7, 12) // the view scrolled up three lines
	if d, ok := core.stitch_delta(up, start, -1); testing.expect(t, ok, "an upward move is measured") {
		testing.expect_value(t, d, 3)
	}
	if d, ok := core.stitch_delta(start, up, -1); testing.expect(t, ok, "a downward move is measured") {
		testing.expect_value(t, d, -3)
	}
	_, ok := core.stitch_delta(start, start, -1)
	testing.expect(t, !ok, "an unchanged page has no direction")
}

@(test)
test_stitch_short_page_has_no_shift :: proc(t: ^testing.T) {
	a: [4]string = {"x1", "x2", "x3", "x4"}
	b: [4]string = {"y1", "y2", "y3", "y4"}
	_, ok := core.stitch_shift(b[:], a[:], -1)
	testing.expect(t, !ok, "too little evidence for a distance")
}

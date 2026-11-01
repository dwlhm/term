package feature_session_core

// Pure stitch geometry: page rows are trimmed, a right-edge scrollbar column is
// ignored, and an upward scroll is recovered by aligning rows. No IO, no
// Terminal here, so the heuristics unit-test without a process.

import "core:strings"
import "core:unicode/utf8"

STITCH_MAX_ROWS        :: 1024
STITCH_SHIFT_MAX       :: 64 // a wheel notch never moves more than this many lines
STITCH_SCROLLBAR_RUN   :: 3  // this many rows ending in a track/thumb glyph = a scrollbar
STITCH_SAME_PERCENT    :: 70 // the page did not move
STITCH_OVERLAP_PERCENT :: 30 // a scroll distance is only trusted above this
STITCH_MIN_MATCHED     :: 3  // ... and only with this much evidence

// stitch_key is what a comparison looks at: trailing blanks dropped and, when
// the page has a scrollbar, that column dropped too.
stitch_key :: proc(s: string, col: int) -> string {
	res := s
	if col >= 0 {
		off, i := 0, 0
		for off < len(s) {
			_, size := utf8.decode_rune_in_string(s[off:])
			if i == col {
				if off + size == len(s) do res = s[:off]
				break
			}
			off += size
			i += 1
		}
	}
	return strings.trim_right_space(res)
}

@(private = "file")
_is_scrollbar :: proc(r: rune) -> bool {
	// track, thumb, full block and double line: boxes and rules do not stay on
	// the right edge of every row, a scrollbar does.
	return r == '│' || r == '┃' || r == '█' || r == '║' || r == '▐' || r == '▌'
}

// stitch_scrollbar_col finds the right-edge column of a scrollbar: rune index
// `col` where at least STITCH_SCROLLBAR_RUN rows of the given pages end in a
// track/thumb glyph (-1: no scrollbar).
stitch_scrollbar_col :: proc(pages: ..[]string) -> int {
	counts: [STITCH_MAX_ROWS]int
	for rows in pages {
		for row in rows {
			if len(row) == 0 do continue
			r, _ := utf8.decode_last_rune_in_string(row)
			if !_is_scrollbar(r) do continue
			col := utf8.rune_count_in_string(row) - 1
			if col >= 0 && col < STITCH_MAX_ROWS do counts[col] += 1
		}
	}
	best, most := -1, STITCH_SCROLLBAR_RUN - 1
	for n, col in counts {
		if n > most {
			best, most = col, n
		}
	}
	return best
}

// stitch_same: the page did not move (≥ STITCH_SAME_PERCENT of the non-empty
// row pairs are equal). Two blank pages count as the same screen.
stitch_same :: proc(a, b: []string, col: int) -> bool {
	if len(a) != len(b) do return false
	total, matched := 0, 0
	for i in 0..<len(a) {
		ka, kb := stitch_key(a[i], col), stitch_key(b[i], col)
		if len(ka) == 0 && len(kb) == 0 do continue
		total += 1
		if ka == kb do matched += 1
	}
	if total == 0 do return true
	return matched * 100 >= total * STITCH_SAME_PERCENT
}

// stitch_shift recovers how far a page scrolled up: new[i] == old[i - d] for
// the overlapping rows. The distance with the most matching rows wins (ties:
// the smallest), and only if ≥ STITCH_OVERLAP_PERCENT of the overlap and at
// least STITCH_MIN_MATCHED rows agree. 0 = no trusted distance.
stitch_shift :: proc(new, old: []string, col: int) -> (shift: int, ok: bool) {
	best, best_matched := 0, 0
	limit := min(min(len(new), len(old)) - 1, STITCH_SHIFT_MAX)
	for d in 1..=limit {
		matched, overlap := 0, 0
		for i in d..<min(len(new), len(old)) {
			kn, ko := stitch_key(new[i], col), stitch_key(old[i - d], col)
			if len(kn) == 0 && len(ko) == 0 do continue
			overlap += 1
			if kn == ko do matched += 1
		}
		if matched < STITCH_MIN_MATCHED do continue
		if matched * 100 < overlap * STITCH_OVERLAP_PERCENT do continue
		if matched > best_matched {
			best, best_matched = d, matched
		}
	}
	return best, best_matched > 0
}

// stitch_pinned counts the leading rows that stayed in place (a fixed header
// above the scrolling region). They are chrome, not history. It may be taller
// than the scroll distance when the program keeps several header rows.
stitch_pinned :: proc(new, old: []string, col: int) -> int {
	h := 0
	for h < min(len(new), len(old)) - 1 {
		kn, ko := stitch_key(new[h], col), stitch_key(old[h], col)
		if len(kn) == 0 || kn != ko do break
		h += 1
	}
	return h
}

// stitch_glue_range is the slice of the new page that is history: the rows an
// upward scroll revealed above what the previous page showed.
stitch_glue_range :: proc(new, old: []string, col: int, shift: int) -> (from, to: int) {
	from = stitch_pinned(new, old, col)
	return from, min(from + shift, len(new))
}

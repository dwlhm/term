package parser_test

import "core:testing"
import p "../../parser"

// Deterministic LCG so fuzz is reproducible without extra imports.
_fuzz_state: u64 = 0x9E3779B97F4A7C15

_fuzz_reset :: proc() {
	_fuzz_state = 0x9E3779B97F4A7C15
}

_fuzz_next :: proc() -> u64 {
	_fuzz_state = _fuzz_state * 6364136223846793005 + 1442695040888963407
	return _fuzz_state >> 33
}

// Alphabet: printable, ESC, C0, 0x7F, 0x80-0xFF, UTF-8 leads/continuations.
_fuzz_byte :: proc(r: u64) -> u8 {
	switch r % 10 {
	case 0:
		return 0x1B
	case 1:
		return u8(r % 0x20)
	case 2:
		return 0x7F
	case 3:
		return u8(0x80 + (r % 0x80))
	case 4:
		return u8(0xC0 + (r % 0x40))
	case:
		return u8(0x20 + (r % 0x5F))
	}
}

// _runs_equal checks length AND data equality of two runs.
_runs_equal :: proc(a, b: p.ASCII_Run) -> bool {
	if a.length != b.length {
		return false
	}
	if len(a.data) != len(b.data) {
		return false
	}
	for i in 0 ..< a.length {
		if a.data[i] != b.data[i] {
			return false
		}
	}
	return true
}

// _check_all_paths compares the dispatcher and SWAR path against the
// scalar oracle. (Phase 13: SIMD deleted, scalar retained per bench.)
_check_all_paths :: proc(input: []u8) -> bool {
	ref := p.scan_ascii_run_scalar(input)
	if !_runs_equal(p.scan_ascii_run(input), ref) {
		return false
	}
	if !_runs_equal(p.scan_ascii_swar(input), ref) {
		return false
	}
	return true
}

@(test)
test_simd_differential_fuzz :: proc(t: ^testing.T) {
	_fuzz_reset()
	buf := make([]u8, 300)
	defer delete(buf)

	mism := 0
	for length in 0 ..= 300 {
		for sample in 0 ..< 4 {
			for i in 0 ..< length {
				buf[i] = _fuzz_byte(_fuzz_next())
			}
			if !_check_all_paths(buf[:length]) {
				mism += 1
			}
			_ = sample
		}
	}
	testing.expect(t, mism == 0, "all fast paths must match scalar oracle on fuzz")
}

@(test)
test_simd_boundary_sweep :: proc(t: ^testing.T) {
	mism := 0

	// Every value 0..255 as the sole input byte.
	one := [1]u8{0}
	for v in 0 ..= 255 {
		one[0] = u8(v)
		if !_check_all_paths(one[:]) {
			mism += 1
		}
	}

	// Explicit boundary values 0x1F/0x20/0x7E/0x7F embedded in printable runs.
	bounds := [4]u8{0x1F, 0x20, 0x7E, 0x7F}
	for b in bounds {
		buf := [4]u8{'A', 'B', 'C', b}
		if !_check_all_paths(buf[:]) {
			mism += 1
		}
	}

	testing.expect(t, mism == 0, "boundary sweep must match scalar oracle")
}

@(test)
test_simd_value_edges :: proc(t: ^testing.T) {
	lanes := [8]int{0, 7, 8, 15, 16, 31, 32, 63}
	specials := [8]u8{0x00, 0x1B, 0x1F, 0x20, 0x7E, 0x7F, 0x80, 0xC3}
	lengths := [6]int{16, 17, 32, 33, 64, 65}

	mism := 0
	for n in lengths {
		for lane in lanes {
			if lane >= n {
				continue
			}
			for sp in specials {
				work := [65]u8{}
				for i in 0 ..< n {
					work[i] = 'A'
				}
				work[lane] = sp
				if !_check_all_paths(work[:n]) {
					mism += 1
				}
			}
		}
	}
	testing.expect(t, mism == 0, "lane edge values must match scalar oracle")
}

@(test)
test_simd_mece_cases :: proc(t: ^testing.T) {
	mism := 0

	// len == 0
	empty := []u8{}
	if !_check_all_paths(empty) {
		mism += 1
	}

	// 1 <= len < 8 scalar exact (all printable + special at each pos).
	for n in 1 ..< 8 {
		buf := [8]u8{'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'}
		if !_check_all_paths(buf[:n]) {
			mism += 1
		}
		for pos in 0 ..< n {
			work := [8]u8{'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'}
			work[pos] = 0x1B
			if !_check_all_paths(work[:n]) {
				mism += 1
			}
		}
	}

	// 8 <= len < 16 (SIMD build: scalar exact; SWAR: 1 word + tail).
	for n in 8 ..< 16 {
		buf := [16]u8{'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p'}
		if !_check_all_paths(buf[:n]) {
			mism += 1
		}
		for pos in 0 ..< n {
			work := [16]u8{'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p'}
			work[pos] = 0x7F
			if !_check_all_paths(work[:n]) {
				mism += 1
			}
		}
	}

	// special @ 0 and @ 16.
	at0 := []u8{0x1B, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q'}
	if !_check_all_paths(at0) {
		mism += 1
	}
	at16 := make([]u8, 32)
	for i in 0 ..< 32 {
		at16[i] = 'z'
	}
	at16[16] = 0x00
	if !_check_all_paths(at16) {
		mism += 1
	}
	delete(at16)

	// special @ 16k.
	big := make([]u8, 16384)
	for i in 0 ..< 16384 {
		big[i] = 'x'
	}
	if !_check_all_paths(big) {
		mism += 1
	}
	big[16000] = 0x1B
	if !_check_all_paths(big) {
		mism += 1
	}
	delete(big)

	// All-special >= 16 -> 0, no pathology.
	allspecial := make([]u8, 64)
	for i in 0 ..< 64 {
		allspecial[i] = 0x1B
	}
	r := p.scan_ascii_run(allspecial)
	testing.expect(t, r.length == 0, "all-special input must scan 0")
	if !_check_all_paths(allspecial) {
		mism += 1
	}
	delete(allspecial)

	// Unaligned sub-slices: offsets 1..7 with a special inside.
	raw := make([]u8, 128)
	for i in 0 ..< 128 {
		raw[i] = 'q'
	}
	raw[100] = 0xC3
	for off in 1 ..< 8 {
		if !_check_all_paths(raw[off:]) {
			mism += 1
		}
	}
	delete(raw)

	// Long all-printable run.
	printable := make([]u8, 1024)
	for i in 0 ..< 1024 {
		printable[i] = u8(0x20 + (i % 95))
	}
	rp := p.scan_ascii_run(printable)
	testing.expect(t, rp.length == 1024, "all-printable 1k must scan fully")
	if !_check_all_paths(printable) {
		mism += 1
	}
	delete(printable)

	testing.expect(t, mism == 0, "MECE cases must match scalar oracle")
}

@(test)
test_swar_differential :: proc(t: ^testing.T) {
	mism := 0

	// Exhaustive swar_bad_mask: every value in every lane of a word.
	for lane in 0 ..< 8 {
		for v in 0 ..= 255 {
			word := [8]u8{'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A'}
			word[lane] = u8(v)
			w := (cast(^u64)(&word[0]))^
			m := p.swar_bad_mask(w)
			printable := v >= 0x20 && v <= 0x7E
			if printable {
				if m != 0 {
					mism += 1
				}
			} else {
				// Exactly the bad lane's 0x80 bit, nothing else.
				if m != (u64(0x80) << uint(lane * 8)) {
					mism += 1
				}
			}
		}
	}

	// swar path vs scalar: special at every position for lengths 0..64.
	for n in 0 ..= 64 {
		buf := make([]u8, n + 1)
		for i in 0 ..< n + 1 {
			buf[i] = 'B'
		}
		ref := p.scan_ascii_run_scalar(buf[:n])
		if !_runs_equal(p.scan_ascii_swar(buf[:n]), ref) {
			mism += 1
		}
		for pos in 0 ..< n {
			buf[pos] = 0x1B
			ref2 := p.scan_ascii_run_scalar(buf[:n])
			if !_runs_equal(p.scan_ascii_swar(buf[:n]), ref2) {
				mism += 1
			}
			buf[pos] = 'B'
		}
		delete(buf)
	}

	testing.expect(t, mism == 0, "SWAR must match scalar oracle")
}

package parser

import "core:simd"
import "base:intrinsics"

// ASCII fast-path tuning constants.
//
// Phase 13 outcome (ARM64 NEON, -o:speed, min-of-5 MB/s scan throughput):
//   corpus      scalar  simd-best    ratio
//   ascii_1m      1554      29674    19.09
//   csi_spam      1146        280     0.24
//   osc_spam      1347        316     0.23
//   utf8_mix      1169        245     0.21
//   escape_3b     2759       2970     1.08
//   micro geomean(simd_best/scalar) = 0.75 (keep threshold 1.15: FAIL)
//   worst corpus best/scalar = 0.21 (regress threshold 0.95: FAIL)
// Decision: scalar retained. The 16-byte block cost loses to scalar whenever
// runs are short (an escape every few bytes), which dominates real terminal
// traffic. The SIMD block scanner was deleted; ASCII_USE_SIMD stays false
// as the documented switch.
ASCII_SWAR_BLOCK   :: 8     // u64 SWAR bytes per word
ASCII_USE_SIMD     :: false // master switch; SIMD removed per Phase 13 bench

// SWAR broadcast constants.
SWAR_LO_E0 :: 0xE0E0E0E0E0E0E0E0
SWAR_LO_7F :: 0x7F7F7F7F7F7F7F7F
SWAR_SUB   :: 0x0101010101010101
SWAR_HI    :: 0x8080808080808080

// ASCII_Run represents a run of printable ASCII bytes.
ASCII_Run :: struct {
	data:   []u8, // slice of printable ASCII bytes
	length: int,  // number of bytes in run
}

// scan_ascii_run scans for a run of printable ASCII bytes (0x20-0x7E).
// Returns the run and the number of bytes consumed.
// Stops at first non-printable byte (ESC, C0 control, UTF-8 lead, etc.).
// Dispatcher: scalar on hardware-SIMD builds (SIMD removed, see above),
// SWAR word scan on non-SIMD builds, scalar for short inputs.
scan_ascii_run :: proc(input: []u8) -> ASCII_Run {
	if len(input) == 0 {
		return ASCII_Run{data = input[:0], length = 0}
	}
	when simd.HAS_HARDWARE_SIMD {
		return scan_ascii_run_scalar(input)
	} else {
		if len(input) >= ASCII_SWAR_BLOCK {
			return scan_ascii_swar(input)
		}
		return scan_ascii_run_scalar(input)
	}
}

// scan_ascii_run_scalar is the scalar reference oracle: byte-at-a-time scan.
scan_ascii_run_scalar :: proc(input: []u8) -> ASCII_Run {
	if len(input) == 0 {
		return ASCII_Run{data = input[:0], length = 0}
	}

	// Find the length of the printable ASCII run
	i := 0
	for i < len(input) {
		if !is_printable_ascii(input[i]) {
			break
		}
		i += 1
	}

	return ASCII_Run{data = input[:i], length = i}
}

// swar_bad_mask returns 0 iff all 8 bytes of w are printable ASCII,
// else the 0x80 bit of each bad lane.
swar_bad_mask :: proc(w: u64) -> u64 {
	lo := w & SWAR_LO_E0
	lo_bad := ((lo - SWAR_SUB) & ~lo) & SWAR_HI
	eq := w ~ SWAR_LO_7F
	eq_bad := ((eq - SWAR_SUB) & ~eq) & SWAR_HI
	hi_bad := w & SWAR_HI
	return lo_bad | eq_bad | hi_bad
}

// scan_ascii_swar scans 8 bytes per iteration with a scalar tail.
// Used on non-SIMD builds; reference-tested against the scalar oracle.
scan_ascii_swar :: proc(input: []u8) -> ASCII_Run {
	pos := 0
	for pos + ASCII_SWAR_BLOCK <= len(input) {
		w := (cast(^u64)(&input[pos]))^
		m := swar_bad_mask(w)
		if m != 0 {
			end := pos + int(intrinsics.count_trailing_zeros(m) / 8)
			return ASCII_Run{data = input[:end], length = end}
		}
		pos += ASCII_SWAR_BLOCK
	}
	for pos < len(input) {
		if !is_printable_ascii(input[pos]) {
			break
		}
		pos += 1
	}
	return ASCII_Run{data = input[:pos], length = pos}
}

// is_printable_ascii returns true if byte is printable ASCII (0x20-0x7E).
is_printable_ascii :: proc(b: u8) -> bool {
	return b >= 0x20 && b <= 0x7E
}

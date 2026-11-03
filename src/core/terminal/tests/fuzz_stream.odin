package terminal_tests

import "core:strings"

// Seeded VT byte streams shared by the property tests: printable runs mixed
// with pieces chosen to cut wide pairs, wrap, scroll inside regions, erase with
// a coloured background and toggle modes.

Fuzz_Rng :: struct {
	s: u64,
}

fuzz_next :: proc(r: ^Fuzz_Rng, n: int) -> int {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return int(r.s % u64(n))
}

@(private = "file")
PIECES := [?]string{
	"\r", "\n", "\r\n", "\b", "\t", "日本", "😀", "é", "\x1b[0m", "\x1b[1;31m", "\x1b[38;2;10;20;30m",
	"\x1b[48;5;200m", "\x1b[4:3m\x1b[58;2;1;2;3m", "\x1b]8;;http://x\x1b\\", "\x1b]8;;\x1b\\", "\x1b[?7l",
	"\x1b[?7h", "\x1b[2;5r", "\x1b[r", "\x1b[3;7H", "\x1b[1;1H", "\x1b[K", "\x1b[2J", "\x1b[?1049h",
	"\x1b[?1049l", "\x1b(0", "\x1b(B", "\x1b[3b", "\x1b[2@", "\x1b[2P", "\x1bM", "\x1b[1;20H",
	"\x1b[1K", "\x1b[2K", "\x1b[J", "\x1b[1J", "\x1b[3X", "\x1b[2S", "\x1b[2T", "\x1b[2L", "\x1b[2M",
	"\x1b[48;2;9;9;9m\x1b[K", "\x1b[44m\x1b[2J", "\x1b[45m\n\n", "\x1b[49m",
}

fuzz_stream :: proc(seed: u64) -> []u8 {
	rng := Fuzz_Rng{seed | 1}
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < 6000 {
		if fuzz_next(&rng, 3) == 0 {
			strings.write_string(&b, PIECES[fuzz_next(&rng, len(PIECES))])
			continue
		}
		for _ in 0 ..< 1 + fuzz_next(&rng, 45) do strings.write_byte(&b, u8(0x20 + fuzz_next(&rng, 95)))
	}
	return b.buf[:]
}

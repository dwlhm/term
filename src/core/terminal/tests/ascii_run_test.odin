package terminal_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import term "../"
import damage "../damage"
import grid "../grid"
import parser "../parser"

// The batched ASCII run path (terminal_feed_bytes) must leave exactly the state
// the per-byte path (parser_parse_byte) leaves: cells, colours, line flags,
// history, cursor and the damaged bounds.

@(private = "file")
Rng :: struct {
	s: u64,
}

@(private = "file")
_next :: proc(r: ^Rng, n: int) -> int {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return int(r.s % u64(n))
}

// Pieces chosen to cut wide pairs, wrap, scroll inside regions and toggle modes.
@(private = "file")
PIECES := [?]string{
	"\r", "\n", "\r\n", "\b", "\t", "日本", "😀", "é", "\x1b[0m", "\x1b[1;31m", "\x1b[38;2;10;20;30m",
	"\x1b[48;5;200m", "\x1b[4:3m\x1b[58;2;1;2;3m", "\x1b]8;;http://x\x1b\\", "\x1b]8;;\x1b\\", "\x1b[?7l",
	"\x1b[?7h", "\x1b[2;5r", "\x1b[r", "\x1b[3;7H", "\x1b[1;1H", "\x1b[K", "\x1b[2J", "\x1b[?1049h",
	"\x1b[?1049l", "\x1b(0", "\x1b(B", "\x1b[3b", "\x1b[2@", "\x1b[2P", "\x1bM", "\x1b[1;20H",
}

@(private = "file")
_stream :: proc(seed: u64) -> []u8 {
	rng := Rng{seed | 1}
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < 6000 {
		if _next(&rng, 3) == 0 {
			strings.write_string(&b, PIECES[_next(&rng, len(PIECES))])
			continue
		}
		for _ in 0 ..< 1 + _next(&rng, 45) do strings.write_byte(&b, u8(0x20 + _next(&rng, 95)))
	}
	return b.buf[:]
}

@(private = "file")
_expect_same :: proc(t: ^testing.T, a, b: ^term.Terminal, seed: u64) -> bool {
	where_ := fmt.tprintf("seed %d", seed)
	if a.parser.cursor.row != b.parser.cursor.row || a.parser.cursor.col != b.parser.cursor.col ||
	   a.parser.cursor.pending_wrap != b.parser.cursor.pending_wrap || a.parser.last_print != b.parser.last_print {
		testing.expectf(t, false, "%s: cursor %v/%v", where_, a.parser.cursor, b.parser.cursor)
		return false
	}
	if a.grid.history_count != b.grid.history_count {
		testing.expectf(t, false, "%s: history %d vs %d", where_, a.grid.history_count, b.grid.history_count)
		return false
	}
	for r in -a.grid.history_count ..< a.grid.row_count {
		ra, rb := grid.grid_get_row(&a.grid, r), grid.grid_get_row(&b.grid, r)
		if ra.wrap != rb.wrap || ra.is_prompt != rb.is_prompt {
			testing.expectf(t, false, "%s: row %d flags differ", where_, r)
			return false
		}
		for c in 0 ..< a.grid.col_count {
			if ra.cells[c] != rb.cells[c] || ra.direct_colors[c] != rb.direct_colors[c] {
				testing.expectf(t, false, "%s: cell (%d,%d) %v %v vs %v %v", where_, r, c, ra.cells[c], ra.direct_colors[c], rb.cells[c], rb.direct_colors[c])
				return false
			}
		}
	}
	ja, jb := damage.damage_consume(&a.damage), damage.damage_consume(&b.damage)
	if ja.has_damage != jb.has_damage || ja.full_damage != jb.full_damage ||
	   (ja.has_damage && (ja.min_row != jb.min_row || ja.max_row != jb.max_row || ja.min_col != jb.min_col || ja.max_col != jb.max_col)) {
		testing.expectf(t, false, "%s: damage %v vs %v", where_, ja, jb)
		return false
	}
	return true
}

@test
test_ascii_runs_match_per_byte_path :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 300 {
		data := _stream(seed * 0x9E3779B97F4A7C15)
		batched, per_byte := new(term.Terminal), new(term.Terminal)
		term.terminal_init(batched, 8, 20)
		term.terminal_init(per_byte, 8, 20)

		rng := Rng{seed}
		for off := 0; off < len(data); {
			n := min(len(data) - off, 1 + _next(&rng, 700))
			term.terminal_feed_bytes(batched, data[off:][:n])
			off += n
		}
		for b in data do parser.parser_parse_byte(&per_byte.parser, &per_byte.grid, &per_byte.damage, b)

		ok := _expect_same(t, batched, per_byte, seed)
		term.terminal_destroy(batched)
		term.terminal_destroy(per_byte)
		free(batched)
		free(per_byte)
		if !ok do return
	}
}

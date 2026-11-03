package terminal_tests

import "core:fmt"
import "core:testing"
import term "../"
import damage "../damage"
import grid "../grid"
import parser "../parser"

// The batched ASCII run path (terminal_feed_bytes) must leave exactly the state
// the per-byte path (parser_parse_byte) leaves: cells, colours, line flags,
// history, cursor and the damaged bounds.

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
		data := fuzz_stream(seed * 0x9E3779B97F4A7C15)
		batched, per_byte := new(term.Terminal), new(term.Terminal)
		term.terminal_init(batched, 8, 20)
		term.terminal_init(per_byte, 8, 20)

		rng := Fuzz_Rng{seed}
		for off := 0; off < len(data); {
			n := min(len(data) - off, 1 + fuzz_next(&rng, 700))
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

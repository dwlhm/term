package terminal_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import term "../"
import cell "../cell"
import grid "../grid"

// Row.occ contract: every cell at [occ:] is blank (CELL_DEFAULT, no colour),
// in every physical row of both screens, after any feed or resize. Blank
// resets clear only [0, occ), so this is what keeps them equal to full clears.

@(private = "file")
_occ_holds :: proc(t: ^testing.T, g: ^grid.Grid, where_: string) -> bool {
	blank := make([]cell.Semantic_Cell, g.col_count, context.temp_allocator)
	slice.fill(blank, cell.CELL_DEFAULT)
	for &r, phys in g.rows {
		tail_cells, tail_colors := r.cells[r.occ:], r.direct_colors[r.occ:]
		if !slice.equal(tail_cells, blank[:len(tail_cells)]) || !mem.check_zero(slice.to_bytes(tail_colors)) {
			testing.expectf(t, false, "%s: phys row %d has content past occ %d", where_, phys, r.occ)
			return false
		}
	}
	return true
}

@test
test_row_occ_bounds_written_cells :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 100 {
		data := fuzz_stream(seed * 0xD1B54A32D192ED03)
		tm := new(term.Terminal)
		term.terminal_init(tm, 8, 20)
		rng := Fuzz_Rng{seed}
		ok := true
		for off := 0; ok && off < len(data); {
			n := min(len(data) - off, 1 + fuzz_next(&rng, 300))
			term.terminal_feed_bytes(tm, data[off:][:n])
			off += n
			if fuzz_next(&rng, 8) == 0 do term.terminal_resize(tm, 5 + fuzz_next(&rng, 6), 12 + fuzz_next(&rng, 14))
			where_ := fmt.tprintf("seed %d at %d", seed, off)
			ok = _occ_holds(t, &tm.grid, where_) && _occ_holds(t, &tm.alt_grid, where_)
		}
		term.terminal_destroy(tm)
		free(tm)
		free_all(context.temp_allocator)
		if !ok do return
	}
}

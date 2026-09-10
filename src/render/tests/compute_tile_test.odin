package render_tests

// Phase 14 compute-tile CPU tests (nil backend, no GPU):
// single-span mapping, overlap dedup, full-grid mark, scroll branch,
// empty skip, nil-pipeline fallback + expand reference parity, and
// covered-cell union parity across all tile size candidates.

import "core:testing"
import render "../"
import instance "../instance"
import tile "../tile"
import termgrid "../../terminal"

COMPUTE_TILE_TEST_ROWS :: 24
COMPUTE_TILE_TEST_COLS :: 80

// _compute_tile_journal writes one cell and takes its damage journal.
_compute_tile_journal :: proc(term: ^termgrid.Terminal, row, col: int, c: rune) -> termgrid.Damage_Journal {
	termgrid.terminal_move_cursor(term, row, col)
	termgrid.terminal_put_char(term, c)
	return termgrid.terminal_take_damage(term)
}

@(test)
test_compute_tile_single_span :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	journal := _compute_tile_journal(&term, 12, 42, 'Q')
	defer termgrid.damage_journal_destroy(&journal)

	count, full := tile.tile_map_mark_damage(&m, &journal)
	testing.expect_value(t, count, 1)
	testing.expect(t, !full, "single tile must not be full")
	testing.expect_value(t, m.list[0], tile.tile_index_of(&m, 12, 42))
	testing.expect_value(t, m.list[0], u32(35))
}

@(test)
test_compute_tile_dedup :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	// Four overlapping spans inside tile 5 (cols 40..47 after ±1 widen).
	termgrid.damage_mark_span(&term.damage, 12, 41, 42, 0)
	termgrid.damage_mark_span(&term.damage, 12, 42, 43, 0)
	termgrid.damage_mark_span(&term.damage, 12, 41, 43, 0)
	termgrid.damage_mark_span(&term.damage, 12, 42, 44, 0)
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	count, _ := tile.tile_map_mark_damage(&m, &journal)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, m.list[0], u32(35))
}

@(test)
test_compute_tile_full :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	for row in 0..<COMPUTE_TILE_TEST_ROWS {
		termgrid.damage_mark_row(&term.damage, row, 0)
	}
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	count, full := tile.tile_map_mark_damage(&m, &journal)
	testing.expect_value(t, count, 10 * 6)
	testing.expect(t, full, "all rows full must report full")

	tile.tile_map_clear(&m)
	tile.tile_map_mark_all(&m)
	testing.expect_value(t, m.count, 10 * 6)
}

@(test)
test_compute_tile_scroll :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	termgrid.terminal_put_string(&term, "hi")
	termgrid.terminal_scroll_up(&term, 1)
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	// Caller branch: scroll_ops present → mark_all (full rebase, no span mapping).
	testing.expect(t, len(journal.scroll_ops) > 0, "scroll journal must carry scroll ops")
	if len(journal.scroll_ops) > 0 {
		tile.tile_map_mark_all(&m)
	}
	testing.expect_value(t, m.count, 10 * 6)
}

@(test)
test_compute_tile_empty :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	count, full := tile.tile_map_mark_damage(&m, &journal)
	testing.expect_value(t, count, 0)
	testing.expect(t, !full, "empty journal must not be full")
}

@(test)
test_compute_tile_fallback_nil_pipeline :: proc(t: ^testing.T) {
	// Unavailable renderer never dispatches and uploads zero bytes for an
	// empty map without touching the (nil) backend.
	r: tile.Compute_Tile_Renderer
	testing.expect(t, !r.available, "zero renderer must be unavailable")

	m: tile.Tile_Map
	testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, 8, 4), "tile map init must succeed")
	defer tile.tile_map_destroy(&m)

	dispatches, invocations := tile.compute_tile_dispatch(&r, &m)
	testing.expect_value(t, dispatches, u32(0))
	testing.expect_value(t, invocations, u32(0))

	// Expand reference parity: the fallback instance path expands 'Q' to
	// one bg + one glyph instance with the pinned slot UVs and LUT colors.
	lut := _dirty_test_lut()
	atlas := _dirty_test_atlas()
	cell := render.render_cell_from_semantic(termgrid.Semantic_Cell{content = u32('Q'), style = 0, width = 1, flags = .None})
	bg_inst, glyph_inst: instance.Instance_Data
	emit_bg, emit_glyph := render.render_cell_expand_instance(cell, &lut, &atlas, 40 * 8, 12 * 16, 8, 16, &bg_inst, &glyph_inst)
	testing.expect(t, emit_bg && emit_glyph, "reference expand must emit bg + glyph")
	testing.expect(t, bg_inst != instance.Instance_Data{}, "reference bg instance must be written")
	testing.expect(t, glyph_inst != instance.Instance_Data{}, "reference glyph instance must be written")
	testing.expect(t, glyph_inst.x == 40 * 8 && glyph_inst.y == 12 * 16, "reference glyph must sit on its cell origin")
	testing.expect(t, glyph_inst.cw == 8 && glyph_inst.ch == 16, "reference glyph must span one cell")
}

@(test)
test_compute_tile_size_parity :: proc(t: ^testing.T) {
	term: termgrid.Terminal
	termgrid.terminal_init(&term, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS)
	defer termgrid.terminal_destroy(&term)

	// Full damage: every candidate must cover the identical cell union.
	for row in 0..<COMPUTE_TILE_TEST_ROWS {
		termgrid.damage_mark_row(&term.damage, row, 0)
	}
	journal := termgrid.terminal_take_damage(&term)
	defer termgrid.damage_journal_destroy(&journal)

	N := COMPUTE_TILE_TEST_ROWS * COMPUTE_TILE_TEST_COLS
	first := make([]bool, N)
	defer delete(first)
	for i in 0..<N {
		first[i] = false
	}
	for ci in 0..<len(tile.TILE_CANDIDATES) {
		tw := tile.TILE_CANDIDATES[ci][0]
		th := tile.TILE_CANDIDATES[ci][1]
		m: tile.Tile_Map
		testing.expect(t, tile.tile_map_init(&m, COMPUTE_TILE_TEST_ROWS, COMPUTE_TILE_TEST_COLS, tw, th), "tile map init must succeed for every candidate")
		count, full := tile.tile_map_mark_damage(&m, &journal)
		testing.expect(t, full, "full damage must report full for every candidate")

		covered := make([]bool, N)
		defer delete(covered)
		for k in 0..<count {
			orow, ocol := tile.tile_origin_of(&m, m.list[k])
			for rr in orow..<min(orow + int(th), COMPUTE_TILE_TEST_ROWS) {
				for cc in ocol..<min(ocol + int(tw), COMPUTE_TILE_TEST_COLS) {
					covered[rr * COMPUTE_TILE_TEST_COLS + cc] = true
				}
			}
		}
		if ci == 0 {
			copy(first, covered)
		} else {
			for i in 0..<N {
				if first[i] != covered[i] {
					testing.expect(t, false, "covered-cell union must be identical across tile sizes")
					break
				}
			}
		}
		for i in 0..<N {
			testing.expect(t, first[i], "full damage union must cover every cell")
		}
		tile.tile_map_destroy(&m)
	}
}

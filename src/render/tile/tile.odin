package tile

// Phase 14 tile map: damage journal → deduplicated dirty tile list.
//
// A tile is a tile_w × tile_h block of cells. Each frame the renderer's
// damage journal is mapped to the set of dirty tiles (deduplicated via a
// bitset, compacted into a dense u32 list for GPU upload). The map is
// Renderer-owned, reused across frames, cleared per frame, never allocated
// per frame.
//
// Data flow:
//   Damage_Journal -> Tile_Map -> Tile_List_Buffer -> Compute_Dispatch

import "base:runtime"
import termgrid "../../terminal"

// TILE_W_DEFAULT is the default tile width in cells.
TILE_W_DEFAULT :: 8

// TILE_H_DEFAULT is the default tile height in cells.
TILE_H_DEFAULT :: 4

// TILE_MAX_TILES caps the tile grid; over-cap geometry refuses init/resize
// and the caller falls back to the instance path.
TILE_MAX_TILES :: 4096

// TILE_CANDIDATES is the benchmark sweep set: {w, h} cell extents.
TILE_CANDIDATES: [5][2]u32 = {{4, 2}, {8, 4}, {8, 8}, {16, 4}, {16, 8}}

// Tile_Map maps grid damage to a deduplicated dirty tile list.
// tiles_x = ceil(cols / tile_w), tiles_y = ceil(rows / tile_h).
// Tile index t covers cells rows [t / tiles_x * tile_h, +tile_h) ×
// cols [t % tiles_x * tile_w, +tile_w), clamped to the grid.
Tile_Map :: struct {
	tile_w:  u32,
	tile_h:  u32,
	tiles_x: u32,
	tiles_y: u32,
	rows:    i32,
	cols:    i32,
	bits:    []u64,
	list:    []u32,
	count:   int,
}

// _tile_grid_extent returns the tile grid dimensions for a cell grid.
_tile_grid_extent :: proc(cols, rows: i32, tile_w, tile_h: u32) -> (tiles_x, tiles_y: u32) {
	tiles_x = (u32(cols) + tile_w - 1) / tile_w
	tiles_y = (u32(rows) + tile_h - 1) / tile_h
	return
}

// tile_map_init allocates the bitset + list for the tile grid.
// Returns false when geometry is degenerate or exceeds TILE_MAX_TILES;
// the caller falls back to the instance path.
tile_map_init :: proc(m: ^Tile_Map, rows: i32, cols: i32, tile_w: u32, tile_h: u32, allocator: runtime.Allocator = context.allocator) -> bool {
	if rows <= 0 || cols <= 0 || tile_w == 0 || tile_h == 0 {
		return false
	}
	tiles_x, tiles_y := _tile_grid_extent(cols, rows, tile_w, tile_h)
	if tiles_x == 0 || tiles_y == 0 {
		return false
	}
	if u64(tiles_x) * u64(tiles_y) > TILE_MAX_TILES {
		return false
	}
	total := int(tiles_x) * int(tiles_y)
	m.tile_w = tile_w
	m.tile_h = tile_h
	m.tiles_x = tiles_x
	m.tiles_y = tiles_y
	m.rows = rows
	m.cols = cols
	m.bits = make([]u64, (total + 63) / 64, allocator)
	m.list = make([]u32, total, allocator)
	m.count = 0
	return true
}

// tile_map_destroy frees the bitset + list and resets geometry.
tile_map_destroy :: proc(m: ^Tile_Map, allocator: runtime.Allocator = context.allocator) {
	if m.bits != nil {
		delete(m.bits, allocator)
		m.bits = nil
	}
	if m.list != nil {
		delete(m.list, allocator)
		m.list = nil
	}
	m.count = 0
	m.tiles_x = 0
	m.tiles_y = 0
	m.rows = 0
	m.cols = 0
}

// tile_map_resize rebuilds the map for new geometry. When the existing
// allocations already fit, they are reused in place (no alloc); otherwise
// the map is rebuilt, preserving the old map when the new geometry is
// invalid or over-cap.
tile_map_resize :: proc(m: ^Tile_Map, rows: i32, cols: i32, tile_w: u32, tile_h: u32, allocator: runtime.Allocator = context.allocator) -> bool {
	if rows <= 0 || cols <= 0 || tile_w == 0 || tile_h == 0 {
		return false
	}
	tiles_x, tiles_y := _tile_grid_extent(cols, rows, tile_w, tile_h)
	if tiles_x == 0 || tiles_y == 0 {
		return false
	}
	if u64(tiles_x) * u64(tiles_y) > TILE_MAX_TILES {
		return false
	}
	total := int(tiles_x) * int(tiles_y)
	if m.bits != nil && m.list != nil && total <= len(m.list) && (total + 63) / 64 <= len(m.bits) {
		m.tile_w = tile_w
		m.tile_h = tile_h
		m.tiles_x = tiles_x
		m.tiles_y = tiles_y
		m.rows = rows
		m.cols = cols
		tile_map_clear(m)
		return true
	}
	tmp: Tile_Map
	if !tile_map_init(&tmp, rows, cols, tile_w, tile_h, allocator) {
		return false
	}
	tile_map_destroy(m, allocator)
	m^ = tmp
	return true
}

// tile_map_clear empties the dirty set, reusing both allocations.
tile_map_clear :: proc(m: ^Tile_Map) {
	if m.bits != nil {
		for i in 0..<len(m.bits) {
			m.bits[i] = 0
		}
	}
	m.count = 0
}

// _tile_map_add sets a tile bit, appending to the list on first sight.
// Out-of-range tiles are clamped; the map never panics.
_tile_map_add :: proc(m: ^Tile_Map, tile: u32) {
	total := u64(m.tiles_x) * u64(m.tiles_y)
	if total == 0 || m.bits == nil || m.list == nil {
		return
	}
	t := u64(tile)
	if t >= total {
		t = total - 1
	}
	word := t / 64
	bit := t % 64
	if word >= u64(len(m.bits)) {
		return
	}
	if m.bits[word] & (u64(1) << bit) != 0 {
		return
	}
	m.bits[word] |= u64(1) << bit
	if m.count < len(m.list) {
		m.list[m.count] = u32(t)
		m.count += 1
	}
}

// _tile_map_mark_cell_range marks every tile overlapping the cell rectangle
// [row, row+row_count) × [col_start, col_end), clamped to the grid.
_tile_map_mark_cell_range :: proc(m: ^Tile_Map, row: int, col_start: int, col_end: int) {
	if m.tiles_x == 0 || m.tiles_y == 0 {
		return
	}
	if row < 0 || row >= int(m.rows) {
		return
	}
	cs := col_start
	ce := col_end
	if cs < 0 {
		cs = 0
	}
	if ce > int(m.cols) {
		ce = int(m.cols)
	}
	if cs >= ce {
		return
	}
	tw := int(m.tile_w)
	th := int(m.tile_h)
	tx0 := cs / tw
	tx1 := (ce - 1) / tw
	ty := row / th
	for tx in tx0..=tx1 {
		_tile_map_add(m, u32(ty) * m.tiles_x + u32(tx))
	}
}

// tile_map_mark_damage maps a damage journal to dirty tiles.
// Spans are widened ±1 column (parity with dirty_upload_frame) so lead /
// continuation pairs stay inside the run; tiles dedupe via the bitset.
// The caller checks scroll_ops first and calls tile_map_mark_all instead.
// Out-of-range rows and columns clamp, never panic.
// full is true when every tile in the grid is dirty.
tile_map_mark_damage :: proc(m: ^Tile_Map, journal: ^termgrid.Damage_Journal) -> (count: int, full: bool) {
	if m.bits == nil || m.list == nil || m.tiles_x == 0 || m.tiles_y == 0 {
		return 0, false
	}
	cols := int(m.cols)
	for row_idx in 0..<len(journal.dirty_rows) {
		if row_idx >= int(m.rows) {
			break
		}
		dr := &journal.dirty_rows[row_idx]
		if !dr.full && dr.span_count == 0 {
			continue
		}
		if dr.full {
			_tile_map_mark_cell_range(m, row_idx, 0, cols)
			continue
		}
		for s in 0..<int(dr.span_count) {
			if s >= len(dr.spans) {
				break
			}
			sp := dr.spans[s]
			cs := int(sp.col_start) - 1
			ce := int(sp.col_end) + 1
			if cs < 0 {
				cs = 0
			}
			if ce > cols {
				ce = cols
			}
			if cs >= ce {
				continue
			}
			_tile_map_mark_cell_range(m, row_idx, cs, ce)
		}
	}
	total := int(m.tiles_x) * int(m.tiles_y)
	return m.count, m.count == total
}

// tile_map_mark_all dirties every tile (scroll rebase, resize, strategy switch).
tile_map_mark_all :: proc(m: ^Tile_Map) {
	if m.bits == nil || m.list == nil || m.tiles_x == 0 || m.tiles_y == 0 {
		return
	}
	total := int(m.tiles_x) * int(m.tiles_y)
	if total > len(m.list) {
		total = len(m.list)
	}
	for i in 0..<len(m.bits) {
		m.bits[i] = max(u64)
	}
	// Mask off padding bits past total in the last word.
	excess := len(m.bits) * 64 - int(m.tiles_x) * int(m.tiles_y)
	if excess > 0 && len(m.bits) > 0 {
		m.bits[len(m.bits) - 1] >>= u64(excess)
	}
	for t in 0..<total {
		m.list[t] = u32(t)
	}
	m.count = total
}

// tile_index_of returns the tile containing cell (row, col), clamped to the grid.
tile_index_of :: proc(m: ^Tile_Map, row: int, col: int) -> u32 {
	if m.tiles_x == 0 || m.tiles_y == 0 {
		return 0
	}
	r := row
	c := col
	if r < 0 {
		r = 0
	}
	if c < 0 {
		c = 0
	}
	if r >= int(m.rows) {
		r = int(m.rows) - 1
	}
	if c >= int(m.cols) {
		c = int(m.cols) - 1
	}
	if r < 0 || c < 0 {
		return 0
	}
	return u32(r / int(m.tile_h)) * m.tiles_x + u32(c / int(m.tile_w))
}

// tile_origin_of returns the top-left cell (row, col) of a tile, clamped to the grid.
tile_origin_of :: proc(m: ^Tile_Map, tile: u32) -> (row: int, col: int) {
	if m.tiles_x == 0 || m.tiles_y == 0 {
		return 0, 0
	}
	total := m.tiles_x * m.tiles_y
	t := tile
	if t >= total {
		t = total - 1
	}
	row = int(t / m.tiles_x) * int(m.tile_h)
	col = int(t % m.tiles_x) * int(m.tile_w)
	if row >= int(m.rows) {
		row = int(m.rows) - 1
	}
	if col >= int(m.cols) {
		col = int(m.cols) - 1
	}
	if row < 0 {
		row = 0
	}
	if col < 0 {
		col = 0
	}
	return
}

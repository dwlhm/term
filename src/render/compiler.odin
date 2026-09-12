package render

// Render compiler: converts damage journals from the terminal into packed render cells.
// Only processes dirty ranges, skipping unchanged cells for efficiency.
//
// Data flow:
//   Terminal grid + Damage journal → [Render_Cell] packed array
//
// The compiler reads cells from the terminal grid, converts their semantic
// representation (codepoint + style_id) into packed render cells (codepoint +
// R5G6B5 fg/bg + flags), and writes them into a flat output array.

import "base:runtime"

import termgrid "../terminal"

// Compiled_Frame holds the output of the render compiler.
Compiled_Frame :: struct {
	cells:      []Render_Cell,  // packed render cells, row-major order
	rows:       i32,
	cols:       i32,
	cell_count: i32,            // number of valid cells in the array
}

// render_compiler_init initializes a compiled frame with the given dimensions.
render_compiler_init :: proc(f: ^Compiled_Frame, rows, cols: i32, allocator: runtime.Allocator = context.allocator) {
	f.rows = rows
	f.cols = cols
	total := int(rows) * int(cols)
	f.cells = make([]Render_Cell, total, allocator)
	f.cell_count = 0

	// Initialize all cells to empty
	empty := render_cell_empty()
	for i in 0..<total {
		f.cells[i] = empty
	}
}

// render_compiler_destroy frees the compiled frame.
render_compiler_destroy :: proc(f: ^Compiled_Frame, allocator: runtime.Allocator = context.allocator) {
	if f.cells != nil {
		delete(f.cells)
		f.cells = nil
	}
	f.cell_count = 0
}

// render_compile compiles a terminal grid into packed render cells,
// processing only the dirty ranges specified by the damage journal.
render_compile :: proc(
	f: ^Compiled_Frame,
	terminal: ^termgrid.Terminal,
	journal: ^termgrid.Damage_Journal,
	style_table: ^termgrid.Style_Table,
) {
	rows := int(f.rows)
	cols := int(f.cols)

	// Process each dirty row
	for row_idx in 0..<rows {
		if row_idx >= len(journal.dirty_rows) {
			break
		}

		dr := &journal.dirty_rows[row_idx]

		// Skip rows that are not dirty
		if !dr.full && dr.span_count == 0 {
			continue
		}

		// Compile the dirty spans in this row
		if dr.full {
			// Entire row is dirty: compile all columns
			_compile_row_range(f, terminal, style_table, row_idx, 0, cols)
		} else {
			// Compile only the dirty spans
			for span_idx in 0..<int(dr.span_count) {
				span := &dr.spans[span_idx]
				col_start := int(span.col_start)
				col_end   := int(span.col_end)
				_compile_row_range(f, terminal, style_table, row_idx, col_start, col_end)
			}
		}
	}
}

// _compile_row_range compiles a range of cells in a single row.
_compile_row_range :: proc(
	f: ^Compiled_Frame,
	terminal: ^termgrid.Terminal,
	style_table: ^termgrid.Style_Table,
	row: int,
	col_start: int,
	col_end: int,
) {
	cols := int(f.cols)
	cs := col_start
	ce := col_end
	if cs < 0 { cs = 0 }
	if ce > cols { ce = cols }

	for col in cs..<ce {
		cell := termgrid.grid_get_cell(&terminal.grid, row, col)
		style := termgrid.style_table_get(style_table, cell.style)

		// Convert ARGB colors to R5G6B5
		fg_packed := color_to_r5g6b5(style.fg)
		bg_packed := color_to_r5g6b5(style.bg)

		// Build flags
		flags := Render_Cell_Flags(cell.width)

		// Pack into render cell
		rc := render_cell_pack(cell.content, fg_packed, bg_packed, flags)

		// Write to output array (row-major order)
		idx := row * cols + col
		if idx < len(f.cells) {
			f.cells[idx] = rc
		}
	}
}

// render_compile_full compiles the entire grid (ignoring damage).
// Useful for the initial frame or when damage tracking is not available.
render_compile_full :: proc(
	f: ^Compiled_Frame,
	terminal: ^termgrid.Terminal,
	style_table: ^termgrid.Style_Table,
) {
	rows := int(f.rows)
	cols := int(f.cols)

	for row in 0..<rows {
		_compile_row_range(f, terminal, style_table, row, 0, cols)
	}
	f.cell_count = i32(rows * cols)
}

// ============================================================================
// V2 compiler: grid → packed Render_Cell_V2 cells with NO style table access.
// The absence of a style_table parameter is the chain-break proof: per-cell
// style_table_get + color conversion no longer happen in compile.
// ============================================================================

// Compiled_Frame_V2 holds V2 packed render cells, row-major order.
Compiled_Frame_V2 :: struct {
	cells:      []Render_Cell_V2,
	rows:       i32,
	cols:       i32,
	cell_count: i32,
}

// render_compiler_init_v2 initializes a V2 compiled frame with the given dimensions.
render_compiler_init_v2 :: proc(f: ^Compiled_Frame_V2, rows: i32, cols: i32, allocator: runtime.Allocator = context.allocator) {
	f.rows = rows
	f.cols = cols
	total := int(rows) * int(cols)
	f.cells = make([]Render_Cell_V2, total, allocator)
	f.cell_count = 0

	empty := render_cell_empty_v2()
	for i in 0..<total {
		f.cells[i] = empty
	}
}

// render_compiler_destroy_v2 frees the V2 compiled frame.
render_compiler_destroy_v2 :: proc(f: ^Compiled_Frame_V2, allocator: runtime.Allocator = context.allocator) {
	if f.cells != nil {
		delete(f.cells)
		f.cells = nil
	}
	f.cell_count = 0
}

// render_compile_full_v2 compiles the entire grid (ignoring damage).
// Fallback params default to nil (legacy pure pack); the renderer passes its
// chain/cache/atlas/counters to enable shaping on the slow path.
render_compile_full_v2 :: proc(
	f: ^Compiled_Frame_V2,
	terminal: ^termgrid.Terminal,
	chain: ^Fallback_Chain = nil,
	cache: ^Shape_Cache = nil,
	atlas: ^Atlas = nil,
	counters: ^Fallback_Counters = nil,
	rq: ^Raster_Queue = nil,
	view: ^termgrid.Terminal_View = nil,
) {
	rows := int(f.rows)
	cols := int(f.cols)

	for row in 0..<rows {
		_compile_row_range_v2(f, terminal, row, 0, cols, chain, cache, atlas, counters, rq, view)
	}
	f.cell_count = i32(rows * cols)
}

// _compile_row_range_v2 compiles a range of cells in a single row.
// ASCII cells (content < 0x80) take the unchanged pure-pack branch with zero
// new calls. Non-ASCII grapheme clusters and non-pinned literals resolve
// through shaped_cell_from_cluster; pinned non-ASCII keeps the pure pack.
// Crack: OutOfBounds → skip, no panic.
_compile_row_range_v2 :: proc(
	f: ^Compiled_Frame_V2,
	terminal: ^termgrid.Terminal,
	row: int,
	col_start: int,
	col_end: int,
	chain: ^Fallback_Chain = nil,
	cache: ^Shape_Cache = nil,
	atlas: ^Atlas = nil,
	counters: ^Fallback_Counters = nil,
	rq: ^Raster_Queue = nil,
	view: ^termgrid.Terminal_View = nil,
) {
	cols := int(f.cols)
	cs := col_start
	ce := col_end
	if cs < 0 { cs = 0 }
	if ce > cols { ce = cols }

	shaping := chain != nil && cache != nil && atlas != nil && counters != nil
	store := &terminal.grapheme_store
	document_row := row
	historical := false
	if view != nil {
		document_row = termgrid.terminal_view_document_row(terminal, view, row)
		historical = document_row >= 0 && document_row < len(terminal.scrollback.rows)
	}
	source_row := row
	if view != nil && !historical {
		source_row = document_row - len(terminal.scrollback.rows)
	}
	row_snapshot := termgrid.terminal_damage_target(terminal, source_row, 0)
	row_generation := row_snapshot.row_generation
	row_epoch := row_snapshot.epoch

	for col in cs..<ce {
		cell := termgrid.grid_get_cell(&terminal.grid, row, col)
		if view != nil {
			cell = termgrid.terminal_view_get_cell(terminal, view, row, col)
		}
		selection_point := termgrid.Terminal_Point{row = document_row, col = col}
		if view != nil {
			selection_point = termgrid.terminal_view_point_from_viewport(
				terminal, view, termgrid.Terminal_Point{row = row, col = col})
		}
		selected := view != nil && document_row >= 0 && termgrid.terminal_view_selection_contains(
			terminal, view, selection_point)
		shape_rq := rq
		if historical {
			// Historical cells are view-only. Do not enqueue a raster request whose
			// completion would later apply a damage target to the live grid.
			shape_rq = nil
		}
		rc: Render_Cell_V2
		if shaping && cell.content >= 0x80 {
			handle := termgrid.Content_Handle(cell.content)
			needs_shape := termgrid.content_is_grapheme(handle)
			if !needs_shape {
				_, pinned := atlas_pinned_slot_index(cell.content)
				needs_shape = !pinned
			}
			if needs_shape {
				target := termgrid.Damage_Target{row = source_row, col = col, row_generation = row_generation, epoch = row_epoch}
				request_result: Raster_Request_Result = .Enqueued
				left_cp, right_cp := rune(0), rune(0)
				if col > 0 {
					left_cp = termgrid.grapheme_resolve_base(
						(view == nil ? termgrid.grid_get_cell(&terminal.grid, row, col - 1) :
						termgrid.terminal_view_get_cell(terminal, view, row, col - 1)).content, store)
				}
				if col + 1 < cols {
					right_cp = termgrid.grapheme_resolve_base(
						(view == nil ? termgrid.grid_get_cell(&terminal.grid, row, col + 1) :
						termgrid.terminal_view_get_cell(terminal, view, row, col + 1)).content, store)
				}
				rc = shaped_cell_from_cluster(
					cell, left_cp, right_cp, store, chain, cache, atlas, counters, shape_rq, target, &request_result, selected)
				if shape_rq != nil && request_result == .Retry && !historical {
					termgrid.terminal_apply_damage_target(terminal, target)
				}
			} else {
				rc = render_cell_from_semantic(cell, selected)
			}
		} else {
			rc = render_cell_from_semantic(cell, selected)
		}

		idx := row * cols + col
		if idx < 0 || idx >= len(f.cells) {
			continue
		}
		f.cells[idx] = rc
	}
}

// shaped_cell_from_cluster resolves one non-ASCII cluster to a packed V2
// cell: join form from neighbors, value-identity cache lookup, presentation-
// first fallback resolve, single-slot rasterize+composite, tofu on
// exhaustion. Wide leads keep width 2 (continuation emits nothing
// downstream); empty/space/NUL pack verbatim so fallback never runs.
shaped_cell_from_cluster :: proc(
	cell: termgrid.Semantic_Cell,
	left_cp: rune,
	right_cp: rune,
	store: ^termgrid.Grapheme_Store,
	chain: ^Fallback_Chain,
	cache: ^Shape_Cache,
	atlas: ^Atlas,
	counters: ^Fallback_Counters,
	rq: ^Raster_Queue = nil,
	target: termgrid.Damage_Target,
	result: ^Raster_Request_Result = nil,
	selected: bool = false,
) -> Render_Cell_V2 {
	handle := termgrid.Content_Handle(cell.content)
	base := termgrid.grapheme_resolve_base(handle, store)
	if base == 0 || base == 0x20 {
		return render_cell_from_semantic(cell, selected)
	}

	w := RENDER_CELL_V2_WIDTH_NARROW
	cf := u8(0)
	if selected {
		cf |= RENDER_CELL_V2_CFLAG_SELECTED
	}
	if cell.width == 2 {
		w = RENDER_CELL_V2_WIDTH_WIDE_LEAD
	}
	style := u16(cell.style)

	// Collect cluster marks; an in-cluster ZWJ forces a right boundary
	// (never merges, no ligature) but stays in the key identity.
	mark_buf: [termgrid.GRAPHEME_MAX_MARKS]rune
	mark_n := 0
	own_zwj := false
	if termgrid.content_is_grapheme(handle) && store != nil {
		idx := int(handle - termgrid.CONTENT_GRAPHEME_BASE)
		if idx >= 0 && idx < termgrid.GRAPHEME_STORE_CAP {
			e := &store.entries[idx]
			for i in 0..<int(e.mark_count) {
				m := e.marks[i]
				if m == 0x200D {
					own_zwj = true
				}
				if mark_n < len(mark_buf) {
					mark_buf[mark_n] = m
					mark_n += 1
				}
			}
		}
	}

	// Arabic join form from the nearest non-transparent neighbors.
	// Transparent marks look through (assumed joining); ZWNJ/ZWJ, space,
	// ASCII, EOL, and non-joining letters are boundaries.
	self_type := arabic_join_type(base)
	join_form := Join_Form.Isolated
	shaped_arabic := false
	if self_type == .Dual_Joining || self_type == .Right_Joining {
		lj, rj := false, false
		if !_arabic_is_boundary(left_cp) {
			lt := arabic_join_type(left_cp)
			if lt == .Transparent {
				lj = true
			} else {
				lj = arabic_left_joins(left_cp, lt)
			}
		}
		if !own_zwj && !_arabic_is_boundary(right_cp) {
			rt := arabic_join_type(right_cp)
			if rt == .Transparent {
				rj = self_type == .Dual_Joining
			} else if self_type == .Dual_Joining {
				rj = rt == .Dual_Joining || rt == .Right_Joining
			}
		}
		join_form = arabic_join_form(lj, rj, self_type)
		shaped_arabic = true
	}

	key := cluster_key_from_handle(handle, store, join_form)
	if g, hit := shape_cache_lookup(cache, key); hit {
		if _shaped_slot_fresh(atlas, g) {
			return render_cell_pack_v2(cell.content, style, w, cf, g.atlas_slot)
		}
		// Stale FIFO slot: fall through and lazily re-resolve.
	}


	// Resolve: presentation form first for joining Arabic (retry logical
	// when the presentation is uncovered), logical otherwise.
	shaped := u32(base)
	font_index := 0
	covered := false
	if shaped_arabic {
		if pshaped, ok := arabic_presentation_form(base, join_form); ok {
			if fi, cov := fallback_resolve(chain, pshaped, counters); cov {
				shaped, font_index, covered = pshaped, fi, true
			}
		}
		if !covered {
			if fi, cov := fallback_resolve(chain, u32(base), counters); cov {
				shaped, font_index, covered = u32(base), fi, true
			}
		}
	} else {
		if fi, cov := fallback_resolve(chain, u32(base), counters); cov {
			shaped, font_index, covered = u32(base), fi, true
		}
	}

	// Chain exhausted (fallback_miss counted in resolve): tofu when a tofu
	// glyph is covered, else bg-only skip counted as tofu_missing.
	marks: []rune
	if !covered {
		if fi, cov := fallback_resolve(chain, FALLBACK_TOFU_PRIMARY, counters); cov {
			shaped, font_index = FALLBACK_TOFU_PRIMARY, fi
		} else if sfi, scov := fallback_resolve(chain, FALLBACK_TOFU_SECONDARY, counters); scov {
			shaped, font_index = FALLBACK_TOFU_SECONDARY, sfi
		} else {
			if counters != nil {
				counters.tofu_missing += 1
			}
			return render_cell_pack_v2(0, style, RENDER_CELL_V2_WIDTH_NARROW, cf, RENDER_CELL_V2_SLOT_UNRESOLVED)
		}
	} else {
		// Keep only covered marks (independent probes, nil counters: a
		// mark miss is mark_drop, never fallback_miss). Cross-font pairs
		// composite into ONE slot downstream.
		kept: [termgrid.GRAPHEME_MAX_MARKS]rune
		kn := 0
		for i in 0..<mark_n {
			if _, mok := fallback_resolve(chain, u32(mark_buf[i]), nil); mok {
				kept[kn] = mark_buf[i]
				kn += 1
			} else if counters != nil {
				counters.mark_drop += 1
			}
		}
		marks = kept[:kn]
	}

	// Async enqueue: resolve stays sync, the raster moves off-thread, and
	// this frame packs the blank UNRESOLVED placeholder (pop-in next
	// frame). Chain exhaustion above stays fully sync (no enqueue).
	if rq != nil {
		wide := termgrid.wcwidth(rune(key.base)) == 2
		request_result := raster_request_async(rq, key, font_index, shaped, marks, wide, target)
		if result != nil { result^ = request_result }
		return render_cell_pack_v2(0, style, RENDER_CELL_V2_WIDTH_NARROW, cf, RENDER_CELL_V2_SLOT_UNRESOLVED)
	}
	g := atlas_ensure_glyph(atlas, chain, cache, key, font_index, shaped, marks, counters)
	if g.atlas_slot == RENDER_CELL_V2_SLOT_UNRESOLVED {
		return render_cell_pack_v2(0, style, RENDER_CELL_V2_WIDTH_NARROW, cf, RENDER_CELL_V2_SLOT_UNRESOLVED)
	}
	return render_cell_pack_v2(cell.content, style, w, cf, g.atlas_slot)
}

// _shaped_slot_fresh verifies a cached glyph still owns its dynamic slot
// (FIFO eviction may have reclaimed it). Pinned-range slots only need valid.
_shaped_slot_fresh :: proc(atlas: ^Atlas, g: Shaped_Glyph) -> bool {
	if atlas == nil {
		return false
	}
	slot := int(g.atlas_slot)
	if slot < 0 || slot >= ATLAS_SLOT_COUNT {
		return false
	}
	if slot < FALLBACK_SLOT_BASE {
		return atlas.slots[slot].valid
	}
	want := (u64(g.font_index) << 32) | u64(g.shaped_codepoint)
	return atlas.fallback_tag[slot - FALLBACK_SLOT_BASE] == want && atlas.slots[slot].valid
}

// render_compile_v2 compiles only the dirty ranges specified by the damage journal.
render_compile_v2 :: proc(
	f: ^Compiled_Frame_V2,
	terminal: ^termgrid.Terminal,
	journal: ^termgrid.Damage_Journal,
	chain: ^Fallback_Chain = nil,
	cache: ^Shape_Cache = nil,
	atlas: ^Atlas = nil,
	counters: ^Fallback_Counters = nil,
	rq: ^Raster_Queue = nil,
) {
	rows := int(f.rows)
	cols := int(f.cols)

	for row_idx in 0..<rows {
		if row_idx >= len(journal.dirty_rows) {
			break
		}

		dr := &journal.dirty_rows[row_idx]

		if !dr.full && dr.span_count == 0 {
			continue
		}

		if dr.full {
			_compile_row_range_v2(f, terminal, row_idx, 0, cols, chain, cache, atlas, counters, rq)
		} else {
			for span_idx in 0..<int(dr.span_count) {
				span := &dr.spans[span_idx]
				col_start := int(span.col_start)
				col_end   := int(span.col_end)
				_compile_row_range_v2(f, terminal, row_idx, col_start, col_end, chain, cache, atlas, counters, rq)
			}
		}
	}
}

package session_ipc

import "core:encoding/endian"
import "core:slice"
import termgrid "../terminal"

// Wire constants
SNAPSHOT_HEADER_BYTES    :: 38
SECTION_HEADER_BYTES     :: 8
METADATA_PAYLOAD_BYTES   :: 22
METADATA_SECTION_BYTES   :: SECTION_HEADER_BYTES + METADATA_PAYLOAD_BYTES
STYLE_TABLE_HEADER_BYTES :: 12
STYLE_ENTRY_BYTES        :: 16
FULL_GRID_HEADER_BYTES   :: 16
ROW_META_BYTES           :: 8
CELL_BYTES               :: 8
EXT_COLOR_BYTES          :: 8
DELTA_GRID_HEADER_BYTES  :: 12
DELTA_ROW_HEADER_BYTES   :: 8
SCROLLBACK_HEADER_BYTES  :: 12
SCROLLBACK_ROW_HEADER_BYTES :: 4

Snapshot_Type :: enum u8 {
	Full  = 1,
	Delta = 2,
}

Snapshot_Section_Kind :: enum u8 {
	Metadata        = 1,
	Style_Table     = 2,
	Grid_Cells      = 3,
	Scrollback_Page = 4,
	End             = 5,
}

Snapshot_Header :: struct {
	workspace_id:   u64,
	pane_id:        u64,
	snapshot_rev:   u64,
	topology_rev:   u64,
	kind:           Snapshot_Type,
	total_sections: u16,
	section_index:  u16,
}

Snapshot_Metadata :: struct {
	rows:                u16,
	cols:                u16,
	is_alt_screen:       bool,
	cursor_row:          i16,
	cursor_col:          i16,
	cursor_visible:      bool,
	cursor_pending_wrap: bool,
	cursor_style:        u8,
	saved_cursor_row:    i16,
	saved_cursor_col:    i16,
	saved_cursor_valid:  bool,
	mouse_tracking:      u8,
	mouse_format:        u8,
	bracketed_paste:     bool,
	app_cursor_keys:     bool,
	kitty_kb_flags:      u8,
}

Snapshot_Error :: enum {
	None,
	Buffer_Too_Small,
	Incomplete,
	Malformed,
	Dimension_Mismatch,
	Unsupported_Kind,
}

Section_Header_Decoded :: struct {
	kind:        Snapshot_Section_Kind,
	subkind:     u8,
	payload_len: u32,
}

encode_section_header :: proc(
	dst: []u8,
	kind: Snapshot_Section_Kind,
	subkind: u8,
	payload_len: u32,
) -> (written: int, err: Snapshot_Error) {
	if len(dst) < SECTION_HEADER_BYTES do return 0, .Buffer_Too_Small
	dst[0] = u8(kind)
	dst[1] = subkind
	endian.unchecked_put_u16le(dst[2:4], 0) // reserved
	endian.unchecked_put_u32le(dst[4:8], payload_len)
	return SECTION_HEADER_BYTES, .None
}

decode_section_header :: proc(src: []u8) -> (sh: Section_Header_Decoded, consumed: int, err: Snapshot_Error) {
	if len(src) < SECTION_HEADER_BYTES do return {}, 0, .Incomplete
	raw_kind := src[0]
	if raw_kind < u8(Snapshot_Section_Kind.Metadata) || raw_kind > u8(Snapshot_Section_Kind.End) {
		return {}, 0, .Unsupported_Kind
	}
	res := endian.unchecked_get_u16le(src[2:4])
	if res != 0 do return {}, 0, .Malformed
	plen := endian.unchecked_get_u32le(src[4:8])
	if plen > u32(MAX_PAYLOAD_BYTES) do return {}, 0, .Malformed
	return {Snapshot_Section_Kind(raw_kind), src[1], plen}, SECTION_HEADER_BYTES, .None
}

encode_snapshot_header :: proc(dst: []u8, h: Snapshot_Header) -> (written: int, err: Snapshot_Error) {
	if len(dst) < SNAPSHOT_HEADER_BYTES do return 0, .Buffer_Too_Small
	if h.kind != .Full && h.kind != .Delta do return 0, .Unsupported_Kind

	endian.unchecked_put_u64le(dst[0:8], h.workspace_id)
	endian.unchecked_put_u64le(dst[8:16], h.pane_id)
	endian.unchecked_put_u64le(dst[16:24], h.snapshot_rev)
	endian.unchecked_put_u64le(dst[24:32], h.topology_rev)
	dst[32] = u8(h.kind)
	dst[33] = 0 // padding
	endian.unchecked_put_u16le(dst[34:36], h.total_sections)
	endian.unchecked_put_u16le(dst[36:38], h.section_index)
	return SNAPSHOT_HEADER_BYTES, .None
}

decode_snapshot_header :: proc(src: []u8) -> (h: Snapshot_Header, consumed: int, err: Snapshot_Error) {
	if len(src) < SNAPSHOT_HEADER_BYTES do return {}, 0, .Incomplete

	raw_kind := src[32]
	if raw_kind != u8(Snapshot_Type.Full) && raw_kind != u8(Snapshot_Type.Delta) {
		return {}, 0, .Unsupported_Kind
	}
	if src[33] != 0 do return {}, 0, .Malformed

	h = Snapshot_Header{
		workspace_id   = endian.unchecked_get_u64le(src[0:8]),
		pane_id        = endian.unchecked_get_u64le(src[8:16]),
		snapshot_rev   = endian.unchecked_get_u64le(src[16:24]),
		topology_rev   = endian.unchecked_get_u64le(src[24:32]),
		kind           = Snapshot_Type(raw_kind),
		total_sections = endian.unchecked_get_u16le(src[34:36]),
		section_index  = endian.unchecked_get_u16le(src[36:38]),
	}
	return h, SNAPSHOT_HEADER_BYTES, .None
}

encode_metadata_section :: proc(dst: []u8, meta: Snapshot_Metadata) -> (written: int, err: Snapshot_Error) {
	if len(dst) < METADATA_SECTION_BYTES do return 0, .Buffer_Too_Small
	encode_section_header(dst, .Metadata, 0, METADATA_PAYLOAD_BYTES)
	p := dst[SECTION_HEADER_BYTES:METADATA_SECTION_BYTES]
	endian.unchecked_put_u16le(p[0:2], meta.rows)
	endian.unchecked_put_u16le(p[2:4], meta.cols)
	p[4] = 1 if meta.is_alt_screen else 0
	p[5] = 1 if meta.cursor_visible else 0
	p[6] = 1 if meta.cursor_pending_wrap else 0
	p[7] = meta.cursor_style
	endian.unchecked_put_u16le(p[8:10], u16(meta.cursor_row))
	endian.unchecked_put_u16le(p[10:12], u16(meta.cursor_col))
	endian.unchecked_put_u16le(p[12:14], u16(meta.saved_cursor_row))
	endian.unchecked_put_u16le(p[14:16], u16(meta.saved_cursor_col))
	p[16] = 1 if meta.saved_cursor_valid else 0
	p[17] = meta.mouse_tracking
	p[18] = meta.mouse_format
	p[19] = 1 if meta.bracketed_paste else 0
	p[20] = 1 if meta.app_cursor_keys else 0
	p[21] = meta.kitty_kb_flags
	return METADATA_SECTION_BYTES, .None
}

decode_metadata_section :: proc(src: []u8) -> (meta: Snapshot_Metadata, consumed: int, err: Snapshot_Error) {
	sh, sh_n, sh_err := decode_section_header(src)
	if sh_err != .None do return {}, 0, sh_err
	if sh.kind != .Metadata do return {}, 0, .Unsupported_Kind
	if sh.payload_len != METADATA_PAYLOAD_BYTES do return {}, 0, .Malformed
	total := sh_n + int(sh.payload_len)
	if len(src) < total do return {}, 0, .Incomplete
	p := src[sh_n:total]
	meta.rows = endian.unchecked_get_u16le(p[0:2])
	meta.cols = endian.unchecked_get_u16le(p[2:4])
	meta.is_alt_screen = p[4] != 0
	meta.cursor_visible = p[5] != 0
	meta.cursor_pending_wrap = p[6] != 0
	meta.cursor_style = p[7]
	meta.cursor_row = i16(endian.unchecked_get_u16le(p[8:10]))
	meta.cursor_col = i16(endian.unchecked_get_u16le(p[10:12]))
	meta.saved_cursor_row = i16(endian.unchecked_get_u16le(p[12:14]))
	meta.saved_cursor_col = i16(endian.unchecked_get_u16le(p[14:16]))
	meta.saved_cursor_valid = p[16] != 0
	meta.mouse_tracking = p[17]
	meta.mouse_format = p[18]
	meta.bracketed_paste = p[19] != 0
	meta.app_cursor_keys = p[20] != 0
	meta.kitty_kb_flags = p[21]
	return meta, total, .None
}

encode_style_table_section :: proc(dst: []u8, table: ^termgrid.Style_Table) -> (written: int, err: Snapshot_Error) {
	if table == nil do return 0, .Malformed
	if int(table.count) > termgrid.STYLE_TABLE_CAPACITY do return 0, .Malformed
	payload_len := STYLE_TABLE_HEADER_BYTES + int(table.count) * STYLE_ENTRY_BYTES
	total := SECTION_HEADER_BYTES + payload_len
	if total > len(dst) || total > MAX_PAYLOAD_BYTES do return 0, .Buffer_Too_Small

	encode_section_header(dst, .Style_Table, 0, u32(payload_len))
	p := dst[SECTION_HEADER_BYTES:total]
	endian.unchecked_put_u16le(p[0:2], table.count)
	endian.unchecked_put_u16le(p[2:4], 0) // reserved
	endian.unchecked_put_u32le(p[4:8], table.theme.foreground)
	endian.unchecked_put_u32le(p[8:12], table.theme.background)

	curr := STYLE_TABLE_HEADER_BYTES
	for i in 0..<int(table.count) {
		s := table.entries[i]
		endian.unchecked_put_u32le(p[curr:curr+4], s.fg)
		endian.unchecked_put_u32le(p[curr+4:curr+8], s.bg)
		endian.unchecked_put_u32le(p[curr+8:curr+12], s.underline)
		endian.unchecked_put_u16le(p[curr+12:curr+14], s.flags)
		endian.unchecked_put_u16le(p[curr+14:curr+16], s.hyperlink_id)
		curr += STYLE_ENTRY_BYTES
	}
	return total, .None
}

decode_style_table_section :: proc(src: []u8, table: ^termgrid.Style_Table) -> (consumed: int, err: Snapshot_Error) {
	if table == nil do return 0, .Malformed
	sh, sh_n, sh_err := decode_section_header(src)
	if sh_err != .None do return 0, sh_err
	if sh.kind != .Style_Table do return 0, .Unsupported_Kind
	if int(sh.payload_len) < STYLE_TABLE_HEADER_BYTES do return 0, .Malformed
	total := sh_n + int(sh.payload_len)
	if len(src) < total do return 0, .Incomplete
	p := src[sh_n:total]

	count := endian.unchecked_get_u16le(p[0:2])
	res := endian.unchecked_get_u16le(p[2:4])
	if res != 0 do return 0, .Malformed
	if int(count) > termgrid.STYLE_TABLE_CAPACITY do return 0, .Malformed
	expected_len := STYLE_TABLE_HEADER_BYTES + int(count) * STYLE_ENTRY_BYTES
	if int(sh.payload_len) != expected_len do return 0, .Malformed

	table.count = count
	table.theme.foreground = endian.unchecked_get_u32le(p[4:8])
	table.theme.background = endian.unchecked_get_u32le(p[8:12])

	curr := STYLE_TABLE_HEADER_BYTES
	for i in 0..<int(count) {
		table.entries[i] = termgrid.Style{
			fg           = endian.unchecked_get_u32le(p[curr:curr+4]),
			bg           = endian.unchecked_get_u32le(p[curr+4:curr+8]),
			underline    = endian.unchecked_get_u32le(p[curr+8:curr+12]),
			flags        = endian.unchecked_get_u16le(p[curr+12:curr+14]),
			hyperlink_id = endian.unchecked_get_u16le(p[curr+14:curr+16]),
		}
		curr += STYLE_ENTRY_BYTES
	}
	return total, .None
}

encode_full_grid_section :: proc(dst: []u8, g: ^termgrid.Grid) -> (written: int, err: Snapshot_Error) {
	if g == nil do return 0, .Malformed
	if g.row_count <= 0 || g.col_count <= 0 || g.capacity <= 0 do return 0, .Malformed
	total_cells := g.capacity * g.col_count
	payload_len := FULL_GRID_HEADER_BYTES + g.capacity * ROW_META_BYTES + total_cells * (CELL_BYTES + EXT_COLOR_BYTES)
	total := SECTION_HEADER_BYTES + payload_len
	if total > len(dst) || total > MAX_PAYLOAD_BYTES do return 0, .Buffer_Too_Small

	encode_section_header(dst, .Grid_Cells, 1 /* Full */, u32(payload_len))
	p := dst[SECTION_HEADER_BYTES:total]
	endian.unchecked_put_u16le(p[0:2], u16(g.row_count))
	endian.unchecked_put_u16le(p[2:4], u16(g.col_count))
	endian.unchecked_put_u32le(p[4:8], u32(g.capacity))
	endian.unchecked_put_u32le(p[8:12], u32(g.origin))
	endian.unchecked_put_u32le(p[12:16], u32(g.mask))

	curr := FULL_GRID_HEADER_BYTES
	for r in 0..<g.capacity {
		row := &g.rows[r]
		endian.unchecked_put_u32le(p[curr:curr+4], row.generation)
		p[curr+4] = 1 if row.wrapped else 0
		p[curr+5] = 1 if row.is_prompt else 0
		p[curr+6] = u8(transmute(u8)row.ext.channels)
		p[curr+7] = 0 // reserved
		curr += ROW_META_BYTES
	}

	for i in 0..<total_cells {
		c := g.cells[i]
		endian.unchecked_put_u32le(p[curr:curr+4], u32(c.content))
		endian.unchecked_put_u16le(p[curr+4:curr+6], u16(c.style))
		p[curr+6] = c.width
		p[curr+7] = u8(c.flags)
		curr += CELL_BYTES
	}

	for i in 0..<total_cells {
		dc := g.ext_colors[i]
		endian.unchecked_put_u32le(p[curr:curr+4], dc.fg)
		endian.unchecked_put_u32le(p[curr+4:curr+8], dc.bg)
		curr += EXT_COLOR_BYTES
	}

	return total, .None
}

decode_full_grid_section :: proc(src: []u8, g: ^termgrid.Grid) -> (consumed: int, err: Snapshot_Error) {
	if g == nil do return 0, .Malformed
	sh, sh_n, sh_err := decode_section_header(src)
	if sh_err != .None do return 0, sh_err
	if sh.kind != .Grid_Cells do return 0, .Unsupported_Kind
	if sh.subkind != 1 /* Full */ do return 0, .Unsupported_Kind
	if int(sh.payload_len) < FULL_GRID_HEADER_BYTES do return 0, .Malformed
	total := sh_n + int(sh.payload_len)
	if len(src) < total do return 0, .Incomplete
	p := src[sh_n:total]

	rows := int(endian.unchecked_get_u16le(p[0:2]))
	cols := int(endian.unchecked_get_u16le(p[2:4]))
	capacity := int(endian.unchecked_get_u32le(p[4:8]))
	origin := int(endian.unchecked_get_u32le(p[8:12]))
	mask := int(endian.unchecked_get_u32le(p[12:16]))

	if rows <= 0 || cols <= 0 || capacity <= 0 do return 0, .Malformed
	if origin < 0 || origin >= capacity do return 0, .Malformed
	if mask != capacity - 1 do return 0, .Malformed

	total_cells := capacity * cols
	expected_len := FULL_GRID_HEADER_BYTES + capacity * ROW_META_BYTES + total_cells * (CELL_BYTES + EXT_COLOR_BYTES)
	if int(sh.payload_len) != expected_len do return 0, .Malformed

	if g.row_count != rows || g.col_count != cols {
		return 0, .Dimension_Mismatch
	}

	g.origin = origin
	g.mask = mask

	curr := FULL_GRID_HEADER_BYTES
	for r in 0..<capacity {
		gen := endian.unchecked_get_u32le(p[curr:curr+4])
		wrapped := p[curr+4] != 0
		is_prompt := p[curr+5] != 0
		channels := transmute(termgrid.Cell_Channels)p[curr+6]
		if p[curr+7] != 0 do return 0, .Malformed
		g.rows[r].generation = gen
		g.rows[r].wrapped = wrapped
		g.rows[r].is_prompt = is_prompt
		g.rows[r].ext.channels = channels
		curr += ROW_META_BYTES
	}

	for i in 0..<total_cells {
		g.cells[i] = termgrid.Semantic_Cell{
			content = termgrid.Content_Handle(endian.unchecked_get_u32le(p[curr:curr+4])),
			style   = termgrid.Style_Id(endian.unchecked_get_u16le(p[curr+4:curr+6])),
			width   = p[curr+6],
			flags   = termgrid.Cell_Flags(p[curr+7]),
		}
		curr += CELL_BYTES
	}

	for i in 0..<total_cells {
		g.ext_colors[i] = termgrid.Direct_Color_Channel{
			fg = endian.unchecked_get_u32le(p[curr:curr+4]),
			bg = endian.unchecked_get_u32le(p[curr+4:curr+8]),
		}
		curr += EXT_COLOR_BYTES
	}

	return total, .None
}

encode_delta_grid_section :: proc(
	dst: []u8,
	g: ^termgrid.Grid,
	dirty_rows: []termgrid.Dirty_Row,
	row_count: int,
) -> (written: int, err: Snapshot_Error) {
	if g == nil do return 0, .Malformed
	if g.row_count <= 0 || g.col_count <= 0 do return 0, .Malformed
	rows_to_check := min(len(dirty_rows), min(row_count, g.row_count))

	damaged_count := 0
	payload_len := DELTA_GRID_HEADER_BYTES
	for r in 0..<rows_to_check {
		dr := &dirty_rows[r]
		if dr.full || dr.span_count > 0 {
			damaged_count += 1
			phys := termgrid._grid_physical_row(g, r)
			prow := &g.rows[phys]
			has_dc := .Direct_Color in prow.ext.channels
			row_bytes := DELTA_ROW_HEADER_BYTES + g.col_count * CELL_BYTES + (g.col_count * EXT_COLOR_BYTES if has_dc else 0)
			payload_len += row_bytes
		}
	}

	total := SECTION_HEADER_BYTES + payload_len
	if total > len(dst) || total > MAX_PAYLOAD_BYTES do return 0, .Buffer_Too_Small

	encode_section_header(dst, .Grid_Cells, 2 /* Delta */, u32(payload_len))
	p := dst[SECTION_HEADER_BYTES:total]
	endian.unchecked_put_u32le(p[0:4], u32(g.origin))
	endian.unchecked_put_u16le(p[4:6], u16(g.row_count))
	endian.unchecked_put_u16le(p[6:8], u16(g.col_count))
	endian.unchecked_put_u16le(p[8:10], u16(damaged_count))
	endian.unchecked_put_u16le(p[10:12], 0) // reserved

	curr := DELTA_GRID_HEADER_BYTES
	for r in 0..<rows_to_check {
		dr := &dirty_rows[r]
		if !(dr.full || dr.span_count > 0) do continue

		phys := termgrid._grid_physical_row(g, r)
		prow := &g.rows[phys]
		has_dc := .Direct_Color in prow.ext.channels

		flags: u8 = 0
		if prow.wrapped do flags |= 1
		if prow.is_prompt do flags |= 2

		endian.unchecked_put_u16le(p[curr:curr+2], u16(r))
		p[curr+2] = flags
		p[curr+3] = u8(transmute(u8)prow.ext.channels)
		endian.unchecked_put_u32le(p[curr+4:curr+8], prow.generation)
		curr += DELTA_ROW_HEADER_BYTES

		for c in 0..<g.col_count {
			cell := prow.cells[c]
			endian.unchecked_put_u32le(p[curr:curr+4], u32(cell.content))
			endian.unchecked_put_u16le(p[curr+4:curr+6], u16(cell.style))
			p[curr+6] = cell.width
			p[curr+7] = u8(cell.flags)
			curr += CELL_BYTES
		}

		if has_dc {
			for c in 0..<g.col_count {
				dc := prow.ext.colors[c]
				endian.unchecked_put_u32le(p[curr:curr+4], dc.fg)
				endian.unchecked_put_u32le(p[curr+4:curr+8], dc.bg)
				curr += EXT_COLOR_BYTES
			}
		}
	}

	return total, .None
}

decode_delta_grid_section :: proc(src: []u8, g: ^termgrid.Grid) -> (consumed: int, err: Snapshot_Error) {
	if g == nil do return 0, .Malformed
	sh, sh_n, sh_err := decode_section_header(src)
	if sh_err != .None do return 0, sh_err
	if sh.kind != .Grid_Cells do return 0, .Unsupported_Kind
	if sh.subkind != 2 /* Delta */ do return 0, .Unsupported_Kind
	if int(sh.payload_len) < DELTA_GRID_HEADER_BYTES do return 0, .Malformed
	total := sh_n + int(sh.payload_len)
	if len(src) < total do return 0, .Incomplete
	p := src[sh_n:total]

	origin := int(endian.unchecked_get_u32le(p[0:4]))
	rows := int(endian.unchecked_get_u16le(p[4:6]))
	cols := int(endian.unchecked_get_u16le(p[6:8]))
	damaged_count := int(endian.unchecked_get_u16le(p[8:10]))
	res := endian.unchecked_get_u16le(p[10:12])
	if res != 0 do return 0, .Malformed

	if rows <= 0 || cols <= 0 do return 0, .Malformed

	// Dimension check: must match g exactly!
	if g.row_count != rows || g.col_count != cols {
		return 0, .Dimension_Mismatch
	}

	// Pre-validation pass: verify bounds of every damaged row before touching g
	curr := DELTA_GRID_HEADER_BYTES
	for _ in 0..<damaged_count {
		if curr + DELTA_ROW_HEADER_BYTES > len(p) do return 0, .Malformed
		logical_row := int(endian.unchecked_get_u16le(p[curr:curr+2]))
		if logical_row >= g.row_count do return 0, .Malformed
		channels := transmute(termgrid.Cell_Channels)p[curr+3]
		curr += DELTA_ROW_HEADER_BYTES
		row_cells_bytes := cols * CELL_BYTES
		if curr + row_cells_bytes > len(p) do return 0, .Malformed
		curr += row_cells_bytes
		if .Direct_Color in channels {
			row_colors_bytes := cols * EXT_COLOR_BYTES
			if curr + row_colors_bytes > len(p) do return 0, .Malformed
			curr += row_colors_bytes
		}
	}
	if curr != len(p) do return 0, .Malformed

	// Second pass: apply to g
	g.origin = origin
	curr = DELTA_GRID_HEADER_BYTES
	for _ in 0..<damaged_count {
		logical_row := int(endian.unchecked_get_u16le(p[curr:curr+2]))
		flags := p[curr+2]
		channels := transmute(termgrid.Cell_Channels)p[curr+3]
		generation := endian.unchecked_get_u32le(p[curr+4:curr+8])
		curr += DELTA_ROW_HEADER_BYTES

		phys := termgrid._grid_physical_row(g, logical_row)
		prow := &g.rows[phys]
		prow.wrapped = (flags & 1) != 0
		prow.is_prompt = (flags & 2) != 0
		prow.ext.channels = channels
		prow.generation = generation

		for c in 0..<cols {
			prow.cells[c] = termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(endian.unchecked_get_u32le(p[curr:curr+4])),
				style   = termgrid.Style_Id(endian.unchecked_get_u16le(p[curr+4:curr+6])),
				width   = p[curr+6],
				flags   = termgrid.Cell_Flags(p[curr+7]),
			}
			curr += CELL_BYTES
		}

		if .Direct_Color in channels {
			for c in 0..<cols {
				prow.ext.colors[c] = termgrid.Direct_Color_Channel{
					fg = endian.unchecked_get_u32le(p[curr:curr+4]),
					bg = endian.unchecked_get_u32le(p[curr+4:curr+8]),
				}
				curr += EXT_COLOR_BYTES
			}
		} else {
			if len(prow.ext.colors) > 0 {
				slice.zero(prow.ext.colors)
			}
		}
	}

	return total, .None
}

encode_scrollback_page_section :: proc(
	dst: []u8,
	sb: ^termgrid.Scrollback,
	start_row: int,
	max_rows: int,
) -> (written: int, err: Snapshot_Error) {
	if sb == nil do return 0, .Malformed
	if sb.col_count <= 0 do return 0, .Malformed

	count_to_encode := 0
	if start_row >= 0 && start_row < sb.count && max_rows > 0 {
		count_to_encode = min(max_rows, sb.count - start_row)
	}

	payload_len := SCROLLBACK_HEADER_BYTES
	for i in 0..<count_to_encode {
		row := termgrid.scrollback_get(sb, start_row + i)
		has_dc := row != nil && (.Direct_Color in row.ext.channels)
		row_bytes := SCROLLBACK_ROW_HEADER_BYTES + sb.col_count * CELL_BYTES + (sb.col_count * EXT_COLOR_BYTES if has_dc else 0)
		payload_len += row_bytes
	}

	total := SECTION_HEADER_BYTES + payload_len
	if total > len(dst) || total > MAX_PAYLOAD_BYTES do return 0, .Buffer_Too_Small

	encode_section_header(dst, .Scrollback_Page, 0, u32(payload_len))
	p := dst[SECTION_HEADER_BYTES:total]
	endian.unchecked_put_u16le(p[0:2], u16(sb.col_count))
	endian.unchecked_put_u16le(p[2:4], u16(count_to_encode))
	endian.unchecked_put_u32le(p[4:8], u32(max(0, start_row)))
	endian.unchecked_put_u32le(p[8:12], u32(sb.count))

	curr := SCROLLBACK_HEADER_BYTES
	for i in 0..<count_to_encode {
		row := termgrid.scrollback_get(sb, start_row + i)
		if row == nil do continue
		has_dc := .Direct_Color in row.ext.channels

		p[curr] = 1 if row.wrapped else 0
		p[curr+1] = u8(transmute(u8)row.ext.channels)
		endian.unchecked_put_u16le(p[curr+2:curr+4], 0) // reserved
		curr += SCROLLBACK_ROW_HEADER_BYTES

		for c in 0..<sb.col_count {
			cell := row.cells[c]
			endian.unchecked_put_u32le(p[curr:curr+4], u32(cell.content))
			endian.unchecked_put_u16le(p[curr+4:curr+6], u16(cell.style))
			p[curr+6] = cell.width
			p[curr+7] = u8(cell.flags)
			curr += CELL_BYTES
		}

		if has_dc {
			for c in 0..<sb.col_count {
				dc := row.ext.colors[c]
				endian.unchecked_put_u32le(p[curr:curr+4], dc.fg)
				endian.unchecked_put_u32le(p[curr+4:curr+8], dc.bg)
				curr += EXT_COLOR_BYTES
			}
		}
	}

	return total, .None
}

decode_scrollback_page_section :: proc(src: []u8, sb: ^termgrid.Scrollback) -> (consumed: int, err: Snapshot_Error) {
	if sb == nil do return 0, .Malformed
	sh, sh_n, sh_err := decode_section_header(src)
	if sh_err != .None do return 0, sh_err
	if sh.kind != .Scrollback_Page do return 0, .Unsupported_Kind
	if int(sh.payload_len) < SCROLLBACK_HEADER_BYTES do return 0, .Malformed
	total := sh_n + int(sh.payload_len)
	if len(src) < total do return 0, .Incomplete
	p := src[sh_n:total]

	col_count := int(endian.unchecked_get_u16le(p[0:2]))
	row_count := int(endian.unchecked_get_u16le(p[2:4]))

	if col_count <= 0 do return 0, .Malformed
	if sb.col_count != col_count do return 0, .Dimension_Mismatch

	// Pre-validation pass
	curr := SCROLLBACK_HEADER_BYTES
	for _ in 0..<row_count {
		if curr + SCROLLBACK_ROW_HEADER_BYTES > len(p) do return 0, .Malformed
		channels := transmute(termgrid.Cell_Channels)p[curr+1]
		res := endian.unchecked_get_u16le(p[curr+2:curr+4])
		if res != 0 do return 0, .Malformed
		curr += SCROLLBACK_ROW_HEADER_BYTES
		row_cells_bytes := col_count * CELL_BYTES
		if curr + row_cells_bytes > len(p) do return 0, .Malformed
		curr += row_cells_bytes
		if .Direct_Color in channels {
			row_colors_bytes := col_count * EXT_COLOR_BYTES
			if curr + row_colors_bytes > len(p) do return 0, .Malformed
			curr += row_colors_bytes
		}
	}
	if curr != len(p) do return 0, .Malformed

	// Decode pass
	temp_cells: [1024]termgrid.Semantic_Cell
	temp_colors: [1024]termgrid.Direct_Color_Channel
	if col_count > len(temp_cells) do return 0, .Malformed

	curr = SCROLLBACK_HEADER_BYTES
	for _ in 0..<row_count {
		wrapped := p[curr] != 0
		channels := transmute(termgrid.Cell_Channels)p[curr+1]
		curr += SCROLLBACK_ROW_HEADER_BYTES

		for c in 0..<col_count {
			temp_cells[c] = termgrid.Semantic_Cell{
				content = termgrid.Content_Handle(endian.unchecked_get_u32le(p[curr:curr+4])),
				style   = termgrid.Style_Id(endian.unchecked_get_u16le(p[curr+4:curr+6])),
				width   = p[curr+6],
				flags   = termgrid.Cell_Flags(p[curr+7]),
			}
			curr += CELL_BYTES
		}

		if .Direct_Color in channels {
			for c in 0..<col_count {
				temp_colors[c] = termgrid.Direct_Color_Channel{
					fg = endian.unchecked_get_u32le(p[curr:curr+4]),
					bg = endian.unchecked_get_u32le(p[curr+4:curr+8]),
				}
				curr += EXT_COLOR_BYTES
			}
			termgrid.scrollback_push(sb, temp_cells[:col_count], nil, wrapped, ext = {channels = channels, colors = temp_colors[:col_count]})
		} else {
			termgrid.scrollback_push(sb, temp_cells[:col_count], nil, wrapped, ext = {channels = channels})
		}
	}

	return total, .None
}

encode_terminal_snapshot :: proc(dst: []u8, t: ^termgrid.Terminal, h: Snapshot_Header) -> (written: int, err: Snapshot_Error) {
	if t == nil do return 0, .Malformed
	if h.kind != .Full && h.kind != .Delta do return 0, .Unsupported_Kind
	if len(dst) < SNAPSHOT_HEADER_BYTES do return 0, .Buffer_Too_Small

	active_grid := &t.alt_grid if t.is_alt_screen else &t.grid
	meta := Snapshot_Metadata{
		rows                = u16(active_grid.row_count),
		cols                = u16(active_grid.col_count),
		is_alt_screen       = t.is_alt_screen,
		cursor_row          = i16(t.cursor.row),
		cursor_col          = i16(t.cursor.col),
		cursor_visible      = t.cursor.visible,
		cursor_pending_wrap = t.cursor.pending_wrap,
		cursor_style        = t.cursor.style,
		saved_cursor_row    = i16(t.saved_cursor.row),
		saved_cursor_col    = i16(t.saved_cursor.col),
		saved_cursor_valid  = t.saved_cursor_valid,
		mouse_tracking      = u8(t.mouse_tracking),
		mouse_format        = u8(t.mouse_format),
		bracketed_paste     = t.bracketed_paste,
		app_cursor_keys     = t.app_cursor_keys,
		kitty_kb_flags      = t.kitty_kb_alt.flags if t.is_alt_screen else t.kitty_kb.flags,
	}

	h_out := h
	h_out.total_sections = 4
	h_out.section_index = 0

	offset := 0
	hdr_n, hdr_err := encode_snapshot_header(dst[offset:], h_out)
	if hdr_err != .None do return 0, hdr_err
	offset += hdr_n

	meta_n, meta_err := encode_metadata_section(dst[offset:], meta)
	if meta_err != .None do return 0, meta_err
	offset += meta_n

	style_n, style_err := encode_style_table_section(dst[offset:], &active_grid.style_table)
	if style_err != .None do return 0, style_err
	offset += style_n

	if h.kind == .Full {
		grid_n, grid_err := encode_full_grid_section(dst[offset:], active_grid)
		if grid_err != .None do return 0, grid_err
		offset += grid_n
	} else {
		grid_n, grid_err := encode_delta_grid_section(dst[offset:], active_grid, t.damage.dirty_rows, active_grid.row_count)
		if grid_err != .None do return 0, grid_err
		offset += grid_n
	}

	end_n, end_err := encode_section_header(dst[offset:], .End, 0, 0)
	if end_err != .None do return 0, end_err
	offset += end_n

	if offset > MAX_PAYLOAD_BYTES do return 0, .Buffer_Too_Small
	return offset, .None
}

apply_terminal_snapshot :: proc(t: ^termgrid.Terminal, payload: []u8) -> (h: Snapshot_Header, err: Snapshot_Error) {
	if t == nil do return {}, .Malformed
	header, hdr_consumed, hdr_err := decode_snapshot_header(payload)
	if hdr_err != .None do return {}, hdr_err

	// Pre-validation pass: validate all sections and dimension compatibility BEFORE touching t
	meta_found := false
	meta := Snapshot_Metadata{}
	curr := hdr_consumed
	for curr < len(payload) {
		sh, sh_n, sh_err := decode_section_header(payload[curr:])
		if sh_err != .None do return header, sh_err

		sec_total := sh_n + int(sh.payload_len)
		if curr + sec_total > len(payload) do return header, .Incomplete

		switch sh.kind {
		case .Metadata:
			if sh.payload_len != METADATA_PAYLOAD_BYTES do return header, .Malformed
			m, _, m_err := decode_metadata_section(payload[curr:curr+sec_total])
			if m_err != .None do return header, m_err
			meta = m
			meta_found = true

		case .Style_Table:
			if int(sh.payload_len) < STYLE_TABLE_HEADER_BYTES do return header, .Malformed

		case .Grid_Cells:
			if header.kind == .Full && sh.subkind != 1 do return header, .Unsupported_Kind
			if header.kind == .Delta && sh.subkind != 2 do return header, .Unsupported_Kind

		case .Scrollback_Page:
			if int(sh.payload_len) < SCROLLBACK_HEADER_BYTES do return header, .Malformed

		case .End:
			curr += sec_total
			break

		case:
			return header, .Unsupported_Kind
		}

		curr += sec_total
		if sh.kind == .End do break
	}

	if !meta_found do return header, .Malformed
	target_grid := &t.alt_grid if meta.is_alt_screen else &t.grid
	if target_grid.row_count != int(meta.rows) || target_grid.col_count != int(meta.cols) {
		if header.kind == .Full {
			// Safe reconciliation: resize receiver terminal to match the full snapshot
			termgrid.terminal_resize(t, int(meta.rows), int(meta.cols))
		} else {
			return header, .Dimension_Mismatch
		}
	}

	// Apply pass: all validations passed, safe to update t
	t.is_alt_screen = meta.is_alt_screen
	t.cursor.row = int(meta.cursor_row)
	t.cursor.col = int(meta.cursor_col)
	t.cursor.visible = meta.cursor_visible
	t.cursor.pending_wrap = meta.cursor_pending_wrap
	t.cursor.style = meta.cursor_style
	t.saved_cursor.row = int(meta.saved_cursor_row)
	t.saved_cursor.col = int(meta.saved_cursor_col)
	t.saved_cursor_valid = meta.saved_cursor_valid
	t.mouse_tracking = termgrid.Mouse_Tracking_Mode(meta.mouse_tracking)
	t.mouse_format = termgrid.Mouse_Format(meta.mouse_format)
	t.bracketed_paste = meta.bracketed_paste
	t.app_cursor_keys = meta.app_cursor_keys
	if t.is_alt_screen {
		t.kitty_kb_alt.flags = meta.kitty_kb_flags
	} else {
		t.kitty_kb.flags = meta.kitty_kb_flags
	}

	curr = hdr_consumed
	for curr < len(payload) {
		sh, sh_n, _ := decode_section_header(payload[curr:])
		sec_total := sh_n + int(sh.payload_len)
		sec_slice := payload[curr:curr+sec_total]

		switch sh.kind {
		case .Metadata:
			// already applied

		case .Style_Table:
			active_grid := &t.alt_grid if t.is_alt_screen else &t.grid
			_, s_err := decode_style_table_section(sec_slice, &active_grid.style_table)
			if s_err != .None do return header, s_err

		case .Grid_Cells:
			active_grid := &t.alt_grid if t.is_alt_screen else &t.grid
			if header.kind == .Full {
				_, g_err := decode_full_grid_section(sec_slice, active_grid)
				if g_err != .None do return header, g_err
				for r in 0..<active_grid.row_count {
					phys := termgrid._grid_physical_row(active_grid, r)
					termgrid.damage_mark_row(&t.damage, r, active_grid.rows[phys].generation)
				}
			} else {
				_, g_err := decode_delta_grid_section(sec_slice, active_grid)
				if g_err != .None do return header, g_err
			}

		case .Scrollback_Page:
			_, sb_err := decode_scrollback_page_section(sec_slice, &t.scrollback)
			if sb_err != .None do return header, sb_err

		case .End:
			return header, .None

		case:
			return header, .Unsupported_Kind
		}

		curr += sec_total
		if sh.kind == .End do break
	}

	return header, .None
}

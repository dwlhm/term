package session_ipc_test

import "core:testing"
import "core:encoding/endian"
import ipc "../"
import termgrid "../../terminal"

@(test)
test_snapshot_header_codec :: proc(t: ^testing.T) {
	h := ipc.Snapshot_Header{
		workspace_id   = 0x1234567890ABCDEF,
		pane_id        = 0xFEDCBA0987654321,
		snapshot_rev   = 42,
		topology_rev   = 7,
		kind           = .Full,
		total_sections = 4,
		section_index  = 0,
	}

	buf: [64]u8
	written, enc_err := ipc.encode_snapshot_header(buf[:], h)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, written, ipc.SNAPSHOT_HEADER_BYTES)

	decoded, consumed, dec_err := ipc.decode_snapshot_header(buf[:written])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, decoded.workspace_id, h.workspace_id)
	testing.expect_value(t, decoded.pane_id, h.pane_id)
	testing.expect_value(t, decoded.snapshot_rev, h.snapshot_rev)
	testing.expect_value(t, decoded.topology_rev, h.topology_rev)
	testing.expect_value(t, decoded.kind, h.kind)
	testing.expect_value(t, decoded.total_sections, h.total_sections)
	testing.expect_value(t, decoded.section_index, h.section_index)

	// Rejects truncated buffer (< 34 B and < SNAPSHOT_HEADER_BYTES)
	for cut in 0..<ipc.SNAPSHOT_HEADER_BYTES {
		_, _, err := ipc.decode_snapshot_header(buf[:cut])
		testing.expect_value(t, err, ipc.Snapshot_Error.Incomplete)
	}

	// Rejects invalid kind
	bad_kind_buf := buf
	bad_kind_buf[32] = 0
	_, _, bad_err := ipc.decode_snapshot_header(bad_kind_buf[:written])
	testing.expect_value(t, bad_err, ipc.Snapshot_Error.Unsupported_Kind)

	bad_kind_buf[32] = 99
	_, _, bad_err2 := ipc.decode_snapshot_header(bad_kind_buf[:written])
	testing.expect_value(t, bad_err2, ipc.Snapshot_Error.Unsupported_Kind)

	// Rejects non-zero padding
	bad_pad_buf := buf
	bad_pad_buf[33] = 1
	_, _, pad_err := ipc.decode_snapshot_header(bad_pad_buf[:written])
	testing.expect_value(t, pad_err, ipc.Snapshot_Error.Malformed)
}

@(test)
test_metadata_section_codec :: proc(t: ^testing.T) {
	meta := ipc.Snapshot_Metadata{
		rows                = 40,
		cols                = 120,
		is_alt_screen       = true,
		cursor_row          = 15,
		cursor_col          = 30,
		cursor_visible      = true,
		cursor_pending_wrap = false,
		cursor_style        = 2,
		saved_cursor_row    = 10,
		saved_cursor_col    = 5,
		saved_cursor_valid  = true,
		mouse_tracking      = 2,
		mouse_format        = 1,
		bracketed_paste     = true,
		app_cursor_keys     = true,
		kitty_kb_flags      = 7,
	}

	buf: [64]u8
	written, enc_err := ipc.encode_metadata_section(buf[:], meta)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, written, ipc.METADATA_SECTION_BYTES)

	decoded, consumed, dec_err := ipc.decode_metadata_section(buf[:written])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, decoded.rows, meta.rows)
	testing.expect_value(t, decoded.cols, meta.cols)
	testing.expect_value(t, decoded.is_alt_screen, meta.is_alt_screen)
	testing.expect_value(t, decoded.cursor_row, meta.cursor_row)
	testing.expect_value(t, decoded.cursor_col, meta.cursor_col)
	testing.expect_value(t, decoded.cursor_visible, meta.cursor_visible)
	testing.expect_value(t, decoded.cursor_pending_wrap, meta.cursor_pending_wrap)
	testing.expect_value(t, decoded.cursor_style, meta.cursor_style)
	testing.expect_value(t, decoded.saved_cursor_row, meta.saved_cursor_row)
	testing.expect_value(t, decoded.saved_cursor_col, meta.saved_cursor_col)
	testing.expect_value(t, decoded.saved_cursor_valid, meta.saved_cursor_valid)
	testing.expect_value(t, decoded.mouse_tracking, meta.mouse_tracking)
	testing.expect_value(t, decoded.mouse_format, meta.mouse_format)
	testing.expect_value(t, decoded.bracketed_paste, meta.bracketed_paste)
	testing.expect_value(t, decoded.app_cursor_keys, meta.app_cursor_keys)
	testing.expect_value(t, decoded.kitty_kb_flags, meta.kitty_kb_flags)

	// Truncation rejection
	for cut in 0..<written {
		_, _, err := ipc.decode_metadata_section(buf[:cut])
		testing.expect(t, err != .None)
	}
}

@(test)
test_style_table_section_codec :: proc(t: ^testing.T) {
	st: termgrid.Style_Table
	termgrid.style_table_init(&st, termgrid.THEME_CATPPUCCIN_MOCHA)

	s1 := termgrid.Style{
		fg           = 0xFF112233,
		bg           = 0xFF445566,
		underline    = 0xFFAABBCC,
		flags        = termgrid.STYLE_FLAG_BOLD | termgrid.STYLE_FLAG_ITALIC,
		hyperlink_id = 42,
	}
	s2 := termgrid.Style{
		fg           = 0xFF778899,
		bg           = 0xFFAABBCC,
		underline    = 0,
		flags        = termgrid.STYLE_FLAG_UNDERLINE,
		hyperlink_id = 0,
	}

	id1 := termgrid.style_table_insert(&st, s1)
	id2 := termgrid.style_table_insert(&st, s2)
	testing.expect(t, id1 > 0)
	testing.expect(t, id2 > 0)

	buf: [4096]u8
	written, enc_err := ipc.encode_style_table_section(buf[:], &st)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)
	testing.expect(t, written > 0)

	receiver: termgrid.Style_Table
	termgrid.style_table_init(&receiver, termgrid.THEME_CATPPUCCIN_MOCHA)
	consumed, dec_err := ipc.decode_style_table_section(buf[:written], &receiver)
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, consumed, written)

	testing.expect_value(t, receiver.count, st.count)
	testing.expect_value(t, receiver.theme.foreground, st.theme.foreground)
	testing.expect_value(t, receiver.theme.background, st.theme.background)

	for i in 0..<int(st.count) {
		testing.expect_value(t, receiver.entries[i].fg, st.entries[i].fg)
		testing.expect_value(t, receiver.entries[i].bg, st.entries[i].bg)
		testing.expect_value(t, receiver.entries[i].underline, st.entries[i].underline)
		testing.expect_value(t, receiver.entries[i].flags, st.entries[i].flags)
		testing.expect_value(t, receiver.entries[i].hyperlink_id, st.entries[i].hyperlink_id)
	}
}

@(test)
test_full_grid_roundtrip :: proc(t: ^testing.T) {
	t1 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t1)
		free(t1)
	}
	termgrid.terminal_init(t1, 24, 80)

	t2 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t2)
		free(t2)
	}
	termgrid.terminal_init(t2, 24, 80)

	// Write styled text with direct truecolor
	termgrid.terminal_set_direct_fg(t1, 0xFFFF0055)
	termgrid.terminal_set_direct_bg(t1, 0xFF003366)
	for r in "Hello, Terminal Snapshot!" {
		termgrid.terminal_put_char(t1, r)
	}
	termgrid.terminal_reset_direct_fg(t1)
	termgrid.terminal_reset_direct_bg(t1)

	// Insert custom style and write wide characters
	custom_style := termgrid.Style{
		fg    = 0xFFEEAA00,
		bg    = 0xFF1E1E2E,
		flags = termgrid.STYLE_FLAG_BOLD,
	}
	t1.current_style = termgrid.style_table_insert(&t1.grid.style_table, custom_style)
	termgrid.terminal_put_char(t1, '世')
	termgrid.terminal_put_char(t1, '界')

	t1.bracketed_paste = true
	t1.app_cursor_keys = true
	t1.kitty_kb.flags = 3

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	h := ipc.Snapshot_Header{
		workspace_id = 101,
		pane_id      = 202,
		snapshot_rev = 1,
		topology_rev = 1,
		kind         = .Full,
	}

	written, enc_err := ipc.encode_terminal_snapshot(buf, t1, h)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)
	testing.expect(t, written > 0)

	dec_h, dec_err := ipc.apply_terminal_snapshot(t2, buf[:written])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, dec_h.workspace_id, h.workspace_id)
	testing.expect_value(t, dec_h.pane_id, h.pane_id)
	testing.expect_value(t, dec_h.kind, ipc.Snapshot_Type.Full)

	// Assert metadata matches
	testing.expect_value(t, t2.grid.row_count, t1.grid.row_count)
	testing.expect_value(t, t2.grid.col_count, t1.grid.col_count)
	testing.expect_value(t, t2.cursor.row, t1.cursor.row)
	testing.expect_value(t, t2.cursor.col, t1.cursor.col)
	testing.expect_value(t, t2.bracketed_paste, t1.bracketed_paste)
	testing.expect_value(t, t2.app_cursor_keys, t1.app_cursor_keys)
	testing.expect_value(t, t2.kitty_kb.flags, t1.kitty_kb.flags)

	// Assert every cell, style, and direct color matches bit-for-bit
	for r in 0..<t1.grid.row_count {
		p1 := termgrid._grid_physical_row(&t1.grid, r)
		p2 := termgrid._grid_physical_row(&t2.grid, r)
		row1 := &t1.grid.rows[p1]
		row2 := &t2.grid.rows[p2]

		testing.expect_value(t, row2.generation, row1.generation)
		testing.expect_value(t, row2.wrapped, row1.wrapped)
		testing.expect_value(t, row2.is_prompt, row1.is_prompt)
		testing.expect_value(t, row2.ext.channels, row1.ext.channels)

		for c in 0..<t1.grid.col_count {
			c1 := row1.cells[c]
			c2 := row2.cells[c]
			testing.expect_value(t, c2.content, c1.content)
			testing.expect_value(t, c2.style, c1.style)
			testing.expect_value(t, c2.width, c1.width)
			testing.expect_value(t, c2.flags, c1.flags)

			dc1 := row1.ext.colors[c]
			dc2 := row2.ext.colors[c]
			testing.expect_value(t, dc2.fg, dc1.fg)
			testing.expect_value(t, dc2.bg, dc1.bg)
		}
	}

	testing.expect_value(t, t2.grid.style_table.count, t1.grid.style_table.count)
	for i in 0..<int(t1.grid.style_table.count) {
		testing.expect_value(t, t2.grid.style_table.entries[i], t1.grid.style_table.entries[i])
	}
}

@(test)
test_delta_grid_roundtrip :: proc(t: ^testing.T) {
	t1 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t1)
		free(t1)
	}
	termgrid.terminal_init(t1, 24, 80)

	t2 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t2)
		free(t2)
	}
	termgrid.terminal_init(t2, 24, 80)

	// Initialize with base text across lines
	for r in "Base text line" {
		termgrid.terminal_put_char(t1, r)
	}

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	h_full := ipc.Snapshot_Header{workspace_id = 1, pane_id = 1, snapshot_rev = 1, topology_rev = 1, kind = .Full}
	n_full, _ := ipc.encode_terminal_snapshot(buf, t1, h_full)
	_, _ = ipc.apply_terminal_snapshot(t2, buf[:n_full])

	// Clear damage on t1 to isolate delta
	termgrid.damage_clear(&t1.damage)

	// Modify only 2 rows in active grid: row 3 and row 7
	termgrid.cursor_move(&t1.cursor, 3, 0, 24, 80)
	for r in "Row 3 Modified" {
		termgrid.terminal_put_char(t1, r)
	}

	termgrid.cursor_move(&t1.cursor, 7, 0, 24, 80)
	termgrid.terminal_set_direct_fg(t1, 0xFF00FF00)
	for r in "Row 7 Direct Color" {
		termgrid.terminal_put_char(t1, r)
	}
	termgrid.terminal_reset_direct_fg(t1)

	// Verify only row 3 and row 7 are marked dirty
	testing.expect(t, t1.damage.dirty_rows[3].full || t1.damage.dirty_rows[3].span_count > 0)
	testing.expect(t, t1.damage.dirty_rows[7].full || t1.damage.dirty_rows[7].span_count > 0)
	testing.expect(t, !t1.damage.dirty_rows[0].full && t1.damage.dirty_rows[0].span_count == 0)

	// Encode delta snapshot
	h_delta := ipc.Snapshot_Header{workspace_id = 1, pane_id = 1, snapshot_rev = 2, topology_rev = 1, kind = .Delta}
	n_delta, enc_err := ipc.encode_terminal_snapshot(buf, t1, h_delta)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)

	// Apply to receiver
	dec_h, dec_err := ipc.apply_terminal_snapshot(t2, buf[:n_delta])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, dec_h.kind, ipc.Snapshot_Type.Delta)

	// Verify row 3 and row 7 match t1
	p1_r3 := termgrid._grid_physical_row(&t1.grid, 3)
	p2_r3 := termgrid._grid_physical_row(&t2.grid, 3)
	for c in 0..<80 {
		testing.expect_value(t, t2.grid.rows[p2_r3].cells[c], t1.grid.rows[p1_r3].cells[c])
	}

	p1_r7 := termgrid._grid_physical_row(&t1.grid, 7)
	p2_r7 := termgrid._grid_physical_row(&t2.grid, 7)
	for c in 0..<80 {
		testing.expect_value(t, t2.grid.rows[p2_r7].cells[c], t1.grid.rows[p1_r7].cells[c])
		testing.expect_value(t, t2.grid.rows[p2_r7].ext.colors[c], t1.grid.rows[p1_r7].ext.colors[c])
	}

	// Verify unchanged rows retain their original contents
	for r in 0..<24 {
		if r == 3 || r == 7 do continue
		p1 := termgrid._grid_physical_row(&t1.grid, r)
		p2 := termgrid._grid_physical_row(&t2.grid, r)
		for c in 0..<80 {
			testing.expect_value(t, t2.grid.rows[p2].cells[c], t1.grid.rows[p1].cells[c])
		}
	}
}

@(test)
test_delta_dimension_mismatch_rejection :: proc(t: ^testing.T) {
	t1 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t1)
		free(t1)
	}
	termgrid.terminal_init(t1, 24, 80)

	t2 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t2)
		free(t2)
	}
	termgrid.terminal_init(t2, 40, 100)

	// Write something in t2 and record state
	termgrid.terminal_put_char(t2, 'Z')
	t2_cursor_before := t2.cursor
	t2_cell_before := termgrid.grid_get_cell(&t2.grid, 0, 0)

	// Mutate t1 and mark damage
	termgrid.terminal_put_char(t1, 'A')

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	h := ipc.Snapshot_Header{workspace_id = 1, pane_id = 1, snapshot_rev = 1, topology_rev = 1, kind = .Delta}
	n, enc_err := ipc.encode_terminal_snapshot(buf, t1, h)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)

	// Apply delta from 80x24 to 100x40 -> must return Dimension_Mismatch
	_, dec_err := ipc.apply_terminal_snapshot(t2, buf[:n])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.Dimension_Mismatch)

	// Receiver must remain untouched
	testing.expect_value(t, t2.cursor.row, t2_cursor_before.row)
	testing.expect_value(t, t2.cursor.col, t2_cursor_before.col)
	testing.expect_value(t, termgrid.grid_get_cell(&t2.grid, 0, 0), t2_cell_before)
	testing.expect_value(t, t2.grid.row_count, 40)
	testing.expect_value(t, t2.grid.col_count, 100)
}

@(test)
test_snapshot_full_reconciles_dimension_mismatch :: proc(t: ^testing.T) {
	t1 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t1)
		free(t1)
	}
	termgrid.terminal_init(t1, 24, 80)

	t2 := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(t2)
		free(t2)
	}
	termgrid.terminal_init(t2, 40, 100)

	termgrid.terminal_put_char(t1, 'X')

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	h := ipc.Snapshot_Header{workspace_id = 1, pane_id = 1, snapshot_rev = 1, topology_rev = 1, kind = .Full}
	n, enc_err := ipc.encode_terminal_snapshot(buf, t1, h)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)

	// Apply Full from 80x24 to 100x40 -> receiver terminal must safely reconcile dimensions
	_, dec_err := ipc.apply_terminal_snapshot(t2, buf[:n])
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)

	testing.expect_value(t, t2.grid.row_count, 24)
	testing.expect_value(t, t2.grid.col_count, 80)
	testing.expect_value(t, termgrid.grid_get_cell(&t2.grid, 0, 0).content, termgrid.Content_Handle('X'))
}

@(test)
test_scrollback_page_codec :: proc(t: ^testing.T) {
	sb1: termgrid.Scrollback
	termgrid.scrollback_init(&sb1, 80, 50)
	defer termgrid.scrollback_destroy(&sb1, nil)

	sb2: termgrid.Scrollback
	termgrid.scrollback_init(&sb2, 80, 50)
	defer termgrid.scrollback_destroy(&sb2, nil)

	// Row 1: normal row
	cells1: [80]termgrid.Semantic_Cell
	for c in 0..<80 {
		cells1[c] = termgrid.Semantic_Cell{content = termgrid.Content_Handle('A' + (c % 26)), width = 1}
	}
	termgrid.scrollback_push(&sb1, cells1[:], nil, wrapped = false)

	// Row 2: wrapped row
	cells2: [80]termgrid.Semantic_Cell
	for c in 0..<80 {
		cells2[c] = termgrid.Semantic_Cell{content = termgrid.Content_Handle('0' + (c % 10)), width = 1}
	}
	termgrid.scrollback_push(&sb1, cells2[:], nil, wrapped = true)

	// Row 3: row with direct truecolor
	cells3: [80]termgrid.Semantic_Cell
	colors3: [80]termgrid.Direct_Color_Channel
	for c in 0..<80 {
		cells3[c] = termgrid.Semantic_Cell{
			content = termgrid.Content_Handle('X'),
			flags   = .Direct_Color,
			width   = 1,
		}
		colors3[c] = termgrid.Direct_Color_Channel{
			fg = 0xFF123456,
			bg = 0xFF654321,
		}
	}
	termgrid.scrollback_push(&sb1, cells3[:], nil, wrapped = false, ext = {channels = {.Direct_Color}, colors = colors3[:]})

	testing.expect_value(t, sb1.count, 3)

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	written, enc_err := ipc.encode_scrollback_page_section(buf, &sb1, 0, sb1.count)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)
	testing.expect(t, written > 0)

	consumed, dec_err := ipc.decode_scrollback_page_section(buf[:written], &sb2)
	testing.expect_value(t, dec_err, ipc.Snapshot_Error.None)
	testing.expect_value(t, consumed, written)
	testing.expect_value(t, sb2.count, 3)

	for i in 0..<3 {
		r1 := termgrid.scrollback_get(&sb1, i)
		r2 := termgrid.scrollback_get(&sb2, i)
		testing.expect(t, r1 != nil)
		testing.expect(t, r2 != nil)
		testing.expect_value(t, r2.wrapped, r1.wrapped)
		testing.expect_value(t, r2.ext.channels, r1.ext.channels)

		for c in 0..<80 {
			testing.expect_value(t, r2.cells[c], r1.cells[c])
			if .Direct_Color in r1.ext.channels {
				testing.expect_value(t, r2.ext.colors[c], r1.ext.colors[c])
			}
		}
	}
}

@(test)
test_corrupt_payload_rejection :: proc(t: ^testing.T) {
	term := new(termgrid.Terminal)
	defer {
		termgrid.terminal_destroy(term)
		free(term)
	}
	termgrid.terminal_init(term, 24, 80)

	termgrid.terminal_put_char(term, 'Q')

	buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(buf)

	h := ipc.Snapshot_Header{workspace_id = 1, pane_id = 1, snapshot_rev = 1, topology_rev = 1, kind = .Full}
	n, enc_err := ipc.encode_terminal_snapshot(buf, term, h)
	testing.expect_value(t, enc_err, ipc.Snapshot_Error.None)

	// 1. Corrupt section kind
	bad_kind_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(bad_kind_buf)
	copy(bad_kind_buf[:n], buf[:n])
	bad_kind_buf[ipc.SNAPSHOT_HEADER_BYTES] = 99
	_, err1 := ipc.apply_terminal_snapshot(term, bad_kind_buf[:n])
	testing.expect(t, err1 == .Unsupported_Kind || err1 == .Malformed)

	// 2. Corrupt section length claiming out of bounds
	bad_len_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(bad_len_buf)
	copy(bad_len_buf[:n], buf[:n])
	endian.unchecked_put_u32le(bad_len_buf[ipc.SNAPSHOT_HEADER_BYTES+4 : ipc.SNAPSHOT_HEADER_BYTES+8], 999999)
	_, err2 := ipc.apply_terminal_snapshot(term, bad_len_buf[:n])
	testing.expect(t, err2 == .Incomplete || err2 == .Malformed)

	// 3. Truncated buffer across header and sections
	for cut in 0..<ipc.SNAPSHOT_HEADER_BYTES+20 {
		_, err3 := ipc.apply_terminal_snapshot(term, buf[:cut])
		testing.expect(t, err3 != .None)
	}

	// 4. Non-zero reserved bytes in section header
	bad_res_buf := make([]u8, ipc.MAX_PAYLOAD_BYTES)
	defer delete(bad_res_buf)
	copy(bad_res_buf[:n], buf[:n])
	bad_res_buf[ipc.SNAPSHOT_HEADER_BYTES+2] = 0xAA
	_, err4 := ipc.apply_terminal_snapshot(term, bad_res_buf[:n])
	testing.expect_value(t, err4, ipc.Snapshot_Error.Malformed)
}

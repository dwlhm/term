package interaction

import "core:strings"
import "core:unicode"
import termgrid "../terminal"

Char_Class :: enum u8 {
	Whitespace = 0,
	Word       = 1,
	Symbol     = 2,
}

_is_path_or_word_char :: proc(r: rune) -> bool {
	if unicode.is_alpha(r) || unicode.is_digit(r) {
		return true
	}
	switch r {
	case '/', '.', '-', '_', ':', '~':
		return true
	}
	return false
}

_cell_char_class :: proc(t: ^termgrid.Terminal, pt: termgrid.Terminal_Point) -> (Char_Class, rune) {
	cell := termgrid.terminal_view_get_document_cell(t, pt)
	r: rune = ' '
	if cell.content != 0 {
		if termgrid.content_is_grapheme(cell.content) {
			r = termgrid.grapheme_resolve_base(cell.content, &t.grapheme_store)
		} else {
			r = rune(cell.content)
		}
	}
	if r == ' ' || r == 0 || unicode.is_space(r) {
		return .Whitespace, r
	}
	if _is_path_or_word_char(r) {
		return .Word, r
	}
	return .Symbol, r
}

_interaction_cell_is_blank :: proc(cell: termgrid.Semantic_Cell) -> bool {
	return cell.content == 0 || cell.content == termgrid.Content_Handle(' ')
}

_interaction_write_cell :: proc(b: ^strings.Builder, cell: termgrid.Semantic_Cell, store: ^termgrid.Grapheme_Store) {
	if cell.content == 0 || u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) != 0 {
		return
	}
	if !termgrid.content_is_grapheme(cell.content) {
		strings.write_rune(b, rune(cell.content))
		return
	}
	idx := int(cell.content - termgrid.CONTENT_GRAPHEME_BASE)
	if idx < 0 || idx >= termgrid.GRAPHEME_STORE_CAP {
		strings.write_rune(b, termgrid.grapheme_resolve_base(cell.content, store))
		return
	}
	cluster := store.entries[idx]
	count := min(int(cluster.rune_count), termgrid.GRAPHEME_INLINE_CAP)
	for i in 0 ..< count {
		strings.write_rune(b, cluster.runes[i])
	}
}

// interaction_select_word_bounds finds inclusive start and end columns for the word
// under pt, categorizing characters into alphanumeric words, whitespace, or symbols.
interaction_select_word_bounds :: proc(t: ^termgrid.Terminal, pt: termgrid.Terminal_Point) -> (start, end: termgrid.Terminal_Point) {
	if t == nil || t.grid.col_count <= 0 || t.grid.row_count <= 0 {
		return pt, pt
	}
	norm := termgrid.terminal_view_normalize_point(t, pt)
	start = norm
	end = norm

	target_class, _ := _cell_char_class(t, norm)

	// Scan left
	for start.col > 0 {
		prev := termgrid.Terminal_Point{row = norm.row, col = start.col - 1}
		cls, _ := _cell_char_class(t, prev)
		if cls != target_class {
			break
		}
		start.col -= 1
	}

	// Scan right
	for end.col < t.grid.col_count - 1 {
		next_pt := termgrid.Terminal_Point{row = norm.row, col = end.col + 1}
		cls, _ := _cell_char_class(t, next_pt)
		if cls != target_class {
			break
		}
		end.col += 1
	}

	// If end lands on a wide lead, ensure end includes wide continuation
	end_cell := termgrid.terminal_view_get_document_cell(t, end)
	if end_cell.width == 2 && end.col + 1 < t.grid.col_count {
		end.col += 1
	}

	return start, end
}

// interaction_select_line_bounds returns inclusive bounds spanning the entire row at pt.
interaction_select_line_bounds :: proc(t: ^termgrid.Terminal, pt: termgrid.Terminal_Point) -> (start, end: termgrid.Terminal_Point) {
	if t == nil || t.grid.col_count <= 0 || t.grid.row_count <= 0 {
		return pt, pt
	}
	norm := termgrid.terminal_view_normalize_point(t, pt)
	start = termgrid.Terminal_Point{row = norm.row, col = 0}
	end = termgrid.Terminal_Point{row = norm.row, col = t.grid.col_count - 1}
	return start, end
}

// interaction_search_scan scans the combined document (scrollback + live grid) for query matches,
// writing found intervals into out_matches and returning the total number of matches found.
interaction_search_scan :: proc(t: ^termgrid.Terminal, query: string, out_matches: []Search_Match) -> int {
	if t == nil || len(query) == 0 || len(out_matches) == 0 || t.grid.col_count <= 0 || t.grid.row_count <= 0 {
		return 0
	}

	query_runes: [256]rune
	q_len := 0
	for r in query {
		if q_len < len(query_runes) {
			query_runes[q_len] = unicode.to_lower(r)
			q_len += 1
		}
	}
	if q_len == 0 do return 0

	total_rows := termgrid.scrollback_len(&t.scrollback) + t.grid.row_count
	count := 0

	row_runes: [1024]rune
	row_cols: [1024]int

	cols := min(t.grid.col_count, 1024)

	for r in 0 ..< total_rows {
		row_len := 0
		for c in 0 ..< cols {
			cell := termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = r, col = c})
			if u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) != 0 {
				continue
			}
			ch: rune = ' '
			if cell.content != 0 {
				if termgrid.content_is_grapheme(cell.content) {
					ch = termgrid.grapheme_resolve_base(cell.content, &t.grapheme_store)
				} else {
					ch = rune(cell.content)
				}
			}
			row_runes[row_len] = unicode.to_lower(ch)
			row_cols[row_len] = c
			row_len += 1
		}

		if row_len < q_len do continue

		for i := 0; i <= row_len - q_len; i += 1 {
			matched := true
			for j in 0 ..< q_len {
				if row_runes[i + j] != query_runes[j] {
					matched = false
					break
				}
			}
			if matched {
				c_start := row_cols[i]
				c_end := row_cols[i + q_len - 1]
				end_cell := termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = r, col = c_end})
				if end_cell.width == 2 && c_end + 1 < t.grid.col_count {
					c_end += 1
				}
				out_matches[count] = Search_Match{
					row       = r,
					col_start = c_start,
					col_end   = c_end,
				}
				count += 1
				if count == len(out_matches) {
					return count
				}
			}
		}
	}

	return count
}

// interaction_extract_selection_text extracts the selected text according to Visual_Kind (Char, Line, Block),
// resolving grapheme clusters and stripping trailing blank cells per line.
interaction_extract_selection_text :: proc(t: ^termgrid.Terminal, s: ^Interaction_State) -> string {
	if t == nil || s == nil || !s.selection_active || t.grid.col_count <= 0 || t.grid.row_count <= 0 {
		return ""
	}

	p1 := termgrid.terminal_view_normalize_point(t, s.selection_anchor)
	p2 := termgrid.terminal_view_normalize_point(t, s.visual_cursor)

	b := strings.builder_make()

	switch s.visual_kind {
	case .Char:
		start, end := p1, p2
		if start.row > end.row || (start.row == end.row && start.col > end.col) {
			start, end = end, start
		}
		for row := start.row; row <= end.row; row += 1 {
			if row > start.row {
				strings.write_rune(&b, '\n')
			}
			line_start := row == start.row ? start.col : 0
			line_end := row == end.row ? end.col : t.grid.col_count - 1
			last := line_end
			for last >= line_start {
				cell := termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = last})
				if !_interaction_cell_is_blank(cell) {
					break
				}
				last -= 1
			}
			for col := line_start; col <= last; col += 1 {
				_interaction_write_cell(&b, termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = col}), &t.grapheme_store)
			}
		}

	case .Line:
		min_row := min(p1.row, p2.row)
		max_row := max(p1.row, p2.row)
		for row := min_row; row <= max_row; row += 1 {
			if row > min_row {
				strings.write_rune(&b, '\n')
			}
			line_start := 0
			line_end := t.grid.col_count - 1
			last := line_end
			for last >= line_start {
				cell := termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = last})
				if !_interaction_cell_is_blank(cell) {
					break
				}
				last -= 1
			}
			for col := line_start; col <= last; col += 1 {
				_interaction_write_cell(&b, termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = col}), &t.grapheme_store)
			}
		}

	case .Block:
		min_row := min(p1.row, p2.row)
		max_row := max(p1.row, p2.row)
		min_col := min(p1.col, p2.col)
		max_col := max(p1.col, p2.col)
		for row := min_row; row <= max_row; row += 1 {
			if row > min_row {
				strings.write_rune(&b, '\n')
			}
			last := max_col
			for last >= min_col {
				cell := termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = last})
				if !_interaction_cell_is_blank(cell) {
					break
				}
				last -= 1
			}
			for col := min_col; col <= last; col += 1 {
				_interaction_write_cell(&b, termgrid.terminal_view_get_document_cell(t, termgrid.Terminal_Point{row = row, col = col}), &t.grapheme_store)
			}
		}
	}

	return strings.to_string(b)
}

Link_Kind :: enum u8 {
	None,
	URL,
	Path,
}

Link_Target :: struct {
	kind: Link_Kind,
	text: [512]u8,
	len:  int,
}

// interaction_detect_link_at_point inspects the cell or word under pt.
// Returns Link_Target with .URL if hyperlink_id > 0 or a URL scheme is found,
// or .Path if a local filesystem path is found.
interaction_detect_link_at_point :: proc(t: ^termgrid.Terminal, pt: termgrid.Terminal_Point) -> Link_Target {
	res := Link_Target{kind = .None, len = 0}
	if t == nil do return res

	// 1. Check if cell has explicit hyperlink_id > 0
	cell := termgrid.terminal_view_get_document_cell(t, pt)
	if cell.style < t.grid.style_table.count {
		st := termgrid.style_table_get(&t.grid.style_table, cell.style)
		if st.hyperlink_id > 0 {
			url := termgrid.hyperlink_store_get(&t.hyperlinks, st.hyperlink_id)
			if len(url) > 0 {
				s_url := string(url)
				if strings.has_prefix(s_url, "http://") || strings.has_prefix(s_url, "https://") || strings.has_prefix(s_url, "file://") || strings.has_prefix(s_url, "mailto:") {
					res.kind = .URL
					n := min(len(url), len(res.text))
					copy(res.text[:n], url[:n])
					res.len = n
					return res
				}
			}
		}
	}

	// 2. Otherwise detect URL or path from word under cursor
	start, end := interaction_select_word_bounds(t, pt)
	if start.col > end.col || start.row != end.row {
		return res
	}

	buf: [512]u8
	b_len := 0
	for col in start.col..=end.col {
		p := termgrid.Terminal_Point{row = start.row, col = col}
		c := termgrid.terminal_view_get_document_cell(t, p)
		if c.content == 0 || (u8(c.flags) & u8(termgrid.Cell_Flags.Wide_Continuation)) != 0 {
			continue
		}
		r: rune
		if termgrid.content_is_grapheme(c.content) {
			r = termgrid.grapheme_resolve_base(c.content, &t.grapheme_store)
		} else {
			r = rune(c.content)
		}
		if r > 0 && r < 128 && b_len < len(buf) {
			buf[b_len] = u8(r)
			b_len += 1
		}
	}

	if b_len == 0 {
		return res
	}
	s := string(buf[:b_len])

	// URL detection
	if strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://") || strings.has_prefix(s, "file://") {
		res.kind = .URL
		copy(res.text[:b_len], buf[:b_len])
		res.len = b_len
		return res
	}

	// Path detection
	if strings.has_prefix(s, "/") || strings.has_prefix(s, "~/") || strings.has_prefix(s, "./") || strings.has_prefix(s, "../") {
		res.kind = .Path
		copy(res.text[:b_len], buf[:b_len])
		res.len = b_len
		return res
	}

	return res
}

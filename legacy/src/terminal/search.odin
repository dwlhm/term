package termgrid

import "core:unicode"

Search_Match :: struct {
	row:       int,
	col_start: int,
	col_end:   int,
}

// terminal_search scans the combined document (scrollback + live grid) for query matches,
// writing found intervals into out_matches and returning the total number of matches found.
terminal_search :: proc(t: ^Terminal, query: string, out_matches: []Search_Match) -> int {
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

	total_rows := scrollback_len(&t.scrollback) + t.grid.row_count
	count := 0

	row_runes: [1024]rune
	row_cols: [1024]int

	cols := min(t.grid.col_count, 1024)

	for r in 0 ..< total_rows {
		row_len := 0
		for c in 0 ..< cols {
			cell := terminal_view_get_document_cell(t, Terminal_Point{row = r, col = c})
			if u8(cell.flags) & u8(Cell_Flags.Wide_Continuation) != 0 {
				continue
			}
			ch: rune = ' '
			if cell.content != 0 {
				if content_is_grapheme(cell.content) {
					ch = grapheme_resolve_base(cell.content, &t.grapheme_store)
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
				end_cell := terminal_view_get_document_cell(t, Terminal_Point{row = r, col = c_end})
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

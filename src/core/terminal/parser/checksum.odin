package terminal_parser

// DECRQCRA (`CSI Pid ; Pp ; Pt ; Pl ; Pb ; Pr * y`) - Request Checksum of Rectangular Area.
// Standard DEC VT420/VT520 specification: the terminal returns `DCS Pid ! ~ <4 hex digits> ST`
// containing the 16-bit sum of the character codes within the requested rectangle.
// Follows DEC specification: 1-based inclusive corners, coordinate clipping to page
// boundaries, and origin-relative offsets when DECOM is active.

import "core:fmt"
import egc "../egc"
import grid "../grid"

// _checksum_cell_code returns the code point a cell contributes to the sum.
// Continuation cells of wide glyphs contribute 0; extended grapheme clusters
// contribute their base code point; empty cells contribute ASCII space (0x20).
_checksum_cell_code :: proc(p: ^Parser, g: ^grid.Grid, row, col: int) -> int {
	c := grid.grid_get_cell(g, row, col)
	if .Wide_Continuation in c.flags do return 0

	ch := c.char
	if .Has_Egc in c.flags {
		if runes := egc.egc_pool_get(p.egc_pool, int(ch - egc.EGC_INDEX_BASE)); len(runes) > 0 {
			ch = runes[0]
		}
	}
	if ch == 0 do ch = ' '
	return int(ch)
}

// _checksum_rect_bounds resolves the requested 1-based rectangle into 0-based
// inclusive grid coordinates clipped to the addressable page bounds.
// Returns valid = false if the rectangle is empty or outside page bounds.
_checksum_rect_bounds :: proc(p: ^Parser, g: ^grid.Grid) -> (r0, r1, c0, c1: int, valid: bool) {
	row_base := 0
	page_height := g.row_count
	if p.origin_mode {
		row_base = p.scroll_top
		page_height = max(1, p.scroll_bottom - p.scroll_top + 1)
	}
	page_width := g.col_count

	top := p.csi_params[2] if p.csi_count > 2 && p.csi_params[2] > 0 else 1
	left := p.csi_params[3] if p.csi_count > 3 && p.csi_params[3] > 0 else 1
	bottom := p.csi_params[4] if p.csi_count > 4 && p.csi_params[4] > 0 else page_height
	right := p.csi_params[5] if p.csi_count > 5 && p.csi_params[5] > 0 else page_width

	if top > bottom || left > right do return 0, 0, 0, 0, false
	if top > page_height || left > page_width || bottom < 1 || right < 1 do return 0, 0, 0, 0, false

	t := clamp(top, 1, page_height)
	b := clamp(bottom, 1, page_height)
	l := clamp(left, 1, page_width)
	r := clamp(right, 1, page_width)

	r0 = row_base + t - 1
	r1 = row_base + b - 1
	c0 = l - 1
	c1 = r - 1
	return r0, r1, c0, c1, true
}

_parser_report_checksum :: proc(p: ^Parser, g: ^grid.Grid) {
	pid := p.csi_params[0] if p.csi_count > 0 else 0

	sum := 0
	if r0, r1, c0, c1, ok := _checksum_rect_bounds(p, g); ok {
		for row in r0 ..= r1 {
			for col in c0 ..= c1 {
				sum += _checksum_cell_code(p, g, row, col)
			}
		}
	}

	buf: [32]u8
	resp := fmt.bprintf(buf[:], "\x1bP%d!~%04X\x1b\\", pid, sum & 0xFFFF)
	parser_emit_response(p, transmute([]u8)resp)
}

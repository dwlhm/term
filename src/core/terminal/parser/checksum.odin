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

_parser_report_checksum :: proc(p: ^Parser, g: ^grid.Grid) {
	pid := p.csi_params[0] if p.csi_count > 0 else 0

	sum := 0
	if r0, r1, c0, c1, ok := _parser_rect_bounds(p, g, 2); ok {
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

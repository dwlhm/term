package core_terminal

import "core:strconv"
import "core:unicode/utf8"
import cell "cell"
import extension "extension"

// Paint_Pen is the SGR + OSC 8 state the paint stream has put into effect, so a
// run of equally styled cells costs one SGR sequence instead of one per cell.
Paint_Pen :: struct {
	fg, bg: u8,
	style:  cell.Style_Flags,
	dc:     cell.Direct_Color, // has_fg/has_bg/rgb only; link_id lives in `link`
	link:   u16,
}

PAINT_PEN_DEFAULT :: Paint_Pen{fg = 7, bg = 0}

_paint_str :: proc(out: ^[dynamic]u8, s: string) {
	append(out, s)
}

_paint_int :: proc(out: ^[dynamic]u8, v: int) {
	buf: [24]u8
	append(out, strconv.write_int(buf[:], i64(v), 10))
}

_paint_rune :: proc(out: ^[dynamic]u8, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append(out, ..bytes[:n])
}

// _paint_csi_int writes `CSI <prefix><v><final>`, e.g. ("?", 1049, "h").
_paint_csi_int :: proc(out: ^[dynamic]u8, prefix: string, v: int, final: string) {
	_paint_str(out, "\x1b[")
	_paint_str(out, prefix)
	_paint_int(out, v)
	_paint_str(out, final)
}

_paint_dec_mode :: proc(out: ^[dynamic]u8, mode: int, on: bool) {
	_paint_csi_int(out, "?", mode, "h" if on else "l")
}

// _paint_cup moves to a 1-based row/column.
_paint_cup :: proc(out: ^[dynamic]u8, row, col: int) {
	_paint_csi_int(out, "", row, ";")
	_paint_int(out, col)
	_paint_str(out, "H")
}

_paint_pen_of_cell :: proc(c: cell.Semantic_Cell, dc: cell.Direct_Color) -> Paint_Pen {
	pen := Paint_Pen{fg = c.fg, bg = c.bg, style = c.style}
	if .Has_Direct_Color in c.flags {
		pen.dc = cell.Direct_Color{fg = dc.fg, bg = dc.bg, has_fg = dc.has_fg, has_bg = dc.has_bg}
	}
	if .Has_Underline_Decor in c.flags {
		pen.dc.underline_style = dc.underline_style
		pen.dc.underline = dc.underline
	}
	if .Has_Hyperlink in c.flags do pen.link = dc.link_id
	return pen
}

// _paint_set_pen emits the SGR and OSC 8 changes needed to go from `cur` to `want`.
_paint_set_pen :: proc(t: ^Terminal, out: ^[dynamic]u8, cur: ^Paint_Pen, want: Paint_Pen) {
	if cur.fg != want.fg || cur.bg != want.bg || cur.style != want.style || cur.dc != want.dc {
		_paint_sgr(out, want)
	}
	if cur.link != want.link {
		_paint_str(out, "\x1b]8;;")
		_paint_str(out, extension.hyperlinks_uri(&t.hyperlinks, want.link))
		_paint_str(out, "\x1b\\")
	}
	cur^ = want
}

@(rodata)
SGR_STYLE_CODES := [cell.Style_Flag]int {
	.Bold      = 1,
	.Dim       = 2,
	.Italic    = 3,
	.Underline = 4,
	.Invert    = 7,
	.Strike    = 9,
	.Blink     = 5,
	.Hidden    = 8,
}

// _paint_sgr writes a complete SGR that starts from reset, so it never depends
// on what the receiving terminal had in effect.
_paint_sgr :: proc(out: ^[dynamic]u8, pen: Paint_Pen) {
	_paint_str(out, "\x1b[0")
	for flag in cell.Style_Flag {
		if flag not_in pen.style || flag == .Underline do continue
		_paint_str(out, ";")
		_paint_int(out, SGR_STYLE_CODES[flag])
	}
	if .Underline in pen.style do _paint_sgr_underline_style(out, pen.dc.underline_style)
	_paint_sgr_color(out, pen.dc.has_fg, pen.dc.fg, pen.fg, 7, 30, 90, "38")
	_paint_sgr_color(out, pen.dc.has_bg, pen.dc.bg, pen.bg, 0, 40, 100, "48")
	_paint_sgr_underline_color(out, pen)
	_paint_str(out, "m")
}

// _paint_sgr_underline_style emits `4` for a single underline and `4:n` for
// every other shape, which is the form the parser understands on the other side.
_paint_sgr_underline_style :: proc(out: ^[dynamic]u8, style: cell.Underline_Style) {
	_paint_str(out, ";4")
	if style == .None || style == .Single do return
	_paint_str(out, ":")
	_paint_int(out, int(style))
}

// _paint_sgr_underline_color emits SGR 58/59. Each SGR starts from reset, so a
// default underline colour only needs the explicit reset when an underline is
// actually being drawn.
_paint_sgr_underline_color :: proc(out: ^[dynamic]u8, pen: Paint_Pen) {
	switch pen.dc.underline.mode {
	case .Rgb:
		_paint_str(out, ";58:2::")
		_paint_int(out, int(pen.dc.underline.rgb[0]))
		_paint_str(out, ":")
		_paint_int(out, int(pen.dc.underline.rgb[1]))
		_paint_str(out, ":")
		_paint_int(out, int(pen.dc.underline.rgb[2]))
	case .Palette:
		_paint_str(out, ";58;5;")
		_paint_int(out, int(pen.dc.underline.index))
	case .Default:
		if .Underline in pen.style do _paint_str(out, ";59")
	}
}

_paint_sgr_color :: proc(out: ^[dynamic]u8, has_rgb: bool, rgb: [3]u8, idx, default_idx: u8, base, bright_base: int, ext: string) {
	_paint_str(out, ";")
	switch {
	case has_rgb:
		_paint_str(out, ext)
		_paint_str(out, ";2")
		for v in rgb {
			_paint_str(out, ";")
			_paint_int(out, int(v))
		}
	case idx == default_idx:
		_paint_int(out, base + 9)
	case idx < 8:
		_paint_int(out, base + int(idx))
	case idx < 16:
		_paint_int(out, bright_base + int(idx) - 8)
	case:
		_paint_str(out, ext)
		_paint_str(out, ";5;")
		_paint_int(out, int(idx))
	}
}

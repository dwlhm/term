package feature_automation

// Generic inference: what a screen shows, from how terminal UIs draw it —
// boxes, brackets, highlights, bars. Nothing here knows a program by name;
// adapters refine it for one. Everything found is source .Inferred.

import ipc "../../platform/ipc"

// infer finds panels first: controls and lists are placed in them.
infer :: proc(s: ^Screen, out: ^[dynamic]Element) {
	infer_panels(s, out)
	panels := len(out)
	infer_controls(s, out, panels)
	infer_lists(s, out, panels)
	infer_bars(s, out, panels)
	infer_cursor_input(s, out, panels)
}

STYLE_INVERSE :: u8(1 << 4)

// bg_key: a cell's effective background (inverse swaps it with the
// foreground), comparable across palette and RGB colours.
bg_key :: proc(st: ipc.Snap_Style) -> u32 {
	if st.style & STYLE_INVERSE != 0 do return _color_key(st.fg, st.has_fg_rgb, st.fg_rgb)
	return _color_key(st.bg, st.has_bg_rgb, st.bg_rgb)
}

@(private = "file")
_color_key :: proc(index: u8, has_rgb: bool, rgb: [3]u8) -> u32 {
	if has_rgb do return 0x0100_0000 | u32(rgb[0]) << 16 | u32(rgb[1]) << 8 | u32(rgb[2])
	return u32(index)
}

// dominant_bg: the most common background in box.
dominant_bg :: proc(s: ^Screen, b: Box) -> u32 {
	counts := make(map[u32]int, 16, context.temp_allocator)
	best, most := u32(0), -1
	for r in b.row ..< b.row + b.height do for c in b.col ..< b.col + b.width {
		cell := screen_cell(s, r, c)
		if cell == nil do continue
		k := bg_key(cell.style)
		counts[k] += 1
		if counts[k] > most do best, most = k, counts[k]
	}
	return best
}

// container: the innermost panel or dialog (among es[:panels]) holding a cell,
// and the box inside its border (the whole screen when none).
container :: proc(s: ^Screen, es: []Element, row, col: int) -> (index: int, inner: Box) {
	index, inner = -1, Box{0, 0, s.cols, s.rows}
	area := max(int)
	for e, i in es {
		b := e.box
		if !box_has({b.row + 1, b.col + 1, b.width - 2, b.height - 2}, row, col) do continue
		if a := b.width * b.height; a < area {
			index, area = i, a
			inner = {b.row + 1, b.col + 1, b.width - 2, b.height - 2}
		}
	}
	return
}

// luminance of a background key, 0..255 (xterm's 256-colour palette).
luminance :: proc(key: u32) -> int {
	r, g, b: int
	switch {
	case key & 0x0100_0000 != 0:
		r, g, b = int(key >> 16 & 0xFF), int(key >> 8 & 0xFF), int(key & 0xFF)
	case key < 16:
		base := [16][3]int{{0, 0, 0}, {205, 0, 0}, {0, 205, 0}, {205, 205, 0}, {0, 0, 238}, {205, 0, 205}, {0, 205, 205}, {229, 229, 229},
			{127, 127, 127}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0}, {92, 92, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255}}
		c := base[key]
		r, g, b = c[0], c[1], c[2]
	case key < 232:
		i := int(key) - 16
		steps := [6]int{0, 95, 135, 175, 215, 255}
		r, g, b = steps[i / 36], steps[i / 6 % 6], steps[i % 6]
	case:
		v := 8 + (int(key) - 232) * 10
		r, g, b = v, v, v
	}
	return (r * 299 + g * 587 + b * 114) / 1000
}

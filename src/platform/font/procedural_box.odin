package platform_font

// Procedural Box Drawing (Unicode U+2500 - U+257F)
// Ensures 100% full-bleed cell connectivity without 1px font-metric gaps.

import "core:math"

// 4 nibbles: (up << 12) | (down << 8) | (left << 4) | right
// 0: None, 1: Light, 2: Heavy, 3: Double
// Special tags: 0xDxxx = Dash, 0xExxx = Diagonal, 0xFxxx = Arc
@(rodata)
BOX_ARMS := [128]u16{
	0x0011, 0x0022, 0x1100, 0x2200, 0xD004, 0xD005, 0xD006, 0xD007,
	0xD008, 0xD009, 0xD00A, 0xD00B, 0x0101, 0x0102, 0x0201, 0x0202,
	0x0110, 0x0120, 0x0210, 0x0220, 0x1001, 0x1002, 0x2001, 0x2002,
	0x1010, 0x1020, 0x2010, 0x2020, 0x1101, 0x1102, 0x2101, 0x1201,
	0x2201, 0x2102, 0x1202, 0x2202, 0x1110, 0x1120, 0x2110, 0x1210,
	0x2210, 0x2120, 0x1220, 0x2220, 0x0111, 0x0121, 0x0112, 0x0122,
	0x0211, 0x0221, 0x0212, 0x0222, 0x1011, 0x1021, 0x1012, 0x1022,
	0x2011, 0x2021, 0x2012, 0x2022, 0x1111, 0x1121, 0x1112, 0x1122,
	0x2111, 0x1211, 0x2211, 0x2121, 0x2112, 0x1221, 0x1212, 0x2122,
	0x1222, 0x2221, 0x2212, 0x2222, 0xD04C, 0xD04D, 0xD04E, 0xD04F,
	0x0033, 0x3300, 0x0103, 0x0301, 0x0303, 0x0130, 0x0310, 0x0330,
	0x1003, 0x3001, 0x3003, 0x1030, 0x3010, 0x3030, 0x1103, 0x3301,
	0x3303, 0x1130, 0x3310, 0x3330, 0x0133, 0x0311, 0x0333, 0x1033,
	0x3011, 0x3033, 0x1133, 0x3311, 0x3333, 0xF000, 0xF001, 0xF002,
	0xF003, 0xE000, 0xE001, 0xE002, 0x0010, 0x1000, 0x0001, 0x0100,
	0x0020, 0x2000, 0x0002, 0x0200, 0x0012, 0x1200, 0x0021, 0x2100,
}

draw_procedural_box :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h: int, cp: u32) {
	if cp < 0x2500 || cp > 0x257F || cell_w <= 0 || cell_h <= 0 do return
	spec := BOX_ARMS[cp - 0x2500]

	mid_x := px + cell_w / 2
	mid_y := py + cell_h / 2
	light_w := max(1, int(math.round(f32(cell_w) * 0.10)))
	heavy_w := max(light_w + 1, light_w * 2)

	if (spec & 0xF000) == 0xF000 {
		_draw_box_arc(pixels, pitch, px, py, cell_w, cell_h, mid_x, mid_y, light_w, cp)
		return
	}
	if (spec & 0xF000) == 0xE000 {
		_draw_box_diag(pixels, pitch, px, py, cell_w, cell_h, light_w, cp)
		return
	}
	if (spec & 0xF000) == 0xD000 {
		_draw_box_dash(pixels, pitch, px, py, cell_w, cell_h, mid_x, mid_y, light_w, heavy_w, cp)
		return
	}

	u := int((spec >> 12) & 0xF)
	d := int((spec >> 8) & 0xF)
	l := int((spec >> 4) & 0xF)
	r := int(spec & 0xF)
	_draw_box_arms(pixels, pitch, px, py, cell_w, cell_h, mid_x, mid_y, light_w, heavy_w, u, d, l, r)
}

@(private = "file")
_fill_rect :: #force_inline proc(pixels: []u8, pitch, x0, y0, x1, y1: int, val: u8 = 255) {
	for y in y0..<y1 {
		row_off := y * pitch
		for x in x0..<x1 {
			idx := row_off + x
			if idx >= 0 && idx < len(pixels) {
				pixels[idx] = val
			}
		}
	}
}

@(private = "file")
_draw_box_arms :: proc(
	pixels: []u8, pitch, px, py, cell_w, cell_h, mid_x, mid_y, light_w, heavy_w: int,
	u, d, l, r: int,
) {
	// Vertical single arms
	v_w := light_w if (u == 1 || d == 1) else (heavy_w if (u == 2 || d == 2) else 0)
	vx0 := mid_x - v_w / 2
	vx1 := vx0 + v_w

	// Horizontal single arms
	h_w := light_w if (l == 1 || r == 1) else (heavy_w if (l == 2 || r == 2) else 0)
	hy0 := mid_y - h_w / 2
	hy1 := hy0 + h_w

	if u == 1 || u == 2 do _fill_rect(pixels, pitch, vx0, py, vx1, mid_y + 1)
	if d == 1 || d == 2 do _fill_rect(pixels, pitch, vx0, mid_y, vx1, py + cell_h)
	if l == 1 || l == 2 do _fill_rect(pixels, pitch, px, hy0, mid_x + 1, hy1)
	if r == 1 || r == 2 do _fill_rect(pixels, pitch, mid_x, hy0, px + cell_w, hy1)

	// Double line arms (centered with visible gap)
	sep := max(2, light_w)
	x_left := mid_x - sep / 2 - light_w
	x_right := mid_x + sep / 2
	y_top := mid_y - sep / 2 - light_w
	y_bot := mid_y + sep / 2

	if u == 3 {
		_fill_rect(pixels, pitch, x_left, py, x_left + light_w, mid_y + 1)
		_fill_rect(pixels, pitch, x_right, py, x_right + light_w, mid_y + 1)
	}
	if d == 3 {
		_fill_rect(pixels, pitch, x_left, mid_y, x_left + light_w, py + cell_h)
		_fill_rect(pixels, pitch, x_right, mid_y, x_right + light_w, py + cell_h)
	}
	if l == 3 {
		_fill_rect(pixels, pitch, px, y_top, mid_x + 1, y_top + light_w)
		_fill_rect(pixels, pitch, px, y_bot, mid_x + 1, y_bot + light_w)
	}
	if r == 3 {
		_fill_rect(pixels, pitch, mid_x, y_top, px + cell_w, y_top + light_w)
		_fill_rect(pixels, pitch, mid_x, y_bot, px + cell_w, y_bot + light_w)
	}

	// Center junction fill
	if (u > 0 || d > 0) && (l > 0 || r > 0) {
		cx0 := min(vx0 if v_w > 0 else x_left, px + cell_w)
		cx1 := max(vx1 if v_w > 0 else x_right + light_w, px)
		cy0 := min(hy0 if h_w > 0 else y_top, py + cell_h)
		cy1 := max(hy1 if h_w > 0 else y_bot + light_w, py)
		_fill_rect(pixels, pitch, cx0, cy0, cx1, cy1)
	}
}

@(private = "file")
_draw_box_arc :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h, mid_x, mid_y, lw: int, cp: u32) {
	vx0 := mid_x - lw / 2
	vx1 := vx0 + lw
	hy0 := mid_y - lw / 2
	hy1 := hy0 + lw

	vx_center := f32(vx0) + f32(lw) * 0.5
	hy_center := f32(hy0) + f32(lw) * 0.5

	radius := max(2.0, f32(min(cell_w - (mid_x - px), cell_h - (mid_y - py))) * 0.65)
	stroke_w := f32(lw)

	cx: f32 = 0.0
	cy: f32 = 0.0
	quadrant_x := 0
	quadrant_y := 0

	switch cp {
	case 0x256D: // ╭ Down & Right
		cx = vx_center + radius
		cy = hy_center + radius
		quadrant_x = -1
		quadrant_y = -1
		_fill_rect(pixels, pitch, vx0, int(math.round(cy)), vx1, py + cell_h)
		_fill_rect(pixels, pitch, int(math.round(cx)), hy0, px + cell_w, hy1)
	case 0x256E: // ╮ Down & Left
		cx = vx_center - radius
		cy = hy_center + radius
		quadrant_x = 1
		quadrant_y = -1
		_fill_rect(pixels, pitch, vx0, int(math.round(cy)), vx1, py + cell_h)
		_fill_rect(pixels, pitch, px, hy0, int(math.round(cx)) + 1, hy1)
	case 0x256F: // ╯ Up & Left
		cx = vx_center - radius
		cy = hy_center - radius
		quadrant_x = 1
		quadrant_y = 1
		_fill_rect(pixels, pitch, vx0, py, vx1, int(math.round(cy)) + 1)
		_fill_rect(pixels, pitch, px, hy0, int(math.round(cx)) + 1, hy1)
	case 0x2570: // ╰ Up & Right
		cx = vx_center + radius
		cy = hy_center - radius
		quadrant_x = -1
		quadrant_y = 1
		_fill_rect(pixels, pitch, vx0, py, vx1, int(math.round(cy)) + 1)
		_fill_rect(pixels, pitch, int(math.round(cx)), hy0, px + cell_w, hy1)
	}

	for y in py..<py + cell_h {
		fy := f32(y) + 0.5
		if (quadrant_y < 0 && fy > cy) || (quadrant_y > 0 && fy < cy) do continue
		row_off := y * pitch
		for x in px..<px + cell_w {
			fx := f32(x) + 0.5
			if (quadrant_x < 0 && fx > cx) || (quadrant_x > 0 && fx < cx) do continue
			r := math.hypot(fx - cx, fy - cy)
			d := math.abs(r - radius)
			dist_from_edge := d - stroke_w * 0.5
			cov := clamp(int((0.5 - dist_from_edge) * 255.0), 0, 255)
			if cov > 0 {
				idx := row_off + x
				if idx >= 0 && idx < len(pixels) {
					pixels[idx] = max(pixels[idx], u8(cov))
				}
			}
		}
	}
}

@(private = "file")
_draw_box_diag :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h, lw: int, cp: u32) {
	for y in py..<py + cell_h {
		rel_y := f32(y - py) / f32(cell_h)
		row_off := y * pitch
		for x in px..<px + cell_w {
			rel_x := f32(x - px) / f32(cell_w)
			idx := row_off + x
			if idx < 0 || idx >= len(pixels) do continue
			// 0x2571: ╱ (UR to LL), 0x2572: ╲ (UL to LR), 0x2573: ╳
			if (cp == 0x2571 || cp == 0x2573) && math.abs(rel_x + rel_y - 1.0) < 0.10 {
				pixels[idx] = 255
			}
			if (cp == 0x2572 || cp == 0x2573) && math.abs(rel_x - rel_y) < 0.10 {
				pixels[idx] = 255
			}
		}
	}
}

@(private = "file")
_draw_box_dash :: proc(
	pixels: []u8, pitch, px, py, cell_w, cell_h, mid_x, mid_y, light_w, heavy_w: int,
	cp: u32,
) {
	w := heavy_w if (cp == 0x2505 || cp == 0x2507 || cp == 0x2509 || cp == 0x250B || cp == 0x254D || cp == 0x254F) else light_w
	is_vert := (cp == 0x2506 || cp == 0x2507 || cp == 0x250A || cp == 0x250B || cp == 0x254E || cp == 0x254F)
	count := 3 if (cp >= 0x2504 && cp <= 0x2507) else (4 if (cp >= 0x2508 && cp <= 0x250B) else 2)

	if is_vert {
		vx0 := mid_x - w / 2
		seg_len := f32(cell_h) / f32(count * 2)
		for i in 0..<count {
			sy0 := py + int(f32(i * 2) * seg_len)
			sy1 := sy0 + int(seg_len)
			_fill_rect(pixels, pitch, vx0, sy0, vx0 + w, sy1)
		}
	} else {
		hy0 := mid_y - w / 2
		seg_len := f32(cell_w) / f32(count * 2)
		for i in 0..<count {
			sx0 := px + int(f32(i * 2) * seg_len)
			sx1 := sx0 + int(seg_len)
			_fill_rect(pixels, pitch, sx0, hy0, sx1, hy0 + w)
		}
	}
}

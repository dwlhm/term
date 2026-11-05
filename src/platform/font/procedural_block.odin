package platform_font

// Procedural Block Elements (Unicode U+2580 - U+259F)
// Ensures 100% full-bleed cell connectivity without 1px font-metric gaps.

import "core:math"

draw_procedural_block :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h: int, cp: u32) {
	if cp < 0x2580 || cp > 0x259F || cell_w <= 0 || cell_h <= 0 do return

	switch cp {
	case 0x2580: // Upper half block
		_fill_rect_b(pixels, pitch, px, py, px + cell_w, py + cell_h / 2)
	case 0x2581..=0x2587: // Lower 1/8 to 7/8
		fraction := int(cp - 0x2580)
		h := max(1, int(math.round(f32(cell_h) * f32(fraction) / 8.0)))
		_fill_rect_b(pixels, pitch, px, py + cell_h - h, px + cell_w, py + cell_h)
	case 0x2588: // Full block
		_fill_rect_b(pixels, pitch, px, py, px + cell_w, py + cell_h)
	case 0x2589..=0x258F: // Left 7/8 to 1/8
		fraction := 8 - int(cp - 0x2588)
		w := max(1, int(math.round(f32(cell_w) * f32(fraction) / 8.0)))
		_fill_rect_b(pixels, pitch, px, py, px + w, py + cell_h)
	case 0x2590: // Right half block
		_fill_rect_b(pixels, pitch, px + cell_w / 2, py, px + cell_w, py + cell_h)
	case 0x2591..=0x2593: // Shades
		_draw_shade_block(pixels, pitch, px, py, cell_w, cell_h, cp)
	case 0x2594: // Upper 1/8 block
		h := max(1, int(math.round(f32(cell_h) / 8.0)))
		_fill_rect_b(pixels, pitch, px, py, px + cell_w, py + h)
	case 0x2595: // Right 1/8 block
		w := max(1, int(math.round(f32(cell_w) / 8.0)))
		_fill_rect_b(pixels, pitch, px + cell_w - w, py, px + cell_w, py + cell_h)
	case 0x2596..=0x259F: // Quadrant blocks
		_draw_quadrant_block(pixels, pitch, px, py, cell_w, cell_h, cp)
	}
}

@(private = "file")
_fill_rect_b :: #force_inline proc(pixels: []u8, pitch, x0, y0, x1, y1: int, val: u8 = 255) {
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
_draw_shade_block :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h: int, cp: u32) {
	for y in py..<py + cell_h {
		row_off := y * pitch
		for x in px..<px + cell_w {
			hit := false
			rx := x - px
			ry := y - py
			switch cp {
			case 0x2591: // 25% Light Shade
				hit = ((rx % 2 == 0) && (ry % 2 == 0)) && ((rx / 2 + ry / 2) % 2 == 0)
			case 0x2592: // 50% Medium Shade
				hit = ((rx + ry) % 2 == 0)
			case 0x2593: // 75% Dark Shade
				hit = !(((rx % 2 == 0) && (ry % 2 == 0)) && ((rx / 2 + ry / 2) % 2 == 0))
			}
			if hit {
				idx := row_off + x
				if idx >= 0 && idx < len(pixels) {
					pixels[idx] = 255
				}
			}
		}
	}
}

@(private = "file")
_draw_quadrant_block :: proc(pixels: []u8, pitch, px, py, cell_w, cell_h: int, cp: u32) {
	half_w := cell_w / 2
	half_h := cell_h / 2

	ul := false
	ur := false
	ll := false
	lr := false

	switch cp {
	case 0x2596: ll = true                                   // ▖
	case 0x2597: lr = true                                   // ▗
	case 0x2598: ul = true                                   // ▘
	case 0x2599: ul = true; ll = true; lr = true             // ▙
	case 0x259A: ul = true; lr = true                         // ▚
	case 0x259B: ul = true; ur = true; ll = true             // ▛
	case 0x259C: ul = true; ur = true; lr = true             // ▜
	case 0x259D: ur = true                                   // ▝
	case 0x259E: ur = true; ll = true                         // ▞
	case 0x259F: ur = true; ll = true; lr = true             // ▟
	}

	if ul do _fill_rect_b(pixels, pitch, px, py, px + half_w, py + half_h)
	if ur do _fill_rect_b(pixels, pitch, px + half_w, py, px + cell_w, py + half_h)
	if ll do _fill_rect_b(pixels, pitch, px, py + half_h, px + half_w, py + cell_h)
	if lr do _fill_rect_b(pixels, pitch, px + half_w, py + half_h, px + cell_w, py + cell_h)
}

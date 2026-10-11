package contract

// Hardware Surface Damage & Scissor Region Math.
// Part of core_render: Tier 1 Autonomous Core Primitives.
//
// Invariant: ZERO Horizontal Dependencies.
// This package depends ONLY on `base:runtime`. It never imports sibling cores
// or feature slices.

import "base:runtime"

Damage_Rect :: struct {
	x, y, w, h: u32,
}

damage_rect_make :: proc(x, y, w, h: u32) -> Damage_Rect {
	return Damage_Rect{x = x, y = y, w = w, h = h}
}

damage_rect_is_empty :: proc(r: Damage_Rect) -> bool {
	return r.w == 0 || r.h == 0
}

damage_rect_union :: proc(a, b: Damage_Rect) -> Damage_Rect {
	a_empty := damage_rect_is_empty(a)
	b_empty := damage_rect_is_empty(b)

	if a_empty && b_empty {
		return Damage_Rect{}
	}
	if a_empty {
		return b
	}
	if b_empty {
		return a
	}

	max_u := ~u32(0)

	ax1 := max_u if max_u - a.x < a.w else a.x + a.w
	ay1 := max_u if max_u - a.y < a.h else a.y + a.h
	bx1 := max_u if max_u - b.x < b.w else b.x + b.w
	by1 := max_u if max_u - b.y < b.h else b.y + b.h

	x0 := min(a.x, b.x)
	y0 := min(a.y, b.y)
	x1 := max(ax1, bx1)
	y1 := max(ay1, by1)

	return Damage_Rect{
		x = x0,
		y = y0,
		w = x1 - x0,
		h = y1 - y0,
	}
}

damage_rect_expand :: proc(r: Damage_Rect, pad: u32, max_w, max_h: u32) -> Damage_Rect {
	if damage_rect_is_empty(r) || max_w == 0 || max_h == 0 || r.x >= max_w || r.y >= max_h {
		return Damage_Rect{}
	}

	x0 := r.x - pad if r.x >= pad else 0
	y0 := r.y - pad if r.y >= pad else 0

	max_u := ~u32(0)

	x1_val := r.x
	x1_val = max_u if max_u - x1_val < r.w else x1_val + r.w
	x1_val = max_u if max_u - x1_val < pad else x1_val + pad
	x1 := min(x1_val, max_w)

	y1_val := r.y
	y1_val = max_u if max_u - y1_val < r.h else y1_val + r.h
	y1_val = max_u if max_u - y1_val < pad else y1_val + pad
	y1 := min(y1_val, max_h)

	if x0 >= x1 || y0 >= y1 {
		return Damage_Rect{}
	}

	return Damage_Rect{
		x = x0,
		y = y0,
		w = x1 - x0,
		h = y1 - y0,
	}
}

damage_rect_is_full :: proc(r: Damage_Rect, max_w, max_h: u32) -> bool {
	return r.x == 0 && r.y == 0 && r.w >= max_w && r.h >= max_h
}

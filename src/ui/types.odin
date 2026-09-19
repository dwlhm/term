package ui

// Rect_f32 defines a 2D floating-point rectangle.
Rect_f32 :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

// point_in_rect performs an half-open bounding box check for (x, y) within r.
point_in_rect :: #force_inline proc(x, y: f32, r: Rect_f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

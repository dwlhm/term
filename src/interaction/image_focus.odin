package interaction

import graphics "../graphics"

IMAGE_FOCUS_DEFAULT_ZOOM: f32 : 1.0
IMAGE_FOCUS_MIN_ZOOM: f32 : 0.5
IMAGE_FOCUS_MAX_ZOOM: f32 : 8.0
IMAGE_FOCUS_ZOOM_STEP: f32 : 1.25
IMAGE_FOCUS_KEY_PAN_STEP: f32 : 32.0
IMAGE_FOCUS_MAX_PAN: f32 : 1000000.0

Image_Focus_State :: struct {
	active:     bool,
	namespace:  u64,
	image_id:   u32,
	generation: u64,
	zoom:       f32,
	pan_x:      f32,
	pan_y:      f32,
}

Image_Focus_Hit :: struct {
	image_id:   u32,
	generation: u64,
	placement:  graphics.Placement,
}

image_focus_clamp_zoom :: proc(zoom: f32) -> f32 {
	return clamp(zoom, IMAGE_FOCUS_MIN_ZOOM, IMAGE_FOCUS_MAX_ZOOM)
}

image_focus_clamp_pan :: proc(pan_x, pan_y, max_x, max_y: f32) -> (f32, f32) {
	return clamp(pan_x, -max(0, max_x), max(0, max_x)), clamp(pan_y, -max(0, max_y), max(0, max_y))
}

image_focus_init :: proc(s: ^Image_Focus_State) {
	if s == nil do return
	s^ = Image_Focus_State{zoom = IMAGE_FOCUS_DEFAULT_ZOOM}
}

image_focus_open :: proc(s: ^Image_Focus_State, namespace: u64, image_id: u32, generation: u64) {
	if s == nil || namespace == 0 || image_id == 0 || generation == 0 do return
	s.active = true
	s.namespace = namespace
	s.image_id = image_id
	s.generation = generation
	s.zoom = IMAGE_FOCUS_DEFAULT_ZOOM
	s.pan_x = 0
	s.pan_y = 0
}

image_focus_close :: proc(s: ^Image_Focus_State) {
	if s == nil do return
	s.active = false
	s.namespace = 0
	s.image_id = 0
	s.generation = 0
	s.zoom = IMAGE_FOCUS_DEFAULT_ZOOM
	s.pan_x = 0
	s.pan_y = 0
}

image_focus_zoom :: proc(s: ^Image_Focus_State, direction: int) -> bool {
	if s == nil || !s.active || direction == 0 do return false
	before := s.zoom
	if direction > 0 {
		s.zoom = image_focus_clamp_zoom(s.zoom * IMAGE_FOCUS_ZOOM_STEP)
	} else {
		s.zoom = image_focus_clamp_zoom(s.zoom / IMAGE_FOCUS_ZOOM_STEP)
	}
	return before != s.zoom
}

image_focus_pan :: proc(s: ^Image_Focus_State, dx, dy: f32, max_x: f32 = IMAGE_FOCUS_MAX_PAN, max_y: f32 = IMAGE_FOCUS_MAX_PAN) -> bool {
	if s == nil || !s.active do return false
	before_x, before_y := s.pan_x, s.pan_y
	s.pan_x, s.pan_y = image_focus_clamp_pan(s.pan_x + dx, s.pan_y + dy, max_x, max_y)
	return before_x != s.pan_x || before_y != s.pan_y
}

// image_focus_clamp_for_view keeps the focused image reachable while allowing
// the render path to use the actual drawable dimensions. It mutates only a
// temporary state copy in the renderer; event dispatch remains screen-only.
image_focus_clamp_for_view :: proc(s: ^Image_Focus_State, viewport_w, viewport_h, image_w, image_h: f32) {
	if s == nil || viewport_w <= 0 || viewport_h <= 0 || image_w <= 0 || image_h <= 0 do return
	s.zoom = image_focus_clamp_zoom(s.zoom)
	base_scale := min(viewport_w / image_w, viewport_h / image_h)
	content_w := image_w * base_scale * s.zoom
	content_h := image_h * base_scale * s.zoom
	max_x := max(0, (content_w - viewport_w) * 0.5)
	max_y := max(0, (content_h - viewport_h) * 0.5)
	s.pan_x, s.pan_y = image_focus_clamp_pan(s.pan_x, s.pan_y, max_x, max_y)
}

// image_focus_rect returns the aspect-correct focused image rectangle in the
// full viewport. The caller must clamp the state for the same dimensions first.
image_focus_rect :: proc(s: Image_Focus_State, viewport_w, viewport_h, image_w, image_h: f32) -> (rect: [4]f32, ok: bool) {
	if viewport_w <= 0 || viewport_h <= 0 || image_w <= 0 || image_h <= 0 do return {}, false
	base_scale := min(viewport_w / image_w, viewport_h / image_h)
	width := image_w * base_scale * image_focus_clamp_zoom(s.zoom)
	height := image_h * base_scale * image_focus_clamp_zoom(s.zoom)
	return [4]f32{
		(viewport_w - width) * 0.5 + s.pan_x,
		(viewport_h - height) * 0.5 + s.pan_y,
		width,
		height,
	}, true
}

_image_focus_destination_rect :: proc(p: ^graphics.Placement, cell_w, cell_h: f32, frame_w, frame_h: int) -> (rect: [4]f32, ok: bool) {
	if p == nil || !p.used || cell_w <= 0 || cell_h <= 0 || frame_w <= 0 || frame_h <= 0 do return {}, false
	if p.src_x >= u32(frame_w) || p.src_y >= u32(frame_h) || p.src_w == 0 || p.src_h == 0 do return {}, false
	src_w := min(p.src_w, u32(frame_w) - p.src_x)
	src_h := min(p.src_h, u32(frame_h) - p.src_y)
	if src_w == 0 || src_h == 0 do return {}, false
	width, height: f32
	if p.cols > 0 do width = f32(p.cols) * cell_w
	if p.rows > 0 do height = f32(p.rows) * cell_h
	if width <= 0 && height <= 0 {
		width, height = f32(src_w), f32(src_h)
	} else if width <= 0 {
		width = height * f32(src_w) / f32(src_h)
	} else if height <= 0 {
		height = width * f32(src_h) / f32(src_w)
	}
	if width <= 0 || height <= 0 do return {}, false
	return [4]f32{f32(p.col) * cell_w + f32(p.cell_x), f32(p.row) * cell_h + f32(p.cell_y), width, height}, true
}

// interaction_hit_test_image selects the frontmost rendered placement. The
// ordering matches TG3's renderer ordering: highest z wins, followed by the
// largest image and placement ids for a stable overlap tie-break.
interaction_hit_test_image :: proc(store: ^graphics.Store, x, y, cell_w, cell_h: f32) -> (hit: Image_Focus_Hit, ok: bool) {
	if store == nil || cell_w <= 0 || cell_h <= 0 do return {}, false
	best_z: i32 = 0
	best_image, best_placement: u32 = 0, 0
	found := false
	for i := 0; i < len(store.placements); i += 1 {
		p := &store.placements[i]
		if !p.used do continue
		image := graphics.store_find_image(store, p.image_id, p.image_number)
		if image == nil || !image.used || image.generation == 0 || image.frame_count <= 0 || image.current_frame < 0 || image.current_frame >= image.frame_count do continue
		frame := &image.frames[image.current_frame]
		rect, rect_ok := _image_focus_destination_rect(p, cell_w, cell_h, frame.width, frame.height)
		if !rect_ok || x < rect[0] || y < rect[1] || x >= rect[0] + rect[2] || y >= rect[1] + rect[3] do continue
		if !found || p.z > best_z || (p.z == best_z && (image.id > best_image || (image.id == best_image && p.placement_id > best_placement))) {
			found = true
			best_z = p.z
			best_image = image.id
			best_placement = p.placement_id
			hit = Image_Focus_Hit{image_id = image.id, generation = image.generation, placement = p^}
		}
	}
	return hit, found
}

package termgrid

SCROLLBAR_WIDTH :: 8.0 // pixels
MIN_THUMB_HEIGHT :: 20.0

Scrollbar :: struct {
	visible:           bool,
	track_rect:        [4]f32, // x, y, w, h
	thumb_rect:        [4]f32, // x, y, w, h
	total_lines:       int,
	visible_lines:     int,
	offset:            int,
	is_dragging:       bool,
	drag_start_y:      f32,
	drag_start_offset: int,
}

scrollbar_init :: proc(sb: ^Scrollbar) {
	if sb == nil do return
	sb^ = Scrollbar{}
}

scrollbar_update :: proc(sb: ^Scrollbar, total_lines, visible_lines, offset: int, viewport_w, viewport_h: f32) {
	if sb == nil do return
	sb.total_lines = total_lines
	sb.visible_lines = visible_lines
	max_offset := max(0, total_lines - visible_lines)
	sb.offset = clamp(offset, 0, max_offset)

	if total_lines <= visible_lines || visible_lines <= 0 || viewport_h <= 0 {
		sb.visible = false
		sb.track_rect = {}
		sb.thumb_rect = {}
		return
	}

	sb.visible = true
	sb.track_rect = [4]f32{viewport_w - SCROLLBAR_WIDTH, 0, SCROLLBAR_WIDTH, viewport_h}

	thumb_h := max(MIN_THUMB_HEIGHT, viewport_h * (f32(visible_lines) / f32(total_lines)))
	thumb_h = min(thumb_h, viewport_h)

	available_track := viewport_h - thumb_h
	ratio: f32 = 0
	if max_offset > 0 {
		ratio = f32(max_offset - sb.offset) / f32(max_offset)
	}
	thumb_y := sb.track_rect[1] + ratio * available_track
	sb.thumb_rect = [4]f32{sb.track_rect[0], thumb_y, SCROLLBAR_WIDTH, thumb_h}
}

scrollbar_hit_test :: proc(sb: ^Scrollbar, px, py: f32) -> (hit_thumb: bool, hit_track: bool) {
	if sb == nil || !sb.visible {
		return false, false
	}

	in_track := px >= sb.track_rect[0] && px < sb.track_rect[0] + sb.track_rect[2] &&
		py >= sb.track_rect[1] && py < sb.track_rect[1] + sb.track_rect[3]

	in_thumb := px >= sb.thumb_rect[0] && px < sb.thumb_rect[0] + sb.thumb_rect[2] &&
		py >= sb.thumb_rect[1] && py < sb.thumb_rect[1] + sb.thumb_rect[3]

	return in_thumb, in_track
}

scrollbar_drag :: proc(sb: ^Scrollbar, cur_y: f32) -> (new_offset: int) {
	if sb == nil || !sb.visible do return 0
	max_offset := max(0, sb.total_lines - sb.visible_lines)
	if max_offset <= 0 do return 0

	available_track := sb.track_rect[3] - sb.thumb_rect[3]
	if available_track <= 0 do return 0

	dy := cur_y - sb.drag_start_y
	offset_delta := int((dy / available_track) * f32(max_offset))
	new_offset = clamp(sb.drag_start_offset - offset_delta, 0, max_offset)
	return new_offset
}

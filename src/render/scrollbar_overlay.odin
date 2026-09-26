package render

import instance "instance"
import termgrid "../terminal"

// Semi-transparent / muted scrollbar colors
SCROLLBAR_TRACK_R: f32 : 0.15
SCROLLBAR_TRACK_G: f32 : 0.15
SCROLLBAR_TRACK_B: f32 : 0.18

SCROLLBAR_THUMB_R: f32 : 0.45
SCROLLBAR_THUMB_G: f32 : 0.45
SCROLLBAR_THUMB_B: f32 : 0.50

// scrollbar_overlay_draw stages track and thumb quads for the scrollbar
// into the renderer staging buffer when the scrollbar is visible (scrollback > 0).
scrollbar_overlay_draw :: proc(
	r: ^Renderer,
	sb: ^termgrid.Scrollbar,
) -> bool {
	if r == nil {
		return false
	}
	r.scrollbar_staged = false
	r.scrollbar_count = 0

	if sb == nil || !sb.visible || sb.total_lines <= sb.visible_lines {
		return false
	}

	// Track
	r.scrollbar_data[0] = instance.Instance_Data{
		x  = sb.track_rect[0],
		y  = sb.track_rect[1],
		cw = sb.track_rect[2],
		ch = sb.track_rect[3],
		u0 = 0, v0 = 0, u1 = 0, v1 = 0,
		r  = SCROLLBAR_TRACK_R,
		g  = SCROLLBAR_TRACK_G,
		b  = SCROLLBAR_TRACK_B,
		a  = 1.0,
	}

	// Thumb
	r.scrollbar_data[1] = instance.Instance_Data{
		x  = sb.thumb_rect[0],
		y  = sb.thumb_rect[1],
		cw = sb.thumb_rect[2],
		ch = sb.thumb_rect[3],
		u0 = 0, v0 = 0, u1 = 0, v1 = 0,
		r  = SCROLLBAR_THUMB_R,
		g  = SCROLLBAR_THUMB_G,
		b  = SCROLLBAR_THUMB_B,
		a  = 1.0,
	}

	r.scrollbar_count = 2
	r.scrollbar_staged = true
	return true
}

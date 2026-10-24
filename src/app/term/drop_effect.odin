package term

import "base:runtime"
import "core:math"
import chrome_dl "../../core/chrome/draw_list"

MAX_WATER_SPLASHES   :: 32
DROP_WAKE_SPACING    :: 55.0
DROP_WAKE_STRENGTH   :: 0.40
DROP_WAKE_LIFETIME   :: 1.6
DROP_IMPACT_STRENGTH :: 1.25
DROP_IMPACT_LIFETIME :: 2.4

Water_Splash_3D :: struct {
	x, y:     f32,
	time:     f32,
	max_t:    f32,
	strength: f32,
	active:   bool,
}

Drop_Effect_State :: struct {
	is_dragging:    bool,
	is_exiting:     bool,
	exit_fade_t:    f32,
	flush_frame:    bool,
	was_active:     bool,
	idle_time:      f32,
	hover_x:        f32,
	hover_y:        f32,
	target_rect:    [4]f32,
	anchor_valid:   bool,
	path_remainder: f32,
	impact_emitted: bool,
	next_splash:    int,
	splashes:       [MAX_WATER_SPLASHES]Water_Splash_3D,
}

@(private = "file")
_is_shell_special :: proc "contextless" (c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\\', '\'', '"', '(', ')', '[', ']', '{', '}', '*', '?', '&', ';', '|', '<', '>', '^', '$', '`', '!', '#', '~':
		return true
	}
	return false
}

escape_shell_path :: proc(path: string, allocator := context.allocator) -> string {
	if len(path) == 0 do return ""
	extra := 1
	for i in 0..<len(path) do if _is_shell_special(path[i]) do extra += 1
	b := make([]u8, len(path) + extra, allocator)
	out_idx := 0
	for i in 0..<len(path) {
		ch := path[i]
		if _is_shell_special(ch) {
			b[out_idx] = '\\'
			out_idx += 1
		}
		b[out_idx] = ch
		out_idx += 1
	}
	b[out_idx] = ' '
	return string(b)
}

drop_effect_init :: proc(state: ^Drop_Effect_State) {
	if state == nil do return
	state^ = {}
	state.exit_fade_t = 0.0
}

drop_effect_spawn :: proc(state: ^Drop_Effect_State, x, y, strength, lifetime: f32) {
	if state == nil do return
	idx := state.next_splash
	oldest: f32 = -1.0
	for step in 0..<MAX_WATER_SPLASHES {
		i := (state.next_splash + step) % MAX_WATER_SPLASHES
		w := state.splashes[i]
		if !w.active {
			idx = i
			break
		}
		age := w.time / w.max_t
		if age > oldest {
			oldest = age
			idx = i
		}
	}
	state.splashes[idx] = Water_Splash_3D{
		x        = x,
		y        = y,
		time     = 0.0,
		max_t    = lifetime,
		strength = strength,
		active   = true,
	}
	state.next_splash = (idx + 1) % MAX_WATER_SPLASHES
}

drop_effect_on_drag_begin :: proc(state: ^Drop_Effect_State) {
	if state == nil do return
	state.is_exiting = false
	state.exit_fade_t = 1.0
	state.flush_frame = false
	state.idle_time = 0.0
	state.anchor_valid = false
	state.path_remainder = 0.0
	state.impact_emitted = false
}

drop_effect_on_drag_pos :: proc(state: ^Drop_Effect_State, pos: [2]f32, pane_id: u32, pane_rect: [4]f32) {
	if state == nil do return
	_ = pane_id
	state.is_dragging = true
	state.is_exiting = false
	state.exit_fade_t = 1.0
	state.flush_frame = false
	state.target_rect = pane_rect
	if !state.anchor_valid {
		drop_effect_spawn(state, pos.x, pos.y, DROP_WAKE_STRENGTH, DROP_WAKE_LIFETIME)
		state.anchor_valid = true
		state.idle_time = 0.0
	} else {
		dx := pos.x - state.hover_x
		dy := pos.y - state.hover_y
		dist := math.sqrt(dx * dx + dy * dy)
		if dist > 2.0 {
			state.idle_time = 0.0
		}
		if dist > 0.0 {
			total := state.path_remainder + dist
			count := math.floor(total / DROP_WAKE_SPACING)
			remainder := math.mod(total, DROP_WAKE_SPACING)
			retained := int(math.min(count, f32(MAX_WATER_SPLASHES)))
			for j in 0..<retained {
				back := remainder + f32(retained - 1 - j) * DROP_WAKE_SPACING
				wx := pos.x - dx / dist * back
				wy := pos.y - dy / dist * back
				drop_effect_spawn(state, wx, wy, DROP_WAKE_STRENGTH, DROP_WAKE_LIFETIME)
			}
			state.path_remainder = remainder
		}
	}
	state.hover_x = pos.x
	state.hover_y = pos.y
}

drop_effect_on_drop :: proc(state: ^Drop_Effect_State, pos: [2]f32, pane_id: u32, pane_rect: [4]f32) {
	if state == nil do return
	_ = pane_id
	state.target_rect = pane_rect
	state.is_dragging = false
	state.is_exiting = true
	state.exit_fade_t = 1.0
	state.flush_frame = false
	state.anchor_valid = false
	state.path_remainder = 0.0
	state.impact_emitted = true
	drop_effect_spawn(state, pos.x, pos.y, DROP_IMPACT_STRENGTH, DROP_IMPACT_LIFETIME)
}

drop_effect_on_drag_complete :: proc(state: ^Drop_Effect_State) {
	if state == nil do return
	state.is_dragging = false
	state.is_exiting = true
	state.anchor_valid = false
	state.path_remainder = 0.0
}

drop_effect_update :: proc(state: ^Drop_Effect_State, dt: f32) {
	if state == nil || dt <= 0.0 do return
	clamped_dt := min(dt, 0.05)

	if state.flush_frame {
		state.flush_frame = false
		return
	}

	if state.is_exiting {
		state.exit_fade_t -= clamped_dt / 0.35
		if state.exit_fade_t <= 0.0 {
			state.exit_fade_t = 0.0
			state.is_exiting = false
		}
	}

	active_count := 0
	for &w in state.splashes {
		if !w.active do continue
		w.time += clamped_dt
		if w.time >= w.max_t {
			w.active = false
		} else {
			active_count += 1
		}
	}

	if active_count > 0 || state.is_dragging || state.is_exiting {
		state.was_active = true
	} else if state.was_active {
		state.flush_frame = true
		state.was_active = false
		state.impact_emitted = false
	}
}

drop_effect_is_active :: proc(state: ^Drop_Effect_State) -> bool {
	if state == nil do return false
	if state.is_dragging || state.is_exiting || state.flush_frame do return true
	for w in state.splashes do if w.active do return true
	return false
}

drop_effect_emit_draw_list :: proc(state: ^Drop_Effect_State, dl: ^chrome_dl.Ui_Draw_List, screen_w, screen_h, scale: f32) {
	if state == nil || dl == nil || !drop_effect_is_active(state) do return
	if state.flush_frame do return
	_ = scale
	count := 0
	for w in state.splashes {
		if w.active && w.time < w.max_t {
			count += 1
		}
	}
	if count == 0 do return

	base_col: [4]f32 = {0.60, 0.78, 0.95, 0.85}
	surf_rect: [4]f32 = {0.0, 0.0, screen_w, screen_h}
	chrome_dl.ui_draw_water_surface(dl, surf_rect, count, base_col)

	for w in state.splashes {
		if w.active && w.time < w.max_t {
			chrome_dl.ui_draw_water_wave_record(dl, w.x, w.y, w.time, w.max_t, w.strength)
		}
	}
}

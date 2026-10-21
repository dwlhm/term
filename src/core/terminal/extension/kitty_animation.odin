package terminal_extension

import "base:runtime"
import "core:time"

Kitty_Anim_State :: enum {
	Stopped = 1,
	Loading = 2,
	Running = 3,
}

Kitty_Frame :: struct {
	frame_num:   int,
	duration_ms: int,
	composition: u8,
	pixels:      []u8,
	width:       int,
	height:      int,
	x, y, w, h:  int,
	offset_x:    int,
	offset_y:    int,
}

Kitty_Animation :: struct {
	frames:        [dynamic]Kitty_Frame,
	current_frame: int,
	state:         Kitty_Anim_State,
	loop_count:    int,
	current_loop:  int,
	last_tick_ms:  i64,
}

kitty_animation_destroy :: proc(anim: ^Kitty_Animation, allocator: runtime.Allocator) {
	for i in 0..<len(anim.frames) {
		f := &anim.frames[i]
		if len(f.pixels) > 0 do delete(f.pixels, allocator)
	}
	delete(anim.frames)
	anim^ = {}
}

_kitty_ensure_anim_initialized :: proc(img: ^Kitty_Image, allocator: runtime.Allocator) {
	if img.animation.frames == nil {
		img.animation.frames = make([dynamic]Kitty_Frame, 0, 8, allocator)
		if len(img.pixels) > 0 {
			base_px := make([]u8, len(img.pixels), allocator)
			copy(base_px, img.pixels)
			append(&img.animation.frames, Kitty_Frame{
				frame_num   = 1,
				duration_ms = 40,
				composition = 1,
				pixels      = base_px,
				width       = img.width,
				height      = img.height,
			})
		}
	}
}

_kitty_handle_frame :: proc(
	state: ^Kitty_Extension,
	img: ^Kitty_Image,
	pixels: []u8,
	w, h: int,
) {
	if state == nil || img == nil || len(pixels) == 0 do return
	_kitty_ensure_anim_initialized(img, state.allocator)

	frame_num := state.current_frame_num if state.current_frame_num > 0 else len(img.animation.frames) + 1
	gap := state.current_gap if state.current_gap > 0 else 40

	new_frame := Kitty_Frame{
		frame_num   = frame_num,
		duration_ms = gap,
		composition = state.current_composition,
		pixels      = pixels,
		width       = w,
		height      = h,
		x           = state.current_src_x,
		y           = state.current_src_y,
		w           = state.current_src_w,
		h           = state.current_src_h,
		offset_x    = state.current_offset_x,
		offset_y    = state.current_offset_y,
	}

	found_idx := -1
	for i in 0..<len(img.animation.frames) {
		if img.animation.frames[i].frame_num == frame_num {
			found_idx = i
			break
		}
	}

	if found_idx >= 0 {
		old_f := &img.animation.frames[found_idx]
		if len(old_f.pixels) > 0 do delete(old_f.pixels, state.allocator)
		img.animation.frames[found_idx] = new_frame
	} else {
		append(&img.animation.frames, new_frame)
	}

	if len(img.animation.frames) > 1 && img.animation.state == nil {
		img.animation.state = .Running
		img.animation.last_tick_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000
	}
}

_kitty_handle_anim_ctrl :: proc(state: ^Kitty_Extension, img: ^Kitty_Image) {
	if state == nil || img == nil do return
	if state.current_anim_state >= 1 && state.current_anim_state <= 3 {
		img.animation.state = Kitty_Anim_State(state.current_anim_state)
		if img.animation.state == .Running && img.animation.last_tick_ms == 0 {
			img.animation.last_tick_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000
		}
	}
	if state.current_anim_loops > 0 {
		img.animation.loop_count = state.current_anim_loops
	}
	if state.current_frame_num > 0 {
		target_idx := state.current_frame_num - 1
		if target_idx >= 0 && target_idx < len(img.animation.frames) {
			img.animation.current_frame = target_idx
			_kitty_apply_active_frame(img)
		}
	}
}

_kitty_apply_active_frame :: proc(img: ^Kitty_Image) {
	if len(img.animation.frames) == 0 do return
	idx := img.animation.current_frame
	if idx < 0 || idx >= len(img.animation.frames) do return

	f := &img.animation.frames[idx]
	if len(f.pixels) == len(img.pixels) {
		copy(img.pixels, f.pixels)
	}
	img.gpu_dirty = true
}

kitty_animation_tick :: proc(img: ^Kitty_Image, now_ms: i64) -> bool {
	if img == nil || img.animation.state != .Running || len(img.animation.frames) <= 1 {
		return false
	}
	cur_idx := img.animation.current_frame
	if cur_idx < 0 || cur_idx >= len(img.animation.frames) do return false

	dur := i64(img.animation.frames[cur_idx].duration_ms)
	if dur <= 0 do dur = 40

	if now_ms - img.animation.last_tick_ms < dur do return false

	img.animation.last_tick_ms = now_ms
	next_idx := cur_idx + 1
	if next_idx >= len(img.animation.frames) {
		next_idx = 0
		if img.animation.loop_count > 0 {
			img.animation.current_loop += 1
			if img.animation.current_loop >= img.animation.loop_count {
				img.animation.state = .Stopped
				next_idx = len(img.animation.frames) - 1
			}
		}
	}

	img.animation.current_frame = next_idx
	_kitty_apply_active_frame(img)
	return true
}

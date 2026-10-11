package transition

// Package transition provides autonomous, zero-dependency layer transition
// animations (opacity fading and dest_rect interpolation) for core_composer.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime, core:math,
//    composer "../", and scheduler "../scheduler".
// 2. Zero dynamic heap allocation during steady-state.
// 3. Injectable clock: Uses explicit now_ns directly (ZERO wall-clock platform_now).
// 4. Strict adherence to Odin -strict-style.

import "base:runtime"
import "core:math"

import composer "../"
import scheduler "../scheduler"

Easing_Curve :: enum {
	Linear,
	Ease_In_Quad,
	Ease_Out_Quad,
	Ease_In_Out_Quad,
	Smoothstep,
}

Transition_Kind :: enum {
	Opacity,
	Dest_Rect,
}

MAX_TRANSITIONS :: 16

Transition :: struct {
	handle:         u32,
	layer_id:       composer.Layer_Id,
	kind:           Transition_Kind,
	easing:         Easing_Curve,
	start_time_ns:  u64,
	duration_ns:    u64,
	is_active:      bool,

	// Values
	start_opacity:  f32,
	target_opacity: f32,

	start_rect:     composer.Composer_Rect,
	target_rect:    composer.Composer_Rect,
}

Transition_Manager :: struct {
	transitions:  [MAX_TRANSITIONS]Transition,
	active_count: int,
	next_handle:  u32,
}

// transition_manager_init initializes the transition manager state.
transition_manager_init :: proc(tm: ^Transition_Manager) {
	if tm == nil do return
	tm^ = {}
	tm.next_handle = 1
}

// transition_start_opacity arms an opacity transition on the target layer.
transition_start_opacity :: proc(
	tm: ^Transition_Manager,
	s: ^scheduler.Frame_Scheduler,
	layer_id: composer.Layer_Id,
	from_val, to_val: f32,
	start_time_ns, duration_ns: u64,
	easing: Easing_Curve = .Smoothstep,
) -> u32 {
	if tm == nil do return 0

	slot_idx := -1
	existing := false
	for i in 0..<MAX_TRANSITIONS {
		if tm.transitions[i].is_active && tm.transitions[i].layer_id == layer_id && tm.transitions[i].kind == .Opacity {
			slot_idx = i
			existing = true
			break
		}
	}
	if !existing {
		for i in 0..<MAX_TRANSITIONS {
			if !tm.transitions[i].is_active {
				slot_idx = i
				break
			}
		}
	}
	if slot_idx < 0 do return 0

	if tm.next_handle == 0 do tm.next_handle = 1
	handle := tm.next_handle
	tm.next_handle += 1
	if tm.next_handle == 0 do tm.next_handle = 1

	tm.transitions[slot_idx] = Transition{
		handle         = handle,
		layer_id       = layer_id,
		kind           = .Opacity,
		easing         = easing,
		start_time_ns  = start_time_ns,
		duration_ns    = duration_ns,
		is_active      = true,
		start_opacity  = from_val,
		target_opacity = to_val,
	}
	if !existing {
		tm.active_count += 1
	}

	if s != nil {
		scheduler.scheduler_set_anim_active(s, true)
		scheduler.scheduler_mark_damage(s, layer_id)
	}

	return handle
}

// transition_start_rect arms a dest_rect transition on the target layer.
transition_start_rect :: proc(
	tm: ^Transition_Manager,
	s: ^scheduler.Frame_Scheduler,
	layer_id: composer.Layer_Id,
	from_rect, to_rect: composer.Composer_Rect,
	start_time_ns, duration_ns: u64,
	easing: Easing_Curve = .Smoothstep,
) -> u32 {
	if tm == nil do return 0

	slot_idx := -1
	existing := false
	for i in 0..<MAX_TRANSITIONS {
		if tm.transitions[i].is_active && tm.transitions[i].layer_id == layer_id && tm.transitions[i].kind == .Dest_Rect {
			slot_idx = i
			existing = true
			break
		}
	}
	if !existing {
		for i in 0..<MAX_TRANSITIONS {
			if !tm.transitions[i].is_active {
				slot_idx = i
				break
			}
		}
	}
	if slot_idx < 0 do return 0

	if tm.next_handle == 0 do tm.next_handle = 1
	handle := tm.next_handle
	tm.next_handle += 1
	if tm.next_handle == 0 do tm.next_handle = 1

	tm.transitions[slot_idx] = Transition{
		handle        = handle,
		layer_id      = layer_id,
		kind          = .Dest_Rect,
		easing        = easing,
		start_time_ns = start_time_ns,
		duration_ns   = duration_ns,
		is_active     = true,
		start_rect    = from_rect,
		target_rect   = to_rect,
	}
	if !existing {
		tm.active_count += 1
	}

	if s != nil {
		scheduler.scheduler_set_anim_active(s, true)
		scheduler.scheduler_mark_damage(s, layer_id)
	}

	return handle
}

// transition_crossfade starts a crossfade between two layers (fade out and fade in).
transition_crossfade :: proc(
	tm: ^Transition_Manager,
	s: ^scheduler.Frame_Scheduler,
	fade_out_id, fade_in_id: composer.Layer_Id,
	start_time_ns, duration_ns: u64,
	easing: Easing_Curve = .Smoothstep,
) -> (h1, h2: u32) {
	h1 = transition_start_opacity(tm, s, fade_out_id, 1.0, 0.0, start_time_ns, duration_ns, easing)
	h2 = transition_start_opacity(tm, s, fade_in_id, 0.0, 1.0, start_time_ns, duration_ns, easing)
	return h1, h2
}

// transition_update advances all active transitions using an injectable clock.
transition_update :: proc(
	tm: ^Transition_Manager,
	s: ^scheduler.Frame_Scheduler,
	layers: []composer.Composer_Layer,
	now_ns: u64,
) -> (any_changed: bool) {
	if tm == nil do return false

	for &t in tm.transitions {
		if !t.is_active do continue
		if now_ns < t.start_time_ns {
			if s != nil {
				scheduler.scheduler_set_deadline(s, t.start_time_ns)
			}
			continue
		}

		elapsed := now_ns - t.start_time_ns
		u := 1.0 if t.duration_ns == 0 else clamp(f32(elapsed) / f32(t.duration_ns), 0.0, 1.0)

		e: f32
		switch t.easing {
		case .Linear:
			e = u
		case .Ease_In_Quad:
			e = u * u
		case .Ease_Out_Quad:
			e = 1.0 - (1.0 - u) * (1.0 - u)
		case .Ease_In_Out_Quad:
			if u < 0.5 {
				e = 2.0 * u * u
			} else {
				inv := -2.0 * u + 2.0
				e = 1.0 - (inv * inv) / 2.0
			}
		case .Smoothstep:
			e = u * u * (3.0 - 2.0 * u)
		}

		for &l in layers {
			if l.id == t.layer_id {
				switch t.kind {
				case .Opacity:
					l.opacity = t.start_opacity + (t.target_opacity - t.start_opacity) * e
				case .Dest_Rect:
					l.dest_rect.x = math.floor(t.start_rect.x + (t.target_rect.x - t.start_rect.x) * e + 0.5)
					l.dest_rect.y = math.floor(t.start_rect.y + (t.target_rect.y - t.start_rect.y) * e + 0.5)
					l.dest_rect.w = math.floor(t.start_rect.w + (t.target_rect.w - t.start_rect.w) * e + 0.5)
					l.dest_rect.h = math.floor(t.start_rect.h + (t.target_rect.h - t.start_rect.h) * e + 0.5)
					l.scissor_rect = l.dest_rect
				}
				break
			}
		}

		if s != nil {
			scheduler.scheduler_mark_damage(s, t.layer_id)
		}

		if u >= 1.0 {
			t.is_active = false
			if tm.active_count > 0 {
				tm.active_count -= 1
			}
		}

		any_changed = true
	}

	if tm.active_count == 0 && s != nil {
		scheduler.scheduler_set_anim_active(s, false)
	}

	return any_changed
}

package main

import "core:math"
import input "../platform/input"
import instance "../render/instance"

MAX_SPLASHES :: instance.WATER_MAX_WAVES
DROP_WAKE_SPACING: f64 : 22
DROP_WAKE_STRENGTH: f32 : 0.32
DROP_WAKE_LIFETIME: f32 : 1.8
DROP_IMPACT_STRENGTH: f32 : 0.8
DROP_IMPACT_LIFETIME: f32 : 2.2

Drop_Splash :: struct {
	active: bool,
	x, y, time, max_t, strength: f32,
}

Drop_Fx_State :: struct {
	hovering: bool,
	hover_x, hover_y: f32,
	anchor_valid: bool,
	path_remainder: f64,
	impact_emitted: bool,
	next_slot: int,
	splashes: [MAX_SPLASHES]Drop_Splash,
}

_drop_fx_finite :: proc(x: f32) -> bool {
	return !math.is_nan(x) && !math.is_inf(x)
}

_drop_fx_spawn :: proc(s: ^Drop_Fx_State, x, y, strength, lifetime: f32) {
	idx := s.next_slot
	oldest: f32 = -1
	for step in 0..<MAX_SPLASHES {
		i := (s.next_slot + step) % MAX_SPLASHES
		wave := s.splashes[i]
		if !wave.active {
			idx = i
			break
		}
		age := wave.time / wave.max_t
		if age > oldest {
			oldest = age
			idx = i
		}
	}
	s.splashes[idx] = Drop_Splash{active = true, x = x, y = y, max_t = lifetime, strength = strength}
	s.next_slot = (idx + 1) % MAX_SPLASHES
}

// Visual state only: payload ownership and writes remain in event dispatch.
drop_fx_handle :: proc(s: ^Drop_Fx_State, drop: input.Input_Drop_Event) {
	if s == nil do return
	if drop.kind == .Complete {
		s.hovering = false
		s.anchor_valid = false
		s.path_remainder = 0
		s.impact_emitted = false
		return
	}
	if drop.kind == .Begin {
		s.anchor_valid = false
		s.path_remainder = 0
		s.impact_emitted = false
	}
	if !_drop_fx_finite(drop.x) || !_drop_fx_finite(drop.y) {
		s.anchor_valid = false
		s.path_remainder = 0
		return
	}
	if drop.kind == .File || drop.kind == .Text {
		s.hovering = false
		s.anchor_valid = false
		s.path_remainder = 0
		if !s.impact_emitted {
			_drop_fx_spawn(s, drop.x, drop.y, DROP_IMPACT_STRENGTH, DROP_IMPACT_LIFETIME)
			s.impact_emitted = true
		}
		return
	}
	s.hovering = true
	if !s.anchor_valid {
		_drop_fx_spawn(s, drop.x, drop.y, DROP_WAKE_STRENGTH, DROP_WAKE_LIFETIME)
		s.anchor_valid = true
	} else {
		// f64 distance avoids overflowing finite OS f32 coordinates.
		dx := f64(drop.x) - f64(s.hover_x)
		dy := f64(drop.y) - f64(s.hover_y)
		distance := math.sqrt(dx * dx + dy * dy)
		if distance > 0 {
			total := s.path_remainder + distance
			count := math.floor(total / DROP_WAKE_SPACING)
			remainder := math.mod(total, DROP_WAKE_SPACING)
			// Skip old samples mathematically; work stays bounded for any segment.
			retained := int(math.min(count, f64(MAX_SPLASHES)))
			for j in 0..<retained {
				back := remainder + f64(retained - 1 - j) * DROP_WAKE_SPACING
				x := f32(f64(drop.x) - dx / distance * back)
				y := f32(f64(drop.y) - dy / distance * back)
				_drop_fx_spawn(s, x, y, DROP_WAKE_STRENGTH, DROP_WAKE_LIFETIME)
			}
			s.path_remainder = remainder
		}
	}
	s.hover_x = drop.x
	s.hover_y = drop.y
}

drop_fx_active :: proc(s: ^Drop_Fx_State) -> bool {
	if s == nil do return false
	for wave in s.splashes {
		if wave.active do return true
	}
	return false
}

drop_fx_tick :: proc(s: ^Drop_Fx_State, dt: f32) -> (active, changed: bool) {
	if s == nil do return
	if !_drop_fx_finite(dt) || dt <= 0 do return drop_fx_active(s), false
	for &wave in s.splashes {
		if !wave.active do continue
		changed = true
		wave.time = math.min(wave.time + dt, wave.max_t)
		wave.active = wave.time < wave.max_t
		active = active || wave.active
	}
	return
}

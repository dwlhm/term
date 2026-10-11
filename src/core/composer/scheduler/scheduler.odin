package scheduler

// Frame scheduling primitives for OS-Style Layer Compositor Architecture.
// Part of core_composer: Tier 1 Autonomous Core Primitives.
//
// Invariants:
// 1. ZERO Horizontal Dependencies: Imports ONLY base:runtime and composer "../".
//    No imports of terminal, chrome, ui, platform, or app.
// 2. Zero dynamic heap allocation during steady-state.
// 3. Strict adherence to Odin -strict-style.

import "base:runtime"
import composer "../"

Frame_Scheduler :: struct {
	damage_pending:   bool,
	anim_active:      bool,
	force_next:       bool,
	next_deadline:    u64, // ns timestamp (from platform_now ticks_to_ns); 0 = parked / none

	// Telemetry
	rendered_frames:  u64, // frames where needs_frame was true and frame_done succeeded
	skipped_frames:   u64, // iterations where needs_frame returned false
	spurious_wakeups: u64, // woke up but produced zero damage or work
}

// scheduler_init initializes scheduler state and forces first frame render.
scheduler_init :: proc(s: ^Frame_Scheduler) {
	if s == nil do return
	s^ = {}
	s.force_next = true
}

// scheduler_needs_frame evaluates whether the scheduler requires rendering a new frame.
// PURE function with ZERO side effects. Does NOT mutate flags or deadlines.
scheduler_needs_frame :: proc(s: ^Frame_Scheduler, now_ns: u64) -> (needs: bool, wake_at: u64) {
	if s == nil do return false, 0

	if s.force_next || s.damage_pending || s.anim_active {
		return true, 0
	}

	if s.next_deadline > 0 {
		if now_ns >= s.next_deadline {
			return true, 0
		}
		return false, s.next_deadline
	}

	return false, 0
}

// scheduler_frame_done is called ONLY after a frame is successfully presented.
// Clears damage_pending and force_next, and increments rendered_frames.
scheduler_frame_done :: proc(s: ^Frame_Scheduler) {
	if s == nil do return
	s.damage_pending = false
	s.force_next = false
	s.rendered_frames += 1
}

// scheduler_mark_damage marks damage pending for composer layers.
// Rect parameter is preserved for fine-grained damage tracking.
scheduler_mark_damage :: proc(s: ^Frame_Scheduler, layer_id: composer.Layer_Id, rect: [4]f32 = {0, 0, 0, 0}) {
	if s == nil do return
	_ = layer_id
	_ = rect
	s.damage_pending = true
}

// scheduler_force_next requests that the next tick unconditionally renders a frame.
scheduler_force_next :: proc(s: ^Frame_Scheduler) {
	if s == nil do return
	s.force_next = true
}

// scheduler_set_anim_active sets whether an animation loop is actively running.
scheduler_set_anim_active :: proc(s: ^Frame_Scheduler, active: bool) {
	if s == nil do return
	s.anim_active = active
}

// scheduler_set_deadline schedules a future wakeup deadline in nanoseconds.
scheduler_set_deadline :: proc(s: ^Frame_Scheduler, deadline_ns: u64) {
	if s == nil do return
	s.next_deadline = deadline_ns
}

// scheduler_record_skip records a skipped frame tick in telemetry.
scheduler_record_skip :: proc(s: ^Frame_Scheduler) {
	if s == nil do return
	s.skipped_frames += 1
}

// scheduler_record_spurious_wake records a wakeup with zero damage or work in telemetry.
scheduler_record_spurious_wake :: proc(s: ^Frame_Scheduler) {
	if s == nil do return
	s.spurious_wakeups += 1
}

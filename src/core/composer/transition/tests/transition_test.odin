package transition_tests

// OS-Style Layer Compositor Transition automated unit test suite.
// Verifies bit-exact injectable clock progress, frame skipping catch-up,
// scheduler animation sleep coordination, crossfade pairs, dest_rect interpolation,
// and easing curves under strict zero-allocation conditions.

import "core:testing"

import composer "../../"
import scheduler "../../scheduler"
import transition "../"

@test
test_transition_bit_exact_injectable_clock :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id      = composer.Layer_Id(1),
		opacity = 0.0,
	}
	layers := []composer.Composer_Layer{layer}

	start_time_ns: u64 = 0
	duration_ns: u64 = 1_000_000_000

	h := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.0,
		1.0,
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h != 0, "Transition handle must be non-zero")

	now_ns: u64 = 500_000_000
	changed := transition.transition_update(&tm, nil, layers, now_ns)
	testing.expect(t, changed, "Transition update must report changed")
	testing.expect_value(t, layers[0].opacity, f32(0.50))
}

@test
test_transition_delayed_or_skipped_frames_catch_up :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id      = composer.Layer_Id(1),
		opacity = 0.0,
	}
	layers := []composer.Composer_Layer{layer}

	start_time_ns: u64 = 0
	duration_ns: u64 = 1_000_000_000 // 1000 ms

	h := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.0,
		1.0,
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h != 0, "Transition handle must be non-zero")

	// Skip updates completely until t = 750 ms (750_000_000 ns)
	now_ns: u64 = 750_000_000
	changed := transition.transition_update(&tm, nil, layers, now_ns)
	testing.expect(t, changed, "Transition update must report changed")
	testing.expect_value(t, layers[0].opacity, f32(0.75))
}

@test
test_transition_completion_resets_scheduler_anim_active :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_init(&s)
	// Clear initial force_next frame so scheduler is quiescent
	scheduler.scheduler_frame_done(&s)

	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id      = composer.Layer_Id(1),
		opacity = 0.0,
	}
	layers := []composer.Composer_Layer{layer}

	start_time_ns: u64 = 0
	duration_ns: u64 = 1_000_000_000

	h := transition.transition_start_opacity(
		&tm,
		&s,
		composer.Layer_Id(1),
		0.0,
		1.0,
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h != 0, "Transition handle must be non-zero")
	testing.expect(t, s.anim_active, "Scheduler anim_active must be true after starting transition")

	// Update before completion (t < duration) -> s.anim_active remains true
	changed := transition.transition_update(&tm, &s, layers, 500_000_000)
	testing.expect(t, changed, "Transition update must report changed before completion")
	testing.expect(t, s.anim_active, "Scheduler anim_active must remain true before completion")
	scheduler.scheduler_frame_done(&s)

	// Update at/after completion (t >= duration) -> t.is_active becomes false, active_count becomes 0, anim_active becomes false
	changed = transition.transition_update(&tm, &s, layers, 1_000_000_000)
	testing.expect(t, changed, "Transition update must report changed on completion frame")
	testing.expect_value(t, tm.active_count, 0)
	testing.expect(t, !tm.transitions[0].is_active, "Transition must be inactive upon completion")
	testing.expect(t, !s.anim_active, "Scheduler anim_active must be reset to false upon completion")

	// Present completion frame
	scheduler.scheduler_frame_done(&s)

	// Calling scheduler_needs_frame after frame_done returns false (scheduler goes back to sleep!)
	needs, wake_at := scheduler.scheduler_needs_frame(&s, 1_000_000_000)
	testing.expect(t, !needs, "Scheduler must go back to sleep after transition completion")
	testing.expect_value(t, wake_at, u64(0))
}

@test
test_transition_crossfade_pair :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layers := [2]composer.Composer_Layer{
		{id = composer.Layer_Id(1), opacity = 1.0},
		{id = composer.Layer_Id(2), opacity = 0.0},
	}

	start_time_ns: u64 = 0
	duration_ns: u64 = 1_000_000_000

	h1, h2 := transition.transition_crossfade(
		&tm,
		nil,
		composer.Layer_Id(1),
		composer.Layer_Id(2),
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h1 != 0, "h1 must be valid non-zero handle")
	testing.expect(t, h2 != 0, "h2 must be valid non-zero handle")
	testing.expect_value(t, tm.active_count, 2)

	// At midpoint, Layer 1 opacity is 0.5 and Layer 2 opacity is 0.5
	mid_ns: u64 = 500_000_000
	changed := transition.transition_update(&tm, nil, layers[:], mid_ns)
	testing.expect(t, changed, "Must report changed at midpoint")
	testing.expect_value(t, layers[0].opacity, f32(0.50))
	testing.expect_value(t, layers[1].opacity, f32(0.50))

	// At completion, Layer 1 opacity is 0.0 and Layer 2 opacity is 1.0
	end_ns: u64 = 1_000_000_000
	changed = transition.transition_update(&tm, nil, layers[:], end_ns)
	testing.expect(t, changed, "Must report changed at completion")
	testing.expect_value(t, layers[0].opacity, f32(0.00))
	testing.expect_value(t, layers[1].opacity, f32(1.00))
	testing.expect_value(t, tm.active_count, 0)
}

@test
test_transition_dest_rect_interpolation :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id        = composer.Layer_Id(3),
		dest_rect = composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100},
	}
	layers := []composer.Composer_Layer{layer}

	from_rect := composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100}
	to_rect := composer.Composer_Rect{x = 50, y = 100, w = 200, h = 300}

	start_time_ns: u64 = 0
	duration_ns: u64 = 1_000_000_000

	h := transition.transition_start_rect(
		&tm,
		nil,
		composer.Layer_Id(3),
		from_rect,
		to_rect,
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h != 0, "Handle must be valid")

	mid_ns: u64 = 500_000_000
	changed := transition.transition_update(&tm, nil, layers, mid_ns)
	testing.expect(t, changed, "Must report changed")
	testing.expect_value(t, layers[0].dest_rect.x, f32(25))
	testing.expect_value(t, layers[0].dest_rect.y, f32(50))
	testing.expect_value(t, layers[0].dest_rect.w, f32(150))
	testing.expect_value(t, layers[0].dest_rect.h, f32(200))
	testing.expect_value(t, layers[0].scissor_rect, layers[0].dest_rect)
}

@test
test_transition_zero_duration_completes_instantly :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id        = composer.Layer_Id(1),
		opacity   = 0.0,
		dest_rect = composer.Composer_Rect{x = 0, y = 0, w = 10, h = 10},
	}
	layers := []composer.Composer_Layer{layer}

	// Zero duration opacity transition
	h1 := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.0,
		1.0,
		1_000_000_000,
		0,
		.Linear,
	)
	testing.expect(t, h1 != 0, "Opacity handle must be non-zero")
	testing.expect_value(t, tm.active_count, 1)

	changed := transition.transition_update(&tm, nil, layers, 1_000_000_000)
	testing.expect(t, changed, "Update must report changed")
	testing.expect_value(t, layers[0].opacity, f32(1.0))
	testing.expect_value(t, tm.active_count, 0)
	testing.expect(t, !tm.transitions[0].is_active, "Transition must be inactive")

	// Zero duration rect transition
	h2 := transition.transition_start_rect(
		&tm,
		nil,
		composer.Layer_Id(1),
		composer.Composer_Rect{x = 0, y = 0, w = 10, h = 10},
		composer.Composer_Rect{x = 50, y = 50, w = 200, h = 200},
		1_000_000_000,
		0,
		.Linear,
	)
	testing.expect(t, h2 != 0, "Rect handle must be non-zero")
	testing.expect_value(t, tm.active_count, 1)

	changed = transition.transition_update(&tm, nil, layers, 1_000_000_000)
	testing.expect(t, changed, "Update must report changed")
	testing.expect_value(t, layers[0].dest_rect.x, f32(50))
	testing.expect_value(t, layers[0].dest_rect.y, f32(50))
	testing.expect_value(t, layers[0].dest_rect.w, f32(200))
	testing.expect_value(t, layers[0].dest_rect.h, f32(200))
	testing.expect_value(t, tm.active_count, 0)
}

@test
test_transition_start_in_future_waits_for_start_time :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_init(&s)
	scheduler.scheduler_frame_done(&s)

	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id      = composer.Layer_Id(1),
		opacity = 0.2,
	}
	layers := []composer.Composer_Layer{layer}

	start_time_ns: u64 = 2_000_000_000
	duration_ns: u64 = 1_000_000_000

	h := transition.transition_start_opacity(
		&tm,
		&s,
		composer.Layer_Id(1),
		0.2,
		0.8,
		start_time_ns,
		duration_ns,
		.Linear,
	)
	testing.expect(t, h != 0, "Handle must be non-zero")

	// Call before start_time_ns (now_ns < start_time_ns)
	now_ns: u64 = 1_000_000_000
	changed := transition.transition_update(&tm, &s, layers, now_ns)
	testing.expect(t, !changed, "Must not report changed before start_time_ns")
	testing.expect_value(t, layers[0].opacity, f32(0.2))
	testing.expect_value(t, s.next_deadline, start_time_ns)
	testing.expect_value(t, tm.active_count, 1)

	// Call at midway (now_ns = 2_500_000_000)
	changed = transition.transition_update(&tm, &s, layers, 2_500_000_000)
	testing.expect(t, changed, "Must report changed after start_time_ns")
	testing.expect_value(t, layers[0].opacity, f32(0.5))
	testing.expect_value(t, tm.active_count, 1)

	// Call at completion (now_ns = 3_000_000_000)
	changed = transition.transition_update(&tm, &s, layers, 3_000_000_000)
	testing.expect(t, changed, "Must report changed at completion")
	testing.expect_value(t, layers[0].opacity, f32(0.8))
	testing.expect_value(t, tm.active_count, 0)
	testing.expect(t, !s.anim_active, "anim_active must be false upon completion")
}

@test
test_transition_restart_replaces_active_slot_without_count_leak :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id        = composer.Layer_Id(1),
		opacity   = 0.0,
		dest_rect = composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100},
	}
	layers := []composer.Composer_Layer{layer}

	// 1. Start opacity transition
	h1 := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.0,
		1.0,
		0,
		1_000_000_000,
		.Linear,
	)
	testing.expect(t, h1 != 0, "h1 must be valid")
	testing.expect_value(t, tm.active_count, 1)

	// Restart opacity transition on same layer
	h2 := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.5,
		0.0,
		0,
		500_000_000,
		.Linear,
	)
	testing.expect(t, h2 != 0, "h2 must be valid")
	testing.expect(t, h2 != h1, "h2 must have new handle")
	testing.expect_value(t, tm.active_count, 1)
	testing.expect_value(t, tm.transitions[0].target_opacity, f32(0.0))
	testing.expect_value(t, tm.transitions[0].start_opacity, f32(0.5))

	// Update to completion
	changed := transition.transition_update(&tm, nil, layers, 500_000_000)
	testing.expect(t, changed, "Must report changed")
	testing.expect_value(t, layers[0].opacity, f32(0.0))
	testing.expect_value(t, tm.active_count, 0)

	// 2. Start rect transition
	r1 := transition.transition_start_rect(
		&tm,
		nil,
		composer.Layer_Id(1),
		composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100},
		composer.Composer_Rect{x = 10, y = 10, w = 100, h = 100},
		0,
		1_000_000_000,
		.Linear,
	)
	testing.expect(t, r1 != 0, "r1 must be valid")
	testing.expect_value(t, tm.active_count, 1)

	// Restart rect transition on same layer
	r2 := transition.transition_start_rect(
		&tm,
		nil,
		composer.Layer_Id(1),
		composer.Composer_Rect{x = 5, y = 5, w = 100, h = 100},
		composer.Composer_Rect{x = 20, y = 20, w = 200, h = 200},
		0,
		500_000_000,
		.Linear,
	)
	testing.expect(t, r2 != 0, "r2 must be valid")
	testing.expect_value(t, tm.active_count, 1)

	changed = transition.transition_update(&tm, nil, layers, 500_000_000)
	testing.expect(t, changed, "Must report changed")
	testing.expect_value(t, layers[0].dest_rect.x, f32(20))
	testing.expect_value(t, tm.active_count, 0)
}

@test
test_transition_simultaneous_different_kinds_same_layer :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	layer := composer.Composer_Layer{
		id        = composer.Layer_Id(1),
		opacity   = 0.0,
		dest_rect = composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100},
	}
	layers := []composer.Composer_Layer{layer}

	// Arm Opacity and Dest_Rect transitions concurrently on the same layer
	h_op := transition.transition_start_opacity(
		&tm,
		nil,
		composer.Layer_Id(1),
		0.0,
		1.0,
		0,
		1_000_000_000,
		.Linear,
	)
	h_rect := transition.transition_start_rect(
		&tm,
		nil,
		composer.Layer_Id(1),
		composer.Composer_Rect{x = 0, y = 0, w = 100, h = 100},
		composer.Composer_Rect{x = 100, y = 200, w = 300, h = 400},
		0,
		1_000_000_000,
		.Linear,
	)

	testing.expect(t, h_op != 0, "h_op must be valid")
	testing.expect(t, h_rect != 0, "h_rect must be valid")
	testing.expect_value(t, tm.active_count, 2)

	// Midpoint evaluation
	changed := transition.transition_update(&tm, nil, layers, 500_000_000)
	testing.expect(t, changed, "Must report changed")
	testing.expect_value(t, layers[0].opacity, f32(0.50))
	testing.expect_value(t, layers[0].dest_rect.x, f32(50))
	testing.expect_value(t, layers[0].dest_rect.y, f32(100))
	testing.expect_value(t, layers[0].dest_rect.w, f32(200))
	testing.expect_value(t, layers[0].dest_rect.h, f32(250))
	testing.expect_value(t, tm.active_count, 2)

	// Completion evaluation
	changed = transition.transition_update(&tm, nil, layers, 1_000_000_000)
	testing.expect(t, changed, "Must report changed at completion")
	testing.expect_value(t, layers[0].opacity, f32(1.00))
	testing.expect_value(t, layers[0].dest_rect.x, f32(100))
	testing.expect_value(t, layers[0].dest_rect.y, f32(200))
	testing.expect_value(t, layers[0].dest_rect.w, f32(300))
	testing.expect_value(t, layers[0].dest_rect.h, f32(400))
	testing.expect_value(t, tm.active_count, 0)
}

@test
test_transition_completion_frame_renders_final_value_and_then_sleeps :: proc(t: ^testing.T) {
	tm: transition.Transition_Manager
	transition.transition_manager_init(&tm)

	s: scheduler.Frame_Scheduler
	scheduler.scheduler_init(&s)
	// Clear startup force_next
	scheduler.scheduler_frame_done(&s)

	layer := composer.Composer_Layer{
		id      = composer.Layer_Id(1),
		opacity = 0.0,
	}
	layers := []composer.Composer_Layer{layer}

	// Arm opacity 0 -> 1 over 100ms
	_ = transition.transition_start_opacity(
		&tm,
		&s,
		composer.Layer_Id(1),
		0.0,
		1.0,
		0,
		100_000_000,
		.Linear,
	)
	testing.expect(t, s.anim_active, "anim_active must be true while transition is active")

	// Frame at 50ms: progress 0.5
	_ = transition.transition_update(&tm, &s, layers, 50_000_000)
	needs, _ := scheduler.scheduler_needs_frame(&s, 50_000_000)
	testing.expect(t, needs, "Frame needed at 50ms")
	scheduler.scheduler_frame_done(&s)

	// Completion frame at 100ms: progress exactly 1.0 (u >= 1.0)
	_ = transition.transition_update(&tm, &s, layers, 100_000_000)
	testing.expect_value(t, layers[0].opacity, f32(1.00))
	testing.expect(t, !s.anim_active, "anim_active must be set to false upon completion")

	// Critical check: damage_pending must be true on this completion frame so final 100% value renders!
	needs_final, _ := scheduler.scheduler_needs_frame(&s, 100_000_000)
	testing.expect(t, needs_final, "Completion frame MUST render to display the 100% target value!")

	// Present final frame
	scheduler.scheduler_frame_done(&s)

	// Next iteration: now scheduler goes to sleep! Screen rests at 100% with zero wakeups!
	needs_after, _ := scheduler.scheduler_needs_frame(&s, 116_666_666)
	testing.expect(t, !needs_after, "Scheduler MUST sleep after completion frame was presented!")
}

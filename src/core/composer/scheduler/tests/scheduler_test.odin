package scheduler_tests

// OS-Style Layer Compositor Frame Scheduler automated unit test suite.
// Verifies first frame forcing, damage preservation, pure non-mutating queries,
// deadline advancing without spin, and continuous animation loop rendering.

import "core:testing"

import composer "../../"
import scheduler "../"

@test
test_scheduler_first_frame_forces_render :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_init(&s)

	needs, wake_at := scheduler.scheduler_needs_frame(&s, 1000)
	testing.expect(t, needs, "First frame after init must force render")
	testing.expect_value(t, wake_at, u64(0))

	scheduler.scheduler_frame_done(&s)

	needs, wake_at = scheduler.scheduler_needs_frame(&s, 1000)
	testing.expect(t, !needs, "Frame after frame_done must be quiescent if no pending damage")
	testing.expect_value(t, wake_at, u64(0))
	testing.expect_value(t, s.rendered_frames, u64(1))
}

@test
test_scheduler_damage_triggers_frame_and_done_clears :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	// Initially quiescent
	needs, wake_at := scheduler.scheduler_needs_frame(&s, 0)
	testing.expect(t, !needs, "Initially unforced scheduler must be quiescent")
	testing.expect_value(t, wake_at, u64(0))

	scheduler.scheduler_mark_damage(&s, composer.Layer_Id(1), {0, 0, 100, 100})

	// Pure query: multiple queries must return true without mutating state
	for _ in 0..<3 {
		needs, wake_at = scheduler.scheduler_needs_frame(&s, 500)
		testing.expect(t, needs, "Marked damage must require frame across repeated queries")
		testing.expect_value(t, wake_at, u64(0))
	}

	scheduler.scheduler_frame_done(&s)

	needs, wake_at = scheduler.scheduler_needs_frame(&s, 500)
	testing.expect(t, !needs, "frame_done must clear damage_pending")
	testing.expect_value(t, wake_at, u64(0))
}

@test
test_scheduler_presentation_failure_preserves_damage :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_mark_damage(&s, composer.Layer_Id(1), {0, 0, 10, 10})

	needs, _ := scheduler.scheduler_needs_frame(&s, 100)
	testing.expect(t, needs, "Damage must trigger frame")

	// Simulate presentation failure: frame_done is NOT called
	needs, _ = scheduler.scheduler_needs_frame(&s, 101)
	testing.expect(t, needs, "Damage must be preserved across presentation failures")
	testing.expect(t, s.damage_pending, "damage_pending flag must remain true")
	testing.expect_value(t, s.rendered_frames, u64(0))
}

@test
test_scheduler_deadline_triggers_and_does_not_spin_when_advanced :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	now := u64(1_000_000_000)
	deadline := now + 530_000_000

	scheduler.scheduler_set_deadline(&s, deadline)

	// Before deadline
	needs, wake_at := scheduler.scheduler_needs_frame(&s, now + 100_000_000)
	testing.expect(t, !needs, "Must not need frame before deadline")
	testing.expect_value(t, wake_at, deadline)

	// At or after deadline
	needs, wake_at = scheduler.scheduler_needs_frame(&s, now + 530_000_000)
	testing.expect(t, needs, "Must need frame at or after deadline")
	testing.expect_value(t, wake_at, u64(0))

	// Caller advances deadline and presents frame
	next_deadline := now + 1_060_000_000
	scheduler.scheduler_set_deadline(&s, next_deadline)
	scheduler.scheduler_frame_done(&s)

	// Next check at previous deadline time must wait for next_deadline, no infinite spin
	needs, wake_at = scheduler.scheduler_needs_frame(&s, now + 530_000_000)
	testing.expect(t, !needs, "Must not spin after deadline is advanced")
	testing.expect_value(t, wake_at, next_deadline)
}

@test
test_scheduler_animation_continuous_rendering :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_set_anim_active(&s, true)

	needs, wake_at := scheduler.scheduler_needs_frame(&s, 2000)
	testing.expect(t, needs, "Animation active must require frame")
	testing.expect_value(t, wake_at, u64(0))

	scheduler.scheduler_frame_done(&s)

	needs, wake_at = scheduler.scheduler_needs_frame(&s, 2016)
	testing.expect(t, needs, "Animation must continue to require frame after frame_done")
	testing.expect_value(t, wake_at, u64(0))

	scheduler.scheduler_set_anim_active(&s, false)

	needs, wake_at = scheduler.scheduler_needs_frame(&s, 2032)
	testing.expect(t, !needs, "Disabling animation must return scheduler to quiescent")
	testing.expect_value(t, wake_at, u64(0))
}

@test
test_scheduler_force_next_and_telemetry :: proc(t: ^testing.T) {
	s: scheduler.Frame_Scheduler
	scheduler.scheduler_force_next(&s)

	needs, wake_at := scheduler.scheduler_needs_frame(&s, 500)
	testing.expect(t, needs, "force_next must request frame")
	testing.expect_value(t, wake_at, u64(0))

	scheduler.scheduler_frame_done(&s)
	testing.expect(t, !s.force_next, "frame_done must clear force_next")
	testing.expect_value(t, s.rendered_frames, u64(1))

	scheduler.scheduler_record_skip(&s)
	testing.expect_value(t, s.skipped_frames, u64(1))

	scheduler.scheduler_record_spurious_wake(&s)
	testing.expect_value(t, s.spurious_wakeups, u64(1))
}

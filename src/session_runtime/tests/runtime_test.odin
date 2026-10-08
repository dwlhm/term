package session_runtime_test

import posix "core:sys/posix"
import "core:testing"
import "core:time"
import rt "../"

@(test)
test_observe_activity_live_process :: proc(t: ^testing.T) {
	before := time.to_unix_nanoseconds(time.now())
	pid := int(posix.getpid())
	obs := rt.observe_activity(pid)
	after := time.to_unix_nanoseconds(time.now())

	testing.expect_value(t, obs.kind, rt.Activity_Observation_Kind.ShellReady)
	testing.expect(t, obs.observed_at_ns >= before && obs.observed_at_ns <= after, "observed_at_ns must be live timestamp")
	testing.expect_value(t, obs.foreground_name, "shell")
}

@(test)
test_observe_activity_invalid_or_dead :: proc(t: ^testing.T) {
	obs_zero := rt.observe_activity(0)
	testing.expect_value(t, obs_zero.kind, rt.Activity_Observation_Kind.Unknown)

	obs_one := rt.observe_activity(1)
	testing.expect_value(t, obs_one.kind, rt.Activity_Observation_Kind.Unknown)

	obs_invalid := rt.observe_activity(-42)
	testing.expect_value(t, obs_invalid.kind, rt.Activity_Observation_Kind.Unknown)
}

@(test)
test_close_targets :: proc(t: ^testing.T) {
	pids := []int{0, 1, -1}
	ok := rt.close_targets(pids)
	testing.expect(t, ok, "close_targets should succeed on invalid pids")
}

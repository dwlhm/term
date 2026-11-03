package feature_session_core_tests

// Invariant 1: once a session and its viewer exist, relaying program output
// (relay, Terminal, answered queries, viewer DATA + CREDIT, row EVENTs) does
// not allocate.

import "core:mem"
import "core:testing"
import core ".."

@(private = "file")
CHUNK :: "\x1b[1;32mbuild\x1b[0m step \x1b[38;2;10;20;30mrgb\x1b[0m ünï 漢字 \x1b[6n\r\n"

// rig_turn relays one chunk and lets the viewer read it and grant credit.
@(private = "file")
rig_turn :: proc(r: ^Rig) -> int {
	core.core_session_output(r.c, r.s, transmute([]u8)string(CHUNK))
	return rig_deliver(r, 0)
}

@(test)
test_output_relay_allocates_nothing :: proc(t: ^testing.T) {
	r: Rig
	testing.expect(t, rig_make(&r) && rig_attach(&r) == 0, "rig")
	defer rig_destroy(&r)
	// Warm up past the history limit so every ring is at its steady size.
	for _ in 0..<12_000 do rig_turn(&r)
	track, temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&track)
	defer mem.tracking_allocator_destroy(&temp_track)
	delivered := 0
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		for _ in 0..<5_000 do delivered += rig_turn(&r)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
	testing.expect(t, delivered > 5_000 * 40, "the viewer received the stream")
	testing.expect(t, r.c.viewers[0].used, "the viewer is still linked")
}

package feature_multiplexer_tests

import "core:testing"
import feature ".."
import session "../../session"

@test
test_multiplexer_lifecycle :: proc(t: ^testing.T) {
	m: feature.Multiplexer
	feature.multiplexer_init(&m)
	defer feature.multiplexer_destroy(&m)

	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	// 1. Create Terminal pane
	id1, err1 := feature.multiplexer_create_terminal_pane(&m, cfg)
	testing.expect(t, err1 == .None, "Create terminal pane 1 failed")
	testing.expect_value(t, id1, u32(1))
	testing.expect_value(t, m.focused_pane_id, u32(1))

	p1 := feature.multiplexer_get_pane(&m, id1)
	testing.expect(t, p1 != nil, "Pane 1 not found")
	testing.expect_value(t, p1.kind, feature.Pane_Kind.Terminal)

	// 2. Create 3D Canvas pane
	id2 := feature.multiplexer_create_3d_pane(&m)
	testing.expect_value(t, id2, u32(2))

	p2 := feature.multiplexer_get_pane(&m, id2)
	testing.expect(t, p2 != nil, "Pane 2 not found")
	testing.expect_value(t, p2.kind, feature.Pane_Kind.Three_D)
	testing.expect(t, p2.session == nil, "3D pane should have nil session")

	// 3. Focus cycling
	next_f := feature.multiplexer_cycle_focus(&m, forward = true)
	testing.expect_value(t, next_f, u32(2))
	testing.expect_value(t, m.focused_pane_id, u32(2))

	next_b := feature.multiplexer_cycle_focus(&m, forward = false)
	testing.expect_value(t, next_b, u32(1))
	testing.expect_value(t, m.focused_pane_id, u32(1))

	// 4. Zoom toggle
	zoomed := feature.multiplexer_toggle_zoom(&m, id1)
	testing.expect(t, zoomed, "Zoom should be active")
	testing.expect_value(t, m.zoomed_pane_id, id1)

	unzoomed := feature.multiplexer_toggle_zoom(&m, id1)
	testing.expect(t, !unzoomed, "Zoom should be deactivated")
	testing.expect_value(t, m.zoomed_pane_id, u32(0))

	// 5. Close pane
	ok_close := feature.multiplexer_close_pane(&m, id1)
	testing.expect(t, ok_close, "Close pane 1 failed")
	testing.expect_value(t, len(m.panes), 1)
	testing.expect_value(t, m.focused_pane_id, id2)
}

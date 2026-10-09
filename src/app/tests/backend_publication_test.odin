package app_test

import "core:testing"
import app "../"

Publication_Probe :: struct {
	b: ^app.Backend,
	calls: int,
	lock_available: bool,
	snapshot_visible: bool,
}

_publication_notify :: proc(user_data: rawptr) {
	p := cast(^Publication_Probe)user_data
	p.calls += 1
	p.lock_available = true
	app.backend_refresh_snapshot(p.b)
	snap := app.backend_snapshot(p.b)
	p.snapshot_visible = snap != nil &&
		snap.focused == p.b.focused &&
		snap.exited == (p.b.pty.state == .Exited) &&
		snap.search_invalid_regex == p.b.search_invalid_regex
}

@(test)
test_backend_publication_notifies_after_unlock :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	b.middle = 1
	b.write_index = 0
	b.reader.read_index = 2
	p := Publication_Probe{b = b}
	app.backend_set_notify_data_ready(b, &p, _publication_notify)
	for focused in ([]bool{true, false}) {
		b.focused = focused
		b.pty.state = .Exited
		b.search_invalid_regex = !focused
		previous_calls := p.calls
		app._backend_swap_buffers(b)
		testing.expect_value(t, p.calls, previous_calls + 1)
		testing.expect(t, p.lock_available, "notification must run outside the snapshot mutex")
		testing.expect(t, p.snapshot_visible, "notification must observe the published snapshot")
	}
	app.backend_set_notify_data_ready(b, nil, nil)
	app._backend_swap_buffers(b)
	app._backend_swap_buffers(nil)
	testing.expect_value(t, p.calls, 2)
}

@(test)
test_backend_locked_publication_does_not_notify :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
	b.middle = 1
	b.write_index = 0
	b.reader.read_index = 2
	p := Publication_Probe{b = b}
	app.backend_set_notify_data_ready(b, &p, _publication_notify)
	b.focused = true
	app.backend_publish_snapshot(b)
	testing.expect_value(t, p.calls, 0)
	app.backend_refresh_snapshot(b)
	testing.expect(t, app.backend_snapshot(b).focused, "publish helper must still publish the snapshot")
}

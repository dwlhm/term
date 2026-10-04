package app_test

import "core:sync"
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
	p.lock_available = sync.mutex_try_lock(&p.b.swap_mutex)
	if p.lock_available {
		p.snapshot_visible = p.b.front_focused == p.b.focused &&
			p.b.front_exited == (p.b.pty.state == .Exited) &&
			p.b.front_search_invalid_regex == p.b.search_invalid_regex
		sync.mutex_unlock(&p.b.swap_mutex)
	}
}

@(test)
test_backend_publication_notifies_after_unlock :: proc(t: ^testing.T) {
	b := new(app.Backend)
	defer free(b)
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
	p := Publication_Probe{b = b}
	app.backend_set_notify_data_ready(b, &p, _publication_notify)
	b.focused = true
	sync.mutex_lock(&b.swap_mutex)
	app._backend_perform_swap_locked(b)
	sync.mutex_unlock(&b.swap_mutex)
	testing.expect_value(t, p.calls, 0)
	testing.expect(t, b.front_focused, "locked helper must still publish the snapshot")
}

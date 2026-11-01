package feature_session_tests

// Behavioral unit tests for the background-session registry (the viewer's
// mirror of core rows it does not show).

import "core:testing"
import session "../"

@test
test_registry_mirrors_background_rows :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	testing.expect(t, session.session_registry_apply_row(&reg, {id = 1, state = .Busy, pid = 9, title = "make", cwd = "/src"}, false))
	testing.expect_value(t, session.session_registry_count(&reg), 1)
	e := session.session_registry_find(&reg, 1)
	testing.expect(t, e != nil && e.state == .Busy && e.pid == 9)
	if e != nil do testing.expect_value(t, session.registry_text(&e.title), "make")

	// A session this viewer shows is not a background one.
	testing.expect(t, session.session_registry_apply_row(&reg, {id = 1, state = .Busy}, true))
	testing.expect_value(t, session.session_registry_count(&reg), 0)
}

@test
test_registry_attention_on_finish_and_exit :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	session.session_registry_apply_row(&reg, {id = 7, state = .Busy}, false)
	session.session_registry_apply_row(&reg, {id = 8, state = .Idle}, false)
	testing.expect_value(t, session.session_registry_attention_count(&reg), 0)
	session.session_registry_apply_row(&reg, {id = 7, state = .Idle}, false)
	session.session_registry_apply_row(&reg, {id = 8, state = .Exited}, false)
	testing.expect_value(t, session.session_registry_attention_count(&reg), 2)
	testing.expect(t, session.session_registry_clear_attention(&reg), "clear must report a cleared flag")
	testing.expect_value(t, session.session_registry_attention_count(&reg), 0)
	testing.expect(t, session.session_registry_remove(&reg, 7))
	testing.expect(t, !session.session_registry_remove(&reg, 7), "second remove finds nothing")
	testing.expect_value(t, session.session_registry_count(&reg), 1)
}

@test
test_registry_long_text_is_truncated_not_overflowed :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)
	long: [1024]u8
	for &b in long do b = 'x'
	session.session_registry_apply_row(&reg, {id = 2, state = .Idle, title = string(long[:])}, false)
	e := session.session_registry_find(&reg, 2)
	testing.expect(t, e != nil && len(session.registry_text(&e.title)) == len(e.title.buf))
}

@test
test_registry_nil_safe :: proc(t: ^testing.T) {
	testing.expect(t, !session.session_registry_remove(nil, 1))
	testing.expect(t, session.session_registry_find(nil, 1) == nil)
	testing.expect_value(t, session.session_registry_count(nil), 0)
}

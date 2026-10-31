package feature_session_tests

// Behavioral unit tests for the Detached Background Session Registry.

import "core:testing"
import "core:time"
import session "../"

@test
test_registry_detach_pop_live :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	sess, err := session.session_create(session.Session_Config{shell = "/bin/sh", rows = 24, cols = 80})
	testing.expect(t, err == .None, "session_create failed")
	testing.expect(t, sess != nil, "session_create returned nil session")

	ok := session.session_registry_detach(&reg, 1, sess)
	testing.expect(t, ok, "detach must succeed")
	testing.expect_value(t, session.session_registry_count(&reg), 1)

	entry := session.session_registry_find(&reg, 1)
	testing.expect(t, entry != nil, "find must return the detached entry")
	if entry != nil {
		testing.expect(t, entry.state != .Exited, "fresh session must not be .Exited")
	}

	popped, found := session.session_registry_pop(&reg, 1)
	testing.expect(t, found, "pop must find the live entry")
	testing.expect_value(t, popped, sess)
	testing.expect_value(t, session.session_registry_count(&reg), 0)
	session.session_destroy(popped)
}

@test
test_registry_exited_entry :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	sess, err := session.session_create(session.Session_Config{shell = "/bin/sh", rows = 24, cols = 80})
	testing.expect(t, err == .None, "session_create failed")
	testing.expect(t, sess != nil, "session_create returned nil session")

	ok := session.session_registry_detach(&reg, 7, sess)
	testing.expect(t, ok, "detach must succeed")

	_, _ = session.session_write_string(sess, "exit\n")

	start := time.now()
	exited := false
	for time.since(start) < 2 * time.Second {
		session.session_drain(sess)
		session.session_registry_poll(&reg, true)
		entry := session.session_registry_find(&reg, 7)
		if entry != nil && entry.state == .Exited {
			exited = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, exited, "session must reach .Exited within 2s")
	testing.expect_value(t, session.session_registry_attention_count(&reg), 1)

	popped, found := session.session_registry_pop(&reg, 7)
	testing.expect(t, !found, "pop must refuse an .Exited entry")
	testing.expect(t, popped == nil, "pop must return nil for an .Exited entry")
	testing.expect_value(t, session.session_registry_count(&reg), 1)

	testing.expect(t, session.session_registry_clear_attention(&reg), "clear must report a cleared flag")
	testing.expect_value(t, session.session_registry_attention_count(&reg), 0)

	testing.expect(t, session.session_registry_remove(&reg, 7), "remove must dismiss the entry")
	testing.expect_value(t, session.session_registry_count(&reg), 0)
}

@test
test_registry_remove_unknown_and_nil :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	testing.expect(t, !session.session_registry_remove(&reg, 999), "unknown remove must fail")
	testing.expect(t, session.session_registry_find(&reg, 999) == nil, "unknown find must be nil")

	testing.expect(t, !session.session_registry_remove(nil, 1), "nil remove must fail")
	testing.expect(t, session.session_registry_find(nil, 1) == nil, "nil find must be nil")
	testing.expect(t, !session.session_registry_detach(nil, 1, nil), "nil detach must fail")

	popped, found := session.session_registry_pop(nil, 1)
	testing.expect(t, !found, "nil pop must report not found")
	testing.expect(t, popped == nil, "nil pop must return nil")

	testing.expect(t, !session.session_registry_poll(nil, true), "nil poll must report no change")
	testing.expect_value(t, session.session_registry_attention_count(nil), 0)
	testing.expect(t, !session.session_registry_clear_attention(nil), "nil clear must report false")
	testing.expect_value(t, session.session_registry_count(nil), 0)
	session.session_registry_destroy(nil)
}

@test
test_registry_busy_to_idle_attention :: proc(t: ^testing.T) {
	reg: session.Session_Registry
	session.session_registry_init(&reg)
	defer session.session_registry_destroy(&reg)

	sess, err := session.session_create(session.Session_Config{shell = "/bin/sh", rows = 24, cols = 80})
	testing.expect(t, err == .None, "session_create failed")
	testing.expect(t, sess != nil, "session_create returned nil session")

	sess.command_running = true
	sess.in_prompt = false
	ok := session.session_registry_detach(&reg, 9, sess)
	testing.expect(t, ok, "detach must succeed")

	session.session_registry_poll(&reg, true)
	entry := session.session_registry_find(&reg, 9)
	testing.expect(t, entry != nil, "find must return the entry")
	if entry != nil {
		testing.expect_value(t, entry.state, session.Detached_Session_State.Busy)
	}
	testing.expect_value(t, session.session_registry_attention_count(&reg), 0)

	sess.command_running = false
	sess.in_prompt = true
	testing.expect(t, session.session_registry_poll(&reg, true), "Busy→Idle must report a change")
	entry = session.session_registry_find(&reg, 9)
	if entry != nil {
		testing.expect_value(t, entry.state, session.Detached_Session_State.Idle)
	}
	testing.expect_value(t, session.session_registry_attention_count(&reg), 1)

	testing.expect(t, !session.session_registry_poll(&reg, false), "poll without output must not change state")
}

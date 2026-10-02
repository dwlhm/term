package session_core_test

import "core:strings"
import "core:testing"

import session_core "../"
import termgrid "../../terminal"
import parser "../../parser"

@(test)
test_session_registry_init_and_destroy :: proc(t: ^testing.T) {
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	testing.expect_value(t, len(reg.sessions), 0)
	testing.expect_value(t, len(reg.detached_order), 0)
	session_core.session_registry_destroy(&reg)
}

@(test)
test_session_registry_register_and_lookup :: proc(t: ^testing.T) {
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	defer session_core.session_registry_destroy(&reg)

	s1 := new(session_core.Core_Session)
	s1.id = strings.clone("sess_1")
	termgrid.terminal_init(&s1.term, 24, 80)
	parser.parser_init(&s1.vt_parser)

	ok := session_core.session_registry_register(&reg, s1)
	testing.expect(t, ok, "registration of s1 must succeed")

	// Duplicate registration must fail
	dup_ok := session_core.session_registry_register(&reg, s1)
	testing.expect(t, !dup_ok, "duplicate registration must fail")

	found := session_core.session_registry_lookup(&reg, "sess_1")
	testing.expect(t, found == s1, "lookup must find s1")

	not_found := session_core.session_registry_lookup(&reg, "non_existent")
	testing.expect(t, not_found == nil, "lookup for unknown session must return nil")
}

@(test)
test_session_registry_detach_and_pop :: proc(t: ^testing.T) {
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	defer session_core.session_registry_destroy(&reg)

	s1 := new(session_core.Core_Session)
	s1.id = strings.clone("sess_1")
	s1.is_detached = true
	termgrid.terminal_init(&s1.term, 24, 80)
	parser.parser_init(&s1.vt_parser)

	s2 := new(session_core.Core_Session)
	s2.id = strings.clone("sess_2")
	s2.is_detached = true
	termgrid.terminal_init(&s2.term, 24, 80)
	parser.parser_init(&s2.vt_parser)

	s3 := new(session_core.Core_Session)
	s3.id = strings.clone("sess_3")
	s3.is_detached = false
	termgrid.terminal_init(&s3.term, 24, 80)
	parser.parser_init(&s3.vt_parser)

	testing.expect(t, session_core.session_registry_register(&reg, s1))
	testing.expect(t, session_core.session_registry_register(&reg, s2))
	testing.expect(t, session_core.session_registry_register(&reg, s3))

	// List detached: should only contain sess_2 and sess_1 (s3 is not detached)
	out: [4]string
	count := session_core.session_registry_list_detached(&reg, out[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, out[0], "sess_2")
	testing.expect_value(t, out[1], "sess_1")

	// Pop latest detached: sess_2 was detached after sess_1
	popped := session_core.session_registry_pop_latest_detached(&reg)
	testing.expect(t, popped == s2, "popped session must be s2")
	testing.expect(t, !popped.is_detached, "popped session is_detached must become false")

	// Remaining detached: sess_1
	count2 := session_core.session_registry_list_detached(&reg, out[:])
	testing.expect_value(t, count2, 1)
	testing.expect_value(t, out[0], "sess_1")

	popped2 := session_core.session_registry_pop_latest_detached(&reg)
	testing.expect(t, popped2 == s1, "second popped session must be s1")
	testing.expect(t, !popped2.is_detached, "second popped session is_detached must become false")

	popped3 := session_core.session_registry_pop_latest_detached(&reg)
	testing.expect(t, popped3 == nil, "no more detached sessions to pop")

	// Cleanup popped sessions that were removed from registry
	session_core.session_destroy(s1)
	free(s1)
	session_core.session_destroy(s2)
	free(s2)
}

@(test)
test_session_registry_unregister :: proc(t: ^testing.T) {
	reg: session_core.Session_Registry
	session_core.session_registry_init(&reg)
	defer session_core.session_registry_destroy(&reg)

	s := new(session_core.Core_Session)
	s.id = strings.clone("sess_unreg")
	s.is_detached = true
	termgrid.terminal_init(&s.term, 24, 80)
	parser.parser_init(&s.vt_parser)

	session_core.session_registry_register(&reg, s)
	testing.expect(t, session_core.session_registry_lookup(&reg, "sess_unreg") != nil)

	unreg := session_core.session_registry_unregister(&reg, "sess_unreg")
	testing.expect(t, unreg == s, "unregister must return s")
	testing.expect(t, session_core.session_registry_lookup(&reg, "sess_unreg") == nil)

	// Clean up unreg
	session_core.session_destroy(unreg)
	free(unreg)
}

package term

// Tests W1–W3: term session whoami (spec 4.8).

import "core:os"
import "core:strings"
import "core:testing"
import proto "../../features/session_proto"

@(test)
test_W2_whoami_outside_term_fails :: proc(t: ^testing.T) {
	// Unset TERM_SESSION_ID
	orig := os.get_env(proto.SESSION_ID_ENV, context.temp_allocator)
	defer {
		if len(orig) > 0 {
			os.set_env(proto.SESSION_ID_ENV, orig)
		}
	}
	os.unset_env(proto.SESSION_ID_ENV)

	code := _agent_whoami(nil)
	testing.expect_value(t, code, 1)
}

@(test)
test_W3_whoami_bogus_env_rejected :: proc(t: ^testing.T) {
	orig := os.get_env(proto.SESSION_ID_ENV, context.temp_allocator)
	defer {
		if len(orig) > 0 {
			os.set_env(proto.SESSION_ID_ENV, orig)
		} else {
			os.unset_env(proto.SESSION_ID_ENV)
		}
	}

	// Non-numeric id
	os.set_env(proto.SESSION_ID_ENV, "bogus")
	code := _agent_whoami(nil)
	testing.expect_value(t, code, 1)

	// Negative id
	os.set_env(proto.SESSION_ID_ENV, "-1")
	code = _agent_whoami(nil)
	testing.expect_value(t, code, 1)
}

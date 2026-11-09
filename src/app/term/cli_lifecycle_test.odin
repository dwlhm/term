package term

// CLI pre-validation tests for lifecycle verbs
// (spec 4.1–4.8, U1–U7, N3, N7, N9, A2).

import "core:strings"
import "core:testing"
import proto "../../features/session_proto"

@(test)
test_U1_unknown_verb_lists_verbs :: proc(t: ^testing.T) {
	handled, code := app_cli_agent([]string{"bogus_verb"})
	testing.expect(t, handled, "handled unknown verb")
	testing.expect_value(t, code, 1)
}

@(test)
test_U4_bad_session_id_rejected :: proc(t: ^testing.T) {
	bad_ids := []string{"abc", "-1", "0", "99999999999"}
	for id_str in bad_ids {
		_, _, ok := _agent_target([]string{"kill", id_str})
		testing.expect(t, !ok, "invalid id rejected")
	}
}

@(test)
test_N3_new_nonexistent_directory_rejected :: proc(t: ^testing.T) {
	spec: proto.Spawn_Msg
	ok := app_cli_parse_new([]string{"-d", "/nonexistent/dir/path"}, &spec)
	testing.expect(t, !ok, "nonexistent directory rejected")
}

@(test)
test_N9_new_env_without_equals_rejected :: proc(t: ^testing.T) {
	spec: proto.Spawn_Msg
	ok := app_cli_parse_new([]string{"-e", "NO_EQUALS_SIGN"}, &spec)
	testing.expect(t, !ok, "env without equals rejected")
}

@(test)
test_U5_ls_invalid_output_format_rejected :: proc(t: ^testing.T) {
	code := app_cli_session_ls([]string{"--output", "xml"})
	testing.expect_value(t, code, 1)
}

@(test)
test_A2_attach_no_window_fails :: proc(t: ^testing.T) {
	handled, code := app_run_control_cli(
		[]string{"term", "session", "attach", "1"},
	)
	testing.expect(t, handled)
	testing.expect_value(t, code, 1)
}

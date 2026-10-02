package session_core_test

import "core:strings"
import "core:testing"
import "core:os"
import "core:fmt"
import "core:path/filepath"
import "core:c"
import "core:strconv"
import "core:time"
import posix "core:sys/posix"

import session_core "../"
import termgrid "../../terminal"
import parser "../../parser"

@(test)
test_headless_shell_bootstrap_clean_output :: proc(t: ^testing.T) {
	for shell in ([]string{"/bin/zsh", "/bin/bash", "/bin/sh"}) {
		if !os.exists(shell) do continue
		s, ok := session_core.session_create(shell, {shell = shell, mode = .Fast_Headless})
		if !testing.expect(t, ok, shell) do continue
		defer free(s)
		defer session_core.session_destroy(s)
		for command in ([]string{"printf 'first_output\\n'", "printf 'second_output\\n'"}) {
			output, exit_code, completed, _, _ := session_core.session_run_command(s, command)
			defer delete(output)
			testing.expect(t, completed, shell)
			testing.expect_value(t, exit_code, 0)
			expected := "first_output" if strings.contains(command, "first") else "second_output"
			testing.expect(t, output == expected, fmt.tprintf("%s: expected %q, got %q", shell, expected, output))
		}
	}
}

@(test)
test_headless_delayed_shell_bootstrap :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "term-headless-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer os.remove_all(root)
	shell, _ := filepath.join({root, "delayed-sh"})
	defer delete(shell)
	// Deliberately delay shell execution to force startup echo to arrive after the old drain budget.
	fixture :: "#!/bin/sh\n/bin/sleep 0.1\nexec /bin/sh\n"
	if !testing.expect(t, os.write_entire_file(shell, string(fixture)) == nil) do return
	if !testing.expect(t, os.chmod(shell, {.Read_User, .Write_User, .Execute_User}) == nil) do return
	s, ok := session_core.session_create("delayed", {shell = shell, mode = .Fast_Headless})
	if !testing.expect(t, ok) do return
	defer free(s)
	defer session_core.session_destroy(s)
	output, exit_code, completed, _, _ := session_core.session_run_command(s, "printf 'delayed_output\\n'")
	defer delete(output)
	testing.expect(t, completed)
	testing.expect_value(t, exit_code, 0)
	testing.expect_value(t, output, "delayed_output")
}

@(test)
test_headless_shell_exit_before_ready :: proc(t: ^testing.T) {
	s, ok := session_core.session_create("exited", {shell = "/usr/bin/true", mode = .Fast_Headless})
	if s != nil {
		session_core.session_destroy(s)
		free(s)
	}
	testing.expect(t, !ok, "shell exit before readiness must fail creation")
	testing.expect(t, s == nil, "failed creation must not expose a session")
}

@(test)
test_headless_readiness_timeout_reaps_child :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "term-headless-timeout-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer os.remove_all(root)
	shell, _ := filepath.join({root, "unready-sh"})
	defer delete(shell)
	fixture :: "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nexec /bin/sleep 30\n"
	if !testing.expect(t, os.write_entire_file(shell, string(fixture)) == nil) do return
	if !testing.expect(t, os.chmod(shell, {.Read_User, .Write_User, .Execute_User}) == nil) do return
	start := time.now()
	s, ok := session_core.session_create("unready", {shell = shell, mode = .Fast_Headless})
	elapsed := time.diff(start, time.now())
	if s != nil {
		session_core.session_destroy(s)
		free(s)
	}
	testing.expect(t, !ok && s == nil, "unacknowledged startup must fail without exposing a session")
	timeout := session_core.HEADLESS_BOOTSTRAP_TIMEOUT_MS * time.Millisecond
	testing.expect(t, elapsed >= timeout && elapsed < 2 * timeout, "startup must stop within its timeout budget")
	pid_path := fmt.aprintf("%s.pid", shell)
	defer delete(pid_path)
	data, read_err := os.read_entire_file(pid_path, context.allocator)
	if !testing.expect(t, read_err == nil) do return
	defer delete(data)
	pid, parsed := strconv.parse_int(string(data))
	if !testing.expect(t, parsed && pid > 1) do return
	status: c.int
	waited := posix.waitpid(posix.pid_t(pid), &status, {.NOHANG})
	testing.expect(t, waited == -1 && posix.errno() == .ECHILD, "failed startup must reap its child")
}

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

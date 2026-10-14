package feature_session_tests

import "core:testing"
import "core:time"
import session "../"

@test
test_session_lifecycle_and_drain :: proc(t: ^testing.T) {
	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	testing.expect(t, err == .None, "session_create failed")
	testing.expect(t, sess != nil, "sess is nil")
	defer session.session_destroy(sess)

	// Write command to real shell
	_, w_err := session.session_write_string(sess, "echo REAL_SESSION_OK\n")
	testing.expect(t, w_err == .None, "session_write failed")

	// Wait and drain output
	found := false
	start := time.now()

	for time.since(start) < 800 * time.Millisecond {
		n := session.session_drain(sess)
		if n > 0 {
			// Scan row 0 to 5 for "REAL_SESSION_OK"
			for r in 0..<5 {
				line_chars: [80]u8
				for c in 0..<80 {
					ch := session.session_get_cell(sess, r, c).char
					line_chars[c] = u8(ch) if ch >= 32 && ch <= 126 else ' '
				}
				s := string(line_chars[:])
				if contains_substring(s, "REAL_SESSION_OK") {
					found = true
					break
				}
			}
			if found do break
		}
		time.sleep(20 * time.Millisecond)
	}

	testing.expect(t, found, "Expected 'REAL_SESSION_OK' rendered on terminal grid from live PTY")
}

contains_substring :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 do return true
	if len(haystack) < len(needle) do return false
	for i in 0..=(len(haystack) - len(needle)) {
		if haystack[i : i + len(needle)] == needle {
			return true
		}
	}
	return false
}

@test
test_session_osc_extensions :: proc(t: ^testing.T) {
	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	testing.expect(t, err == .None, "session_create failed")
	defer session.session_destroy(sess)

	// Test OSC 0 Title
	session.session_write_string(sess, "printf '\\033]0;My Cool Window\\007'\n")
	// Test OSC 7 Working Directory
	session.session_write_string(sess, "printf '\\033]7;file:///Users/dwlhm/project/term\\007'\n")
	// Test OSC 133 Prompt Start
	session.session_write_string(sess, "printf '\\033]133;A\\007'\n")

	start := time.now()
	for time.since(start) < 600 * time.Millisecond {
		session.session_drain(sess)
		if session.session_get_title(sess) == "My Cool Window" &&
		   session.session_get_cwd(sess) == "file:///Users/dwlhm/project/term" &&
		   session.session_is_in_prompt(sess) {
			break
		}
		time.sleep(20 * time.Millisecond)
	}

	testing.expect_value(t, session.session_get_title(sess), "My Cool Window")
	testing.expect_value(t, session.session_get_cwd(sess), "file:///Users/dwlhm/project/term")
	testing.expect(t, session.session_is_in_prompt(sess), "Expected in_prompt == true from OSC 133;A")
}

@test
test_session_resize :: proc(t: ^testing.T) {
	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	testing.expect(t, err == .None, "session_create failed")
	defer session.session_destroy(sess)

	session.session_resize(sess, 120, 40)
	testing.expect_value(t, sess.term.cols, 120)
	testing.expect_value(t, sess.term.rows, 40)
	testing.expect_value(t, sess.pty.cols, 120)
	testing.expect_value(t, sess.pty.rows, 40)
}

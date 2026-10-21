package feature_session_tests

import "core:testing"
import "core:time"
import "core:strings"
import session "../"
import extension "../../../core/terminal/extension"

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
	testing.expect_value(t, session.session_get_cwd_path(sess), "/Users/dwlhm/project/term")
	testing.expect(t, session.session_is_in_prompt(sess), "Expected in_prompt == true from OSC 133;A")

	// Test OSC 52 Clipboard Sink
	copied_clipboard: string
	session.session_set_clipboard_sink(sess, proc(user_data: rawptr, text: string) -> bool {
		s_ptr := (^string)(user_data)
		s_ptr^ = strings.clone(text)
		return true
	}, &copied_clipboard)

	session.session_write_string(sess, "printf '\\033]52;c;TmVvdmltQ2xpcA==\\007'\n")
	start = time.now()
	for time.since(start) < 600 * time.Millisecond {
		session.session_drain(sess)
		if copied_clipboard == "NeovimClip" do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, copied_clipboard, "NeovimClip")
	delete(copied_clipboard)

	// Test OSC 22 Pointer Shape
	session.session_write_string(sess, "printf '\\033]22;pointer\\007'\n")
	// Test OSC 1337 ScrollSpeed
	session.session_write_string(sess, "printf '\\033]1337;ScrollSpeed=0.75\\007'\n")

	start = time.now()
	for time.since(start) < 600 * time.Millisecond {
		session.session_drain(sess)
		if session.session_get_pointer_shape(sess) == "pointer" && sess.custom_scroll_speed == 0.75 do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, session.session_get_pointer_shape(sess), "pointer")
	testing.expect_value(t, sess.custom_scroll_speed, 0.75)
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

@test
test_session_title_resolution :: proc(t: ^testing.T) {
	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	testing.expect(t, err == .None, "session_create failed")
	defer session.session_destroy(sess)

	time.sleep(50 * time.Millisecond)

	buf: [256]u8
	title := session.session_resolve_title(sess, buf[:], "Fallback")
	testing.expect(t, len(title) > 0, "Resolved title should not be empty")

	// When OSC 0 is sent, it overrides process/cwd
	copy(sess.title_buf[:10], "Custom OSC")
	sess.title_len = 10
	osc_title := session.session_resolve_title(sess, buf[:], "Fallback")
	testing.expect_value(t, osc_title, "Custom OSC")
}

@test
test_session_kitty_graphics_stream :: proc(t: ^testing.T) {
	cfg := session.Session_Config{
		shell = "/bin/sh",
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	testing.expect(t, err == .None, "session_create failed")
	defer session.session_destroy(sess)

	// Stream 2x2 RGBA image via printf in live shell over PTY
	cmd := "printf '\\033_Ga=T,i=400,f=32,s=2,v=2,m=1;AAAA\\033\\\\\\033_Gm=0;AAAA\\033\\\\'\n"
	_, w_err := session.session_write_string(sess, cmd)
	testing.expect(t, w_err == .None, "session_write_string failed")

	start := time.now()
	found_image := false
	for time.since(start) < 800 * time.Millisecond {
		session.session_drain(sess)
		for i in 0..<sess.term.extensions.ext_count {
			e := &sess.term.extensions.extensions[i]
			if e.name == "kitty_graphics" && e.user_data != nil {
				img := extension.kitty_graphics_get_image(e.user_data, 400)
				if img != nil && img.is_active {
					found_image = true
					break
				}
			}
		}
		if found_image do break
		time.sleep(20 * time.Millisecond)
	}

	testing.expect(t, found_image, "Image 400 must be streamed and activated via live PTY session")
}

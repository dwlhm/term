package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import session "../../features/session"

main :: proc() {
	fmt.println("=================================================================")
	fmt.println(" Term Live Session Demo (core_platform/pty + core_terminal)")
	fmt.println("=================================================================")

	shell_path := os.get_env("SHELL", context.temp_allocator)
	if len(shell_path) == 0 {
		shell_path = "/bin/sh"
	}
	fmt.printfln("[1] Spawning live shell: %s", shell_path)

	cfg := session.Session_Config{
		shell = shell_path,
		rows  = 24,
		cols  = 80,
	}

	sess, err := session.session_create(cfg)
	if err != .None {
		fmt.eprintfln("Failed to spawn session: %v", err)
		return
	}
	defer session.session_destroy(sess)

	fmt.println("[2] Shell process successfully spawned! PTY master connected.")
	fmt.println("[3] Executing test commands through PTY stream...")

	// 1. Send test command
	session.session_write_string(sess, "echo '=== Hello from inside core_terminal ==='\n")
	session.session_write_string(sess, "pwd\n")
	session.session_write_string(sess, "printf '\\033]0;Term Demo Title\\007'\n") // OSC 0 test
	session.session_write_string(sess, "printf '\\033]7;file:///workspace/demo\\007'\n") // OSC 7 test

	// Wait and drain
	time.sleep(250 * time.Millisecond)
	drained := session.session_drain(sess)
	fmt.printfln("[4] Drained %d bytes from PTY master into core_terminal grid.", drained)

	// Display captured OSC extension state
	fmt.printfln("    -> Captured OSC 0 Title : '%s'", session.session_get_title(sess))
	fmt.printfln("    -> Captured OSC 7 CWD   : '%s'", session.session_get_cwd(sess))

	// Print visual grid snapshot (first 10 non-empty rows)
	fmt.println("\n[5] Visual Snapshot of Terminal Grid (from core_terminal):")
	fmt.println("-----------------------------------------------------------------")
	for r in 0..<12 {
		line_chars: [80]u8
		has_content := false
		for c in 0..<80 {
			ch := session.session_get_cell(sess, r, c).char
			line_chars[c] = u8(ch) if (ch >= 32 && ch <= 126) else ' '
			if line_chars[c] != ' ' {
				has_content = true
			}
		}
		if has_content {
			line_str := strings.trim_right_space(string(line_chars[:]))
			fmt.printfln(" Row %2d | %s", r, line_str)
		}
	}
	fmt.println("-----------------------------------------------------------------")
	fmt.println("Demo completed successfully! All data parsed by scalar VT machine.")
}

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import session "../../features/session"
import client_feat "../../features/session_client"

main :: proc() {
	if handled, code := client_feat.client_tier_main(os.args); handled do os.exit(code)
	if !client_feat.client_use_private_session() do os.exit(1)
	client := new(client_feat.Client)
	defer free(client)
	if !client_feat.client_connect(client, nil, nil) {
		fmt.eprintln("Failed to start the session core")
		return
	}
	defer client_feat.client_disconnect(client)
	fmt.println("=================================================================")
	fmt.println(" Term Live Session Demo (holder + core + viewer Terminal)")
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

	sess := client_feat.client_spawn(client, cfg)
	if sess == nil {
		fmt.eprintln("Failed to spawn session")
		return
	}
	defer client_feat.client_release(client, sess, true)

	fmt.println("[2] Shell session started in the core; this Terminal is its viewer.")
	fmt.println("[3] Executing test commands through the session stream...")

	// 1. Send test command
	session.session_write_string(sess, "echo '=== Hello from inside core_terminal ==='\n")
	session.session_write_string(sess, "pwd\n")
	session.session_write_string(sess, "printf '\\033]0;Term Demo Title\\007'\n") // OSC 0 test
	session.session_write_string(sess, "printf '\\033]7;file:///workspace/demo\\007'\n") // OSC 7 test

	// Wait and drain
	drained := 0
	for _ in 0..<25 {
		time.sleep(20 * time.Millisecond)
		client_feat.client_pump(client)
		drained += session.session_drain(sess)
	}
	fmt.printfln("[4] Drained %d bytes from the core into the viewer Terminal grid.", drained)

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

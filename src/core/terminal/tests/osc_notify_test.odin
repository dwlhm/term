package terminal_tests

import "core:strings"
import "core:testing"
import term "../"
import extension "../extension"

Notification_Capture :: struct {
	called:    bool,
	call_cnt:  int,
	last_notif: extension.Terminal_Notification,
}

_test_notify_sink :: proc(user_data: rawptr, notif: extension.Terminal_Notification) -> bool {
	cap := (^Notification_Capture)(user_data)
	if cap == nil do return false
	cap.called = true
	cap.call_cnt += 1
	cap.last_notif = notif
	return true
}

@ (test)
test_osc_9_iterm2_and_conemu_conformance :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	cap := Notification_Capture{}
	ctx := extension.Osc_Notify_Context{
		sink      = _test_notify_sink,
		user_data = rawptr(&cap),
	}

	term.terminal_register_osc(&terminal, extension.OSC_NOTIFY_9, extension.osc_9_handler, rawptr(&ctx))

	// 1. Standard iTerm2 with BEL (\x07) terminator
	term.terminal_feed_string(&terminal, "\x1b]9;Build Succeeded\x07")
	testing.expect(t, cap.called, "OSC 9 with BEL should trigger sink")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "Build Succeeded")
	testing.expect_value(t, extension.terminal_notification_title(&cap.last_notif), "")

	// 2. Standard iTerm2 with ST (\x1b\\) terminator
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]9;All unit tests passed\x1b\\")
	testing.expect(t, cap.called, "OSC 9 with ST should trigger sink")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "All unit tests passed")

	// 3. ConEmu variation with '1;' prefix
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]9;1;ConEmu Task Complete\x07")
	testing.expect(t, cap.called, "OSC 9 with ConEmu 1; prefix should trigger sink")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "ConEmu Task Complete")

	// 4. Sanitization: control characters (< 0x20 except \t) stripped
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]9;Hello\x00\x01\x02\x0eWorld\t!\x07")
	testing.expect(t, cap.called, "OSC 9 with control chars should trigger sink")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "HelloWorld\t!")

	// 5. Empty payload should not trigger sink
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]9;\x07")
	testing.expect(t, !cap.called, "Empty OSC 9 should not trigger sink")
}

@ (test)
test_osc_777_urxvt_conformance :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	cap := Notification_Capture{}
	ctx := extension.Osc_Notify_Context{
		sink      = _test_notify_sink,
		user_data = rawptr(&cap),
	}

	term.terminal_register_osc(&terminal, extension.OSC_NOTIFY_777, extension.osc_777_handler, rawptr(&ctx))

	// 1. Standard urxvt notify with BEL (\x07)
	term.terminal_feed_string(&terminal, "\x1b]777;notify;Compiler;All 42 targets built\x07")
	testing.expect(t, cap.called, "OSC 777 notify with BEL should trigger sink")
	testing.expect_value(t, extension.terminal_notification_title(&cap.last_notif), "Compiler")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "All 42 targets built")

	// 2. Standard urxvt notify with ST (\x1b\\)
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]777;notify;Test Runner;Suite passed in 1.2s\x1b\\")
	testing.expect(t, cap.called, "OSC 777 notify with ST should trigger sink")
	testing.expect_value(t, extension.terminal_notification_title(&cap.last_notif), "Test Runner")
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "Suite passed in 1.2s")

	// 3. Non-notify action (e.g. urxvt tab) must be ignored safely
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]777;tab;new\x07")
	testing.expect(t, !cap.called, "Non-notify OSC 777 action must not trigger notification sink")

	// 4. Incomplete notify without title/body
	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]777;notify\x07")
	testing.expect(t, !cap.called, "Incomplete OSC 777 must not trigger notification sink")
}

@ (test)
test_osc_notify_bounds_and_safety :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 24, 80)
	defer term.terminal_destroy(&terminal)

	cap := Notification_Capture{}
	ctx := extension.Osc_Notify_Context{
		sink      = _test_notify_sink,
		user_data = rawptr(&cap),
	}

	term.terminal_register_osc(&terminal, extension.OSC_NOTIFY_9, extension.osc_9_handler, rawptr(&ctx))
	term.terminal_register_osc(&terminal, extension.OSC_NOTIFY_777, extension.osc_777_handler, rawptr(&ctx))

	// Huge payload (2000 chars) exceeding MAX_NOTIFY_BODY_LEN (1024)
	huge_body := strings.repeat("A", 2000)
	defer delete(huge_body)

	term.terminal_feed_string(&terminal, "\x1b]9;")
	term.terminal_feed_string(&terminal, huge_body)
	term.terminal_feed_string(&terminal, "\x07")

	testing.expect(t, cap.called, "Huge OSC 9 payload should trigger sink safely")
	testing.expect_value(t, cap.last_notif.body_len, extension.MAX_NOTIFY_BODY_LEN)

	// Huge title in OSC 777 exceeding MAX_NOTIFY_TITLE_LEN (128)
	huge_title := strings.repeat("T", 300)
	defer delete(huge_title)

	cap.called = false
	term.terminal_feed_string(&terminal, "\x1b]777;notify;")
	term.terminal_feed_string(&terminal, huge_title)
	term.terminal_feed_string(&terminal, ";Short Body\x07")

	testing.expect(t, cap.called, "Huge OSC 777 title should trigger sink safely")
	testing.expect_value(t, cap.last_notif.title_len, extension.MAX_NOTIFY_TITLE_LEN)
	testing.expect_value(t, extension.terminal_notification_body(&cap.last_notif), "Short Body")
}

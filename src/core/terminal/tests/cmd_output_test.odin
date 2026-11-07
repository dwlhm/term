package terminal_tests

// terminal_cmd_output: the text between OSC 133;C and 133;D survives
// scrolling, a reflowing resize and a full-screen program in between.

import "core:fmt"
import "core:strings"
import "core:testing"
import term "../"

@(private = "file")
C :: "\x1b]133;C\x07"
@(private = "file")
D :: "\x1b]133;D;0\x07"
@(private = "file")
PROMPT :: "\x1b]133;A\x07$ \x1b]133;B\x07"

@(private = "file")
feed :: proc(t: ^term.Terminal, s: string) { term.terminal_feed_bytes(t, transmute([]u8)s) }

@(private = "file")
output :: proc(t: ^term.Terminal, to_cursor := false) -> (text: string, ok, head_lost: bool) {
	b := strings.builder_make(context.temp_allocator)
	ok, head_lost = term.terminal_cmd_output(t, &b, to_cursor)
	return strings.to_string(b), ok, head_lost
}

@(test)
test_cmd_output_between_marks :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 6, 20)
	defer term.terminal_destroy(&tm)
	_, ok, _ := output(&tm)
	testing.expect(t, !ok, "no command yet")
	feed(&tm, PROMPT + "ls\r\n" + C + "a\r\nb\r\n" + D + PROMPT) // one chunk, like a fast command
	text, ok2, lost := output(&tm)
	testing.expect(t, ok2 && !lost, "found")
	testing.expect_value(t, text, "a\nb\n")
	feed(&tm, "echo -n x\r\n" + C + "x" + D + "\r\n" + PROMPT)
	text, _, _ = output(&tm)
	testing.expect_value(t, text, "x\n") // no trailing newline: the D line counts
}

@(test)
test_cmd_output_scrolls_and_loses_head :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 5, 20)
	defer term.terminal_destroy(&tm)
	feed(&tm, PROMPT + "seq\r\n" + C)
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 50 do fmt.sbprintf(&b, "line %d\r\n", i)
	feed(&tm, strings.to_string(b))
	partial, _, _ := output(&tm) // still running: up to the cursor
	testing.expect(t, strings.has_prefix(partial, "line 1\n") && strings.has_suffix(partial, "line 50\n"), "partial output")
	feed(&tm, D + PROMPT)
	text, _, lost := output(&tm)
	testing.expect(t, !lost && strings.count(text, "\n") == 50, "50 lines through history")

	feed(&tm, "big\r\n" + C)
	strings.builder_reset(&b)
	for i in 1 ..= 3000 do fmt.sbprintf(&b, "l%d\r\n", i) // past the scrollback
	feed(&tm, strings.to_string(b))
	feed(&tm, D + PROMPT)
	text, _, lost = output(&tm)
	testing.expect(t, lost && strings.has_suffix(text, "l3000\n") && !strings.contains(text, "l1\n"), "tail kept, head lost")
}

@(test)
test_cmd_output_survives_reflow :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 8, 40)
	defer term.terminal_destroy(&tm)
	feed(&tm, "before line one\r\nbefore line two\r\n" + PROMPT + "run\r\n" + C)
	feed(&tm, "0123456789abcdefghij0123456789\r\nshort\r\n")
	term.terminal_resize(&tm, 8, 12) // the long line now wraps over three rows
	feed(&tm, "after\r\n")
	term.terminal_resize(&tm, 5, 50)
	feed(&tm, D + PROMPT)
	text, _, lost := output(&tm)
	testing.expect(t, !lost, "start kept")
	testing.expect_value(t, text, "0123456789abcdefghij0123456789\nshort\nafter\n")
}

@(test)
test_cmd_output_full_screen_in_between :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 6, 20)
	defer term.terminal_destroy(&tm)
	feed(&tm, "x\r\n" + PROMPT + "vim\r\n" + C + "0123456789abcdefghij0123\r\npre\r\n\x1b[?1049hSCREEN")
	feed(&tm, D) // ignored on the alternate screen
	term.terminal_resize(&tm, 6, 8) // reflows the hidden main screen
	partial, ok, lost := output(&tm, to_cursor = true)
	testing.expect(t, ok && !lost, "start followed behind the full-screen program")
	testing.expect_value(t, partial, "0123456789abcdefghij0123\npre\n")
	term.terminal_resize(&tm, 6, 30)
	feed(&tm, "\x1b[?1049lpost\r\n" + D + PROMPT)
	text, _, _ := output(&tm)
	testing.expect_value(t, text, "0123456789abcdefghij0123\npre\npost\n")
}

// Leaving a full-screen program after a resize puts the cursor back on the
// main screen's line, so the next output does not overwrite earlier lines.
@(test)
test_resize_behind_full_screen_restores_cursor_line :: proc(t: ^testing.T) {
	tm: term.Terminal
	term.terminal_init(&tm, 6, 20)
	defer term.terminal_destroy(&tm)
	feed(&tm, "one\r\n0123456789abcdefghij0123\r\ntwo\r\n\x1b[?1049h")
	term.terminal_resize(&tm, 6, 10)
	term.terminal_resize(&tm, 6, 40)
	feed(&tm, "\x1b[?1049lthree")
	b := strings.builder_make(context.temp_allocator)
	term.terminal_text(&tm, &b, 100)
	testing.expect_value(t, strings.to_string(b), "one\n0123456789abcdefghij0123\ntwo\nthree\n")
}

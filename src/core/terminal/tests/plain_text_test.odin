package terminal_tests

import "core:strings"
import "core:testing"
import terminal "../"

@(test)
test_terminal_text_history_wrap_and_trim :: proc(t: ^testing.T) {
	term := new(terminal.Terminal)
	defer free(term)
	terminal.terminal_init(term, 3, 5)
	defer terminal.terminal_destroy(term)
	terminal.terminal_feed_string(term, "one\r\ntwo\r\nabcdefg\r\n")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	terminal.terminal_text(term, &b, 10)
	testing.expect_value(t, strings.to_string(b), "one\ntwo\nabcdefg\n")
	strings.builder_reset(&b)
	terminal.terminal_text(term, &b, 0)
	testing.expect_value(t, strings.to_string(b), "abcdefg\n")
	strings.builder_reset(&b)
	terminal.terminal_feed_string(term, "\x1b[2J\x1b[H")
	terminal.terminal_text(term, &b, 0)
	testing.expect_value(t, strings.to_string(b), "")
}

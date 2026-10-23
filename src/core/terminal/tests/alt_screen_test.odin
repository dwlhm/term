package terminal_tests

// Regression tests for the alternate screen buffer (DEC private modes 47/1047/1049).
//
// The modes used to flip a boolean only: TUI content leaked into the primary
// screen, scrollback was polluted, and leaving the application never restored
// what the user had before.

import "core:testing"
import term "../"
import extension "../extension"

_alt_text_row :: proc(terminal: ^term.Terminal, row: int, cols: int) -> [24]rune {
	res: [24]rune
	for c in 0..<min(cols, 24) {
		res[c] = term.terminal_get_cell(terminal, row, c).char
	}
	return res
}

@test
test_alt_screen_restores_primary_content :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "PRIMARY\x1b[2;1Hsecond line")
	term.terminal_feed_string(&terminal, "\x1b[3;5H*") // cursor at row 2, col 4

	term.terminal_feed_string(&terminal, "\x1b[?1049h\x1b[H\x1b[2JALT-CONTENT")
	testing.expect(t, term.terminal_in_alt_screen(&terminal), "mode 1049 must switch buffers")
	row := _alt_text_row(&terminal, 0, 11)
	testing.expect_value(t, row[0], 'A')

	term.terminal_feed_string(&terminal, "\x1b[?1049l")
	testing.expect(t, !term.terminal_in_alt_screen(&terminal), "mode 1049 must leave the alternate screen")

	first := _alt_text_row(&terminal, 0, 7)
	second := _alt_text_row(&terminal, 1, 11)
	testing.expect_value(t, first[0], 'P')
	testing.expect_value(t, second[0], 's')

	cursor_row, cursor_col := term.terminal_cursor_pos(&terminal)
	testing.expect_value(t, cursor_row, 2)
	testing.expect_value(t, cursor_col, 5) // DECSC restores the post-write cursor
}

@test
test_alt_screen_does_not_pollute_scrollback :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 4, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "primary line\r\n")
	history_before := term.terminal_history_count(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[?1049h")
	for i in 0..<20 do term.terminal_feed_string(&terminal, "alt output line\r\n")
	testing.expect_value(t, term.terminal_history_count(&terminal), 0)

	term.terminal_feed_string(&terminal, "\x1b[?1049l")
	testing.expect_value(t, term.terminal_history_count(&terminal), history_before)
	row := _alt_text_row(&terminal, 0, 12)
	testing.expect_value(t, row[0], 'p')
}

@test
test_mode_47_preserves_alt_content_between_visits :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[?47h\x1b[HKEPT")
	row := _alt_text_row(&terminal, 0, 4)
	testing.expect_value(t, row[0], 'K')

	// Mode 47 keeps the alternate buffer intact across a round trip.
	term.terminal_feed_string(&terminal, "\x1b[?47l")
	term.terminal_feed_string(&terminal, "\x1b[?47h")
	row = _alt_text_row(&terminal, 0, 4)
	testing.expect_value(t, row[0], 'K')
}

@test
test_mode_1047_clears_alt_on_exit :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "\x1b[?1047hSTALE\x1b[?1047l")
	term.terminal_feed_string(&terminal, "\x1b[?1047h")
	row := _alt_text_row(&terminal, 0, 5)
	testing.expect_value(t, row[0], ' ')
}

@test
test_alt_screen_resize_preserves_hidden_primary :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "KEEP-ME")
	term.terminal_feed_string(&terminal, "\x1b[?1049h\x1b[HALT")
	term.terminal_resize(&terminal, 8, 50)
	term.terminal_feed_string(&terminal, "\x1b[?1049l")

	row := _alt_text_row(&terminal, 0, 8)
	testing.expect_value(t, row[0], 'K')
	testing.expect_value(t, row[1], 'E')
}

@test
test_alt_screen_repeated_cycles_keep_primary :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	term.terminal_feed_string(&terminal, "HOME")
	for i in 0..<5 {
		term.terminal_feed_string(&terminal, "\x1b[?1049h\x1b[H\x1b[2Jcycle")
		term.terminal_feed_string(&terminal, "\x1b[?1049l")
	}
	row := _alt_text_row(&terminal, 0, 4)
	testing.expect_value(t, row[0], 'H')
	testing.expect_value(t, row[3], 'E')
}

@test
test_kitty_graphics_retained_across_alt_screen_transitions :: proc(t: ^testing.T) {
	terminal: term.Terminal
	term.terminal_init(&terminal, 6, 40)
	defer term.terminal_destroy(&terminal)

	kitty_ext := extension.kitty_graphics_extension_make()
	term.terminal_register_extension(&terminal, kitty_ext)

	var_kstate: ^extension.Kitty_Extension
	for i in 0..<terminal.extensions.ext_count {
		e := &terminal.extensions.extensions[i]
		if e.name == "kitty_graphics" && e.user_data != nil {
			var_kstate = (^extension.Kitty_Extension)(e.user_data)
			break
		}
	}
	testing.expect(t, var_kstate != nil, "kitty extension must be loaded")

	// 1. Place Image 42 on the primary screen buffer
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=42,s=2,v=2,f=32;AAAA\x1b\\")

	p42_idx := -1
	for i in 0..<len(var_kstate.placements) {
		p := &var_kstate.placements[i]
		if p.is_active && p.image_id == 42 {
			p42_idx = i
			testing.expect_value(t, p.screen, extension.Kitty_Screen.Primary)
			break
		}
	}
	testing.expect(t, p42_idx >= 0, "placement 42 must be active on primary screen")

	// 2. Enter alternate screen (?1049h) - primary screen placement must NOT be cleared!
	term.terminal_feed_string(&terminal, "\x1b[?1049h")
	testing.expect(t, term.terminal_in_alt_screen(&terminal), "must be in alternate screen")
	testing.expect(t, var_kstate.placements[p42_idx].is_active, "image 42 on primary screen must stay preserved")

	// 3. Place Image 99 inside alternate screen
	term.terminal_feed_string(&terminal, "\x1b_Ga=T,i=99,s=2,v=2,f=32;AAAA\x1b\\")
	p99_idx := -1
	for i in 0..<len(var_kstate.placements) {
		p := &var_kstate.placements[i]
		if p.is_active && p.image_id == 99 {
			p99_idx = i
			testing.expect_value(t, p.screen, extension.Kitty_Screen.Alternate)
			break
		}
	}
	testing.expect(t, p99_idx >= 0, "placement 99 must be active on alternate screen")

	// 4. Leave alternate screen (?1049l) - 99 should be cleaned up, 42 must remain active!
	term.terminal_feed_string(&terminal, "\x1b[?1049l")
	testing.expect(t, !term.terminal_in_alt_screen(&terminal), "must be back in primary screen")
	testing.expect(t, var_kstate.placements[p42_idx].is_active, "primary screen placement 42 must still be active")
	testing.expect(t, !var_kstate.placements[p99_idx].is_active, "alternate screen placement 99 must be deactivated on exit")
}

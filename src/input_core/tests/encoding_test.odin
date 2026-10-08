package input_core_test

import "core:testing"
import input "../"

@(test)
test_portable_encoding_modes_and_small_output :: proc(t: ^testing.T) {
    cases := []struct {
        event: input.Input_Event,
        flags: u8,
        app_cursor: bool,
        expected: string,
    }{
        {input.Input_Event{kind = .Arrow_Up}, 0, true, "\x1bOA"},
        {input.Input_Event{kind = .Arrow_Left, ctrl = true}, 0, true, "\x1b[1;5D"},
        {input.Input_Event{kind = .Alt_Mod, rune = 'x', alt = true}, 0, false, "\x1bx"},
        {input.Input_Event{kind = .Printable, rune = 'A', ctrl = true, shift = true}, input.KITTY_FLAG_DISAMBIGUATE, false, "\x1b[97;6u"},
        {input.Input_Event{kind = .Printable, rune = 'a', is_release = true}, input.KITTY_FLAG_REPORT_EVENT_TYPES, false, "\x1b[97;1:3u"},
    }
    for c in cases {
        out: [input.INPUT_ENCODE_MAX]u8
        n := input.input_encode(c.event, out[:], c.flags, c.app_cursor)
        testing.expect_value(t, string(out[:n]), c.expected)
        short: [input.INPUT_ENCODE_MAX]u8
        for &b in short do b = 0xff
        n = input.input_encode(c.event, short[:len(c.expected)-1], c.flags, c.app_cursor)
        testing.expect_value(t, n, 0)
        for b in short do testing.expect_value(t, b, u8(0xff))
    }
    out: [input.INPUT_ENCODE_MAX]u8
    testing.expect_value(t, input.input_encode(input.Input_Event{event_type = .Local, action = .Paste, paste_shadow = true}, out[:]), 0)
    testing.expect_value(t, input.input_encode(input.Input_Event{kind = .Printable, rune = 'a', is_release = true}, out[:]), 0)
}

package terminal_tests

// The core relay feeds program output into its own Terminal and forwards it to
// viewers minus the queries that Terminal already answered.

import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"
import term "../"
import extension "../extension"

RELAY_MIXED_INPUT ::
	"a\x1b[c b\x1b[6n c\x1b]11;?\x1b\\ d\x1bP+q544e\x1b\\ \x1b[1mX\x1b]2;T\x1b\\" +
	"\x1b[?2026$p\x1b[>q e"
RELAY_MIXED_VIEWER :: "a b c d\x1bP+q544e\x1b\\ \x1b[1mX\x1b]2;T\x1b\\ e"

_relay_osc_color_cfg := extension.Osc_Color_Config{responder = term.terminal_emit_response}

_relay_terminal :: proc(terminal: ^term.Terminal) {
	term.terminal_init(terminal, 10, 40)
	term.terminal_register_osc(terminal, 11, extension.osc_color_handler, rawptr(&_relay_osc_color_cfg))
}

@test
test_relay_strips_answered_queries :: proc(t: ^testing.T) {
	whole, split: term.Terminal
	_relay_terminal(&whole)
	_relay_terminal(&split)
	defer term.terminal_destroy(&whole)
	defer term.terminal_destroy(&split)
	r1, r2: term.Relay
	v1, q1, v2, q2: [dynamic]u8
	defer { delete(v1); delete(q1); delete(v2); delete(q2) }

	input := transmute([]u8)string(RELAY_MIXED_INPUT)
	term.relay_feed(&r1, &whole, input, &v1, &q1)
	for i in 0 ..< len(input) do term.relay_feed(&r2, &split, input[i:i + 1], &v2, &q2)

	testing.expect_value(t, string(v1[:]), RELAY_MIXED_VIEWER)
	replies := string(q1[:])
	testing.expect(t, strings.contains(replies, "\x1b[?62;c"), "DA1 reply")
	testing.expect(t, strings.contains(replies, "\x1b[1;4R"), "CPR reply")
	testing.expect(t, strings.contains(replies, "\x1b]11;rgb:"), "OSC 11 reply")
	testing.expect(t, strings.contains(replies, "\x1b[?2026;2$y"), "DECRQM reply")
	testing.expect_value(t, term.terminal_title(&whole), "T")
	testing.expect(t, .Bold in whole.parser.cursor.active_style)

	testing.expect_value(t, string(v2[:]), string(v1[:]))
	testing.expect_value(t, string(q2[:]), string(q1[:]))
	testing.expect_value(t, term.terminal_get_cell(&split, 0, 8).char, term.terminal_get_cell(&whole, 0, 8).char)
}

@test
test_relay_drops_kitty_replies :: proc(t: ^testing.T) {
	query := "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
	direct: term.Terminal
	term.terminal_init(&direct, 4, 20)
	defer term.terminal_destroy(&direct)
	term.terminal_register_extension(&direct, extension.kitty_graphics_extension_make())
	term.terminal_feed_string(&direct, query)
	testing.expect(t, direct.parser.response_len > 0, "the core Terminal does answer the kitty query")

	core: term.Terminal
	term.terminal_init(&core, 4, 20)
	defer term.terminal_destroy(&core)
	term.terminal_register_extension(&core, extension.kitty_graphics_extension_make())
	r: term.Relay
	viewer, replies: [dynamic]u8
	defer { delete(viewer); delete(replies) }
	term.relay_feed(&r, &core, transmute([]u8)query, &viewer, &replies)

	testing.expect_value(t, string(viewer[:]), query)
	testing.expect_value(t, len(replies), 0)
	testing.expect_value(t, core.parser.response_len, 0)
}

@test
test_relay_oversized_osc_passes_through :: proc(t: ^testing.T) {
	core: term.Terminal
	term.terminal_init(&core, 4, 20)
	defer term.terminal_destroy(&core)
	r: term.Relay
	viewer, replies: [dynamic]u8
	defer { delete(viewer); delete(replies) }

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "\x1b]2;?")
	for _ in 0 ..< 700 do strings.write_byte(&b, 'x')
	strings.write_string(&b, "\x1b\\ok")
	input := strings.to_string(b)

	term.relay_feed(&r, &core, transmute([]u8)input, &viewer, &replies)
	testing.expect_value(t, string(viewer[:]), input)
	testing.expect_value(t, core.title_len, len(core.title_buf))
	testing.expect_value(t, term.terminal_get_cell(&core, 0, 1).char, 'k')
	testing.expect(t, term.terminal_parser_at_ground(&core))
}

@test
test_relay_drains_more_than_response_buffer :: proc(t: ^testing.T) {
	core: term.Terminal
	term.terminal_init(&core, 4, 20)
	defer term.terminal_destroy(&core)
	r: term.Relay
	viewer, replies: [dynamic]u8
	defer { delete(viewer); delete(replies) }

	input := strings.repeat("\x1b[6n\x1b[c", 40, context.temp_allocator)
	term.relay_feed(&r, &core, transmute([]u8)input, &viewer, &replies)
	testing.expect_value(t, len(viewer), 0)
	testing.expect(t, len(replies) > 256)
	testing.expect_value(t, bytes.count(replies[:], {'R'}), 40)
	testing.expect_value(t, strings.count(string(replies[:]), "\x1b[?62;c"), 40)
}

@test
test_relay_flush_and_partial_hold :: proc(t: ^testing.T) {
	core: term.Terminal
	term.terminal_init(&core, 4, 20)
	defer term.terminal_destroy(&core)
	r: term.Relay
	viewer, replies: [dynamic]u8
	defer { delete(viewer); delete(replies) }

	term.relay_feed(&r, &core, transmute([]u8)string("hi\x1b[3"), &viewer, &replies)
	testing.expect_value(t, string(viewer[:]), "hi")
	testing.expect(t, term.terminal_parser_at_ground(&core), "held bytes have not reached the Terminal yet")
	term.relay_flush(&r, &core)
	testing.expect(t, !term.terminal_parser_at_ground(&core), "flush hands the partial CSI to the Terminal")
}

@test
test_relay_steady_state_zero_alloc :: proc(t: ^testing.T) {
	core: term.Terminal
	_relay_terminal(&core)
	defer term.terminal_destroy(&core)
	r: term.Relay
	viewer := make([dynamic]u8, 0, 4096)
	replies := make([dynamic]u8, 0, 4096)
	defer { delete(viewer); delete(replies) }
	input := transmute([]u8)string(RELAY_MIXED_INPUT + "\r\n\x1b[38;2;1;2;3mtext \x1b[0m\x1b[5n")
	term.relay_feed(&r, &core, input, &viewer, &replies)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&track)
	for _ in 0 ..< 50 {
		clear(&viewer)
		clear(&replies)
		term.relay_feed(&r, &core, input, &viewer, &replies)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
}

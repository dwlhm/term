package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// --- DECCKM (CSI ? 1 h/l) Tests ---

@(test)
test_decckm_mode :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, !term.app_cursor_keys, "app_cursor_keys must start false")

	// Enable DECCKM: ESC [ ? 1 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', 'h'})
	testing.expect(t, term.app_cursor_keys, "app_cursor_keys must be true after ?1h")

	// Disable DECCKM: ESC [ ? 1 l
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', 'l'})
	testing.expect(t, !term.app_cursor_keys, "app_cursor_keys must be false after ?1l")
}

// --- Mouse Tracking Modes (1000, 1002, 1003, 1006) ---

@(test)
test_mouse_tracking_modes :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, term.mouse_tracking == .None, "mouse_tracking must start None")
	testing.expect(t, term.mouse_format == .X10, "mouse_format must start X10")

	// Enable Mode 1000: ESC [ ? 1000 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '0', 'h'})
	testing.expect(t, term.mouse_tracking == .Normal, "mouse_tracking must be Normal after ?1000h")

	// Enable Mode 1002: ESC [ ? 1002 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '2', 'h'})
	testing.expect(t, term.mouse_tracking == .Button_Event, "mouse_tracking must be Button_Event after ?1002h")

	// Enable Mode 1003: ESC [ ? 1003 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '3', 'h'})
	testing.expect(t, term.mouse_tracking == .Any_Event, "mouse_tracking must be Any_Event after ?1003h")

	// Disable Mode 1003: ESC [ ? 1003 l
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '3', 'l'})
	testing.expect(t, term.mouse_tracking == .None, "mouse_tracking must be None after ?1003l")

	// Enable Mode 1006 (SGR): ESC [ ? 1006 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '6', 'h'})
	testing.expect(t, term.mouse_format == .SGR, "mouse_format must be SGR after ?1006h")

	// Disable Mode 1006 (SGR): ESC [ ? 1006 l
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '6', 'l'})
	testing.expect(t, term.mouse_format == .X10, "mouse_format must be X10 after ?1006l")
}

// --- CSI Subparameter Bitmask Packing ---

@(test)
test_csi_subparam_bitmask_sgr :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Underline style sub-param: ESC [ 4 : 3 m (curly underline)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', ':', '3', 'm'})
	style := term.grid.style_table.entries[term.current_style]
	testing.expect(t, (style.flags & tg.STYLE_FLAG_UNDERLINE) != 0, "4:3 must set underline flag")

	// Truecolor colon form: ESC [ 38 : 2 : : 255 : 128 : 64 m
	p.parse_chunk(&parser, &term, []u8{
		0x1B, '[', '3', '8', ':', '2', ':', ':', '2', '5', '5', ':', '1', '2', '8', ':', '6', '4', 'm',
	})
	style = term.grid.style_table.entries[term.current_style]
	testing.expect(t, style.fg == 0xFF_FF_80_40, "colon truecolor must parse correctly with subparam_mask")
}

// --- Batch Span Printing ---

@(test)
test_terminal_print_span_wrap :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 4, 10)
	defer tg.terminal_destroy(&term)

	// Print 15 ASCII chars into 10-col grid:
	// First 10 fill row 0, then 5 wrap to row 1
	text := "0123456789ABCDE"
	p.parse_chunk(&parser, &term, transmute([]u8)text)

	// Check row 0 contents
	for i in 0..<10 {
		cell := tg.grid_get_cell(&term.grid, 0, i)
		testing.expect(t, cell.content == tg.Content_Handle(text[i]), "row 0 cell content must match")
	}

	// Check row 1 contents
	for i in 0..<5 {
		cell := tg.grid_get_cell(&term.grid, 1, i)
		testing.expect(t, cell.content == tg.Content_Handle(text[10 + i]), "row 1 cell content must match")
	}

	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 1, "cursor row must be 1")
	testing.expect(t, cur.col == 5, "cursor col must be 5")
	testing.expect(t, !cur.pending_wrap, "pending_wrap must be false after col 5")
}

@(test)
test_terminal_print_span_xenl_edge :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 4, 10)
	defer tg.terminal_destroy(&term)

	// Exactly 10 characters fills the row
	text := "0123456789"
	p.parse_chunk(&parser, &term, transmute([]u8)text)

	cur := tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 0, "cursor must remain on row 0")
	testing.expect(t, cur.col == 9, "cursor must sit at col 9 (xenl rule)")
	testing.expect(t, cur.pending_wrap, "pending_wrap must be true after filling row")

	// Next char triggers deferred wrap to row 1 col 0
	p.parse_chunk(&parser, &term, []u8{'X'})
	cur = tg.terminal_get_cursor(&term)
	testing.expect(t, cur.row == 1, "cursor must advance to row 1")
	testing.expect(t, cur.col == 1, "cursor col must be 1 after writing 'X'")
	cell := tg.grid_get_cell(&term.grid, 1, 0)
	testing.expect(t, cell.content == 'X', "'X' must be written at row 1 col 0")
}

// --- Modern Protocol Handshake & Query Tests ---

@(thread_local)
_proto_resp_buf: [2048]u8
@(thread_local)
_proto_resp_n: int

_proto_cb_response :: proc(data: []u8) {
	n := min(len(data), len(_proto_resp_buf) - _proto_resp_n)
	for i in 0..<n {
		_proto_resp_buf[_proto_resp_n + i] = data[i]
	}
	_proto_resp_n += n
}

_proto_reset :: proc() {
	_proto_resp_n = 0
}

_proto_response :: proc() -> []u8 {
	return _proto_resp_buf[:_proto_resp_n]
}

_proto_bytes_eq :: proc(t: ^testing.T, got: []u8, want: []u8, msg: string) {
	testing.expect(t, len(got) == len(want), msg)
	if len(got) != len(want) {
		return
	}
	for i in 0..<len(want) {
		if got[i] != want[i] {
			testing.expect(t, false, msg)
			return
		}
	}
}

@(test)
test_csi_5n_dsr_status :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '5', 'n'})
	_proto_bytes_eq(t, _proto_response(), []u8{0x1B, '[', '0', 'n'}, "CSI 5 n must respond with status report ESC[0n")
}

@(test)
test_csi_6n_cpr_cursor_position :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	tg.terminal_move_cursor(&term, 7, 15)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '6', 'n'})
	// 0-indexed (7, 15) -> 1-indexed (8, 16) -> ESC [ 8 ; 1 6 R
	_proto_bytes_eq(t, _proto_response(), []u8{0x1B, '[', '8', ';', '1', '6', 'R'}, "CSI 6 n must report 1-indexed cursor position ESC[8;16R")
}

@(test)
test_csi_secondary_da :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '>', 'c'})
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{0x1B, '[', '>', '0', ';', '1', '0', ';', '0', 'c'},
		"CSI > c must respond with secondary DA ESC[>0;10;0c",
	)
}

@(test)
test_csi_primary_da :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', 'c'})
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{0x1B, '[', '?', '6', '2', 'c'},
		"CSI c must respond with primary DA ESC[?62c",
	)
}

@(test)
test_osc_10_fg_color_query :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Default theme: Catppuccin Mocha foreground CATPPUCCIN_MOCHA_TEXT = 0xFFCDD6F4
	// r: 0xCD * 257 = 0xCDCD, g: 0xD6 * 257 = 0xD6D6, b: 0xF4 * 257 = 0xF4F4
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '1', '0', ';', '?', 0x07})
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{
			0x1B,
			']',
			'1',
			'0',
			';',
			'r',
			'g',
			'b',
			':',
			'c',
			'd',
			'c',
			'd',
			'/',
			'd',
			'6',
			'd',
			'6',
			'/',
			'f',
			'4',
			'f',
			'4',
			0x1B,
			'\\',
		},
		"OSC 10;? query must respond with rgb:cdcd/d6d6/f4f4",
	)
}

// --- Synchronized Output (CSI ? 2026 h/l) ---

@(test)
test_synchronized_output_mode :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, !term.synchronized_output, "synchronized_output must start false")

	// Enable synchronized output: ESC [ ? 2026 h
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '2', '0', '2', '6', 'h'})
	testing.expect(t, term.synchronized_output, "synchronized_output must be true after CSI ? 2026 h")

	// Disable synchronized output: ESC [ ? 2026 l
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '2', '0', '2', '6', 'l'})
	testing.expect(t, !term.synchronized_output, "synchronized_output must be false after CSI ? 2026 l")
}

// --- XTGETTCAP Tc and RGB (Truecolor / Direct Color) ---

@(test)
test_xtgettcap_tc :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// DCS + q 5463 ("Tc") ST
	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, 'P', '+', 'q', '5', '4', '6', '3', 0x1B, '\\'},
	)
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{0x1B, 'P', '1', '+', 'r', '5', '4', '6', '3', 0x1B, '\\'},
		"XTGETTCAP Tc must respond with DCS 1+r5463 ST",
	)
}

@(test)
test_xtgettcap_rgb :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// DCS + q 524742 ("RGB") ST
	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, 'P', '+', 'q', '5', '2', '4', '7', '4', '2', 0x1B, '\\'},
	)
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{0x1B, 'P', '1', '+', 'r', '5', '2', '4', '7', '4', '2', 0x1B, '\\'},
		"XTGETTCAP RGB must respond with DCS 1+r524742 ST",
	)
}

// --- OSC 4 Palette Color Query Tests ---

@(test)
test_osc_4_palette_color_query :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Palette 0: Surface1 = 0xFF45475A -> r: 0x45*257=0x4545, g: 0x47*257=0x4747, b: 0x5A*257=0x5A5A
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '4', ';', '0', ';', '?', 0x07})
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{
			0x1B, ']', '4', ';', '0', ';',
			'r', 'g', 'b', ':',
			'4', '5', '4', '5', '/',
			'4', '7', '4', '7', '/',
			'5', 'a', '5', 'a',
			0x1B, '\\',
		},
		"OSC 4;0;? query must respond with rgb:4545/4747/5a5a",
	)

	// Palette 1: Red = 0xFFF38BA8 -> r: 0xF3*257=0xF3F3, g: 0x8B*257=0x8B8B, b: 0xA8*257=0xA8A8
	_proto_reset()
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '4', ';', '1', ';', '?', 0x1B, '\\'})
	_proto_bytes_eq(
		t,
		_proto_response(),
		[]u8{
			0x1B, ']', '4', ';', '1', ';',
			'r', 'g', 'b', ':',
			'f', '3', 'f', '3', '/',
			'8', 'b', '8', 'b', '/',
			'a', '8', 'a', '8',
			0x1B, '\\',
		},
		"OSC 4;1;? query must respond with rgb:f3f3/8b8b/a8a8",
	)
}

// --- OSC 52 Clipboard Query Tests ---

_mock_clipboard_read_cb :: proc(user_data: rawptr, out: []u8) -> int {
	if user_data == nil || len(out) == 0 { return 0 }
	s := (^string)(user_data)^
	data := transmute([]u8)s
	n := min(len(data), len(out))
	copy(out[:n], data[:n])
	return n
}

@(test)
test_osc_52_clipboard_query :: proc(t: ^testing.T) {
	_proto_reset()
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _proto_cb_response

	clip_text := "hello world"
	parser.clipboard_read_cb = _mock_clipboard_read_cb
	parser.clipboard_read_user_data = &clip_text

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	// Base64 of "hello world" is "aGVsbG8gd29ybGQ="
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '5', '2', ';', 'c', ';', '?', 0x1B, '\\'})
	want := "\x1b]52;c;aGVsbG8gd29ybGQ=\x1b\\"
	_proto_bytes_eq(
		t,
		_proto_response(),
		transmute([]u8)want,
		"OSC 52;c;? query must respond with base64 clipboard content",
	)
}

// --- OSC 8 Hyperlink Tests ---

@(test)
test_osc_8_hyperlinks :: proc(t: ^testing.T) {
	parser: p.Parser
	p.parser_init(&parser)

	term: tg.Terminal
	tg.terminal_init(&term, 24, 80)
	defer tg.terminal_destroy(&term)

	testing.expect(t, tg.terminal_get_active_hyperlink(&term) == "", "active hyperlink must start empty")

	// Set hyperlink: OSC 8 ;; https://example.com ST
	seq_set := "\x1b]8;;https://example.com\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq_set)
	testing.expect(t, tg.terminal_get_active_hyperlink(&term) == "https://example.com", "active hyperlink must match set URL")

	// Clear hyperlink: OSC 8 ;; ST
	seq_clear := "\x1b]8;;\x1b\\"
	p.parse_chunk(&parser, &term, transmute([]u8)seq_clear)
	testing.expect(t, tg.terminal_get_active_hyperlink(&term) == "", "active hyperlink must be empty after clear")
}



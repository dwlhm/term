package parser_test

import "core:testing"
import tg "../../terminal"
import p "../../parser"

// Fish + modern-CLI compatibility tests: CPR, DECSCUSR, XTVERSION, kitty
// keyboard mode, bracketed paste / focus reporting modes, colon-form SGR,
// OSC title/cwd/bg-query/clipboard, and XTGETTCAP (DCS).

// Thread-local capture buffers: Odin runs package tests on multiple threads,
// so shared globals would race between tests running concurrently.
@(thread_local)
_fx_resp_buf: [2048]u8
@(thread_local)
_fx_resp_n: int
@(thread_local)
_fx_clip_buf: [2048]u8
@(thread_local)
_fx_clip_n: int

_fx_cb_response :: proc(data: []u8) {
	n := min(len(data), len(_fx_resp_buf) - _fx_resp_n)
	for i in 0..<n {
		_fx_resp_buf[_fx_resp_n + i] = data[i]
	}
	_fx_resp_n += n
}

_fx_cb_clipboard :: proc(data: []u8) {
	n := min(len(data), len(_fx_clip_buf) - _fx_clip_n)
	for i in 0..<n {
		_fx_clip_buf[_fx_clip_n + i] = data[i]
	}
	_fx_clip_n += n
}

_fx_reset :: proc() {
	_fx_resp_n = 0
	_fx_clip_n = 0
}

_fx_response :: proc() -> []u8 {
	return _fx_resp_buf[:_fx_resp_n]
}

_fx_clipboard :: proc() -> []u8 {
	return _fx_clip_buf[:_fx_clip_n]
}

_fx_bytes_eq :: proc(t: ^testing.T, got: []u8, want: []u8, msg: string) {
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

_fx_term :: proc(rows, cols: int) -> tg.Terminal {
	t: tg.Terminal
	tg.terminal_init(&t, rows, cols)
	return t
}

_fx_parser :: proc() -> p.Parser {
	parser: p.Parser
	p.parser_init(&parser)
	parser.response_cb = _fx_cb_response
	parser.clipboard_cb = _fx_cb_clipboard
	return parser
}

// --- CPR (Cursor Position Report) ---

@(test)
test_fx_cpr_basic :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	tg.terminal_move_cursor(&term, 5, 10)
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '6', 'n'})
	// 0-indexed (5,10) -> 1-indexed ESC[6;11R
	_fx_bytes_eq(t, _fx_response(), []u8{0x1B, '[', '6', ';', '1', '1', 'R'}, "CPR must report 1-indexed cursor")
}

@(test)
test_fx_cpr_private_ignored :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '6', 'n'})
	testing.expect(t, len(_fx_response()) == 0, "private CSI ? 6 n must not respond")
}

// --- DECSCUSR (cursor style) ---

@(test)
test_fx_decscusr :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	for style in 0..=6 {
		seq := []u8{0x1B, '[', u8('0' + style), ' ', 'q'}
		p.parse_chunk(&parser, &term, seq)
		testing.expect_value(t, term.cursor.style, u8(style))
	}

	// Out of bounds (<0 or >6) resets to 0
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '7', ' ', 'q'})
	testing.expect_value(t, term.cursor.style, u8(0))

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '9', ' ', 'q'})
	testing.expect_value(t, term.cursor.style, u8(0))
}

// --- XTVERSION ---

@(test)
test_fx_xtversion :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '>', 'q'})
	_fx_bytes_eq(
		t,
		_fx_response(),
		[]u8{0x1B, 'P', '>', '|', 'T', 'e', 'r', 'm', 0x1B, '\\'},
		"CSI > q must answer DCS > | Term ST",
	)
}

// --- Kitty keyboard protocol ---

@(test)
test_fx_kitty_set_and_query :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "flags start at 0")

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 1, "CSI = 1 u must set disambiguate")

	_fx_reset()
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', 'u'})
	_fx_bytes_eq(t, _fx_response(), []u8{0x1B, '[', '?', '1', 'u'}, "CSI ? u must report current flags")

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '0', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "CSI = 0 u must reset to legacy")
}

@(test)
test_fx_kitty_unsupported_masked :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// Request disambiguate + event types (3); only disambiguate sticks.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '3', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 1, "unsupported bits must be masked off")

	// Mode 2 sets bits without clearing.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '0', 'u'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', ';', '2', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 1, "mode 2 must set requested bits")

	// Mode 3 clears bits.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', ';', '3', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "mode 3 must clear requested bits")
}

@(test)
test_fx_kitty_push_pop :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', 'u'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '>', '0', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "push must save current and set new")

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '<', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 1, "pop must restore pushed flags")

	// Popping an empty stack resets.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '<', 'u'})
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "empty pop must reset flags")
}

@(test)
test_fx_kitty_alt_screen_independent :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', 'u'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '4', '9', 'h'})
	testing.expect(t, term.is_alt_screen, "must be in alt screen")
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 0, "alt screen starts with its own flags")

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '=', '1', 'u'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '4', '9', 'l'})
	testing.expect(t, !term.is_alt_screen, "must be back on main screen")
	testing.expect(t, tg.terminal_kitty_active(&term).flags == 1, "main screen flags preserved")
}

// --- Private modes: bracketed paste + focus reporting ---

@(test)
test_fx_private_modes_2004_1004 :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '2', '0', '0', '4', 'h'})
	testing.expect(t, term.bracketed_paste, "CSI ? 2004 h must enable bracketed paste")
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '2', '0', '0', '4', 'l'})
	testing.expect(t, !term.bracketed_paste, "CSI ? 2004 l must disable bracketed paste")

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '4', 'h'})
	testing.expect(t, term.focus_reporting, "CSI ? 1004 h must enable focus reporting")
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '?', '1', '0', '0', '4', 'l'})
	testing.expect(t, !term.focus_reporting, "CSI ? 1004 l must disable focus reporting")
}

// --- SGR: dim, 22 fix, underline variants, extended underline colors ---

@(test)
test_fx_sgr_dim :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '1', 'm'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', 'm'})
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD != 0, "bold must be set")
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM != 0, "dim must be set")

	// 22 clears BOTH bold and dim per xterm.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '2', '2', 'm'})
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_BOLD == 0, "22 must clear bold")
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM == 0, "22 must clear dim")
}

@(test)
test_fx_sgr_underline_colon_vs_semicolon :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// Colon form 4:2 = underline style variant: underline on, dim OFF.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', ':', '2', 'm'})
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE != 0, "4:2 must set underline")
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM == 0, "4:2 must NOT set dim")

	// Semicolon form 4;2 = underline + dim.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '0', 'm'})
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', ';', '2', 'm'})
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE != 0, "4;2 must set underline")
	testing.expect(t, st.flags & tg.STYLE_FLAG_DIM != 0, "4;2 must set dim")

	// 4:0 clears underline.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '4', ':', '0', 'm'})
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.flags & tg.STYLE_FLAG_UNDERLINE == 0, "4:0 must clear underline")
}

@(test)
test_fx_sgr_underline_color :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// 256-color underline (colon form).
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '5', '8', ':', '5', ':', '1', '9', '6', 'm'})
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	want := tg.theme_palette_256(tg.THEME_CATPPUCCIN_MOCHA, 196)
	testing.expect(t, st.underline == want, "58:5:196 must set themed underline color")

	// 59 resets underline color.
	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '5', '9', 'm'})
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.underline == 0, "59 must reset underline color")

	// Truecolor underline, colon form with empty field.
	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, '[', '5', '8', ':', '2', ':', ':', '1', '0', ':', '2', '0', ':', '3', '0', 'm'},
	)
	st = tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.underline == 0xFF0A141E, "58:2::10:20:30 must set truecolor underline")
}

@(test)
test_fx_sgr_fg_truecolor_colon :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, '[', '3', '8', ':', '2', ':', ':', '1', '0', ':', '2', '0', ':', '3', '0', 'm'},
	)
	st := tg.style_table_get(&term.grid.style_table, term.current_style)
	testing.expect(t, st.fg == 0xFF0A141E, "38:2::10:20:30 must set truecolor fg")
}

// --- OSC: titles, cwd, bg query, clipboard ---

@(test)
test_fx_osc_title :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '0', ';', 'H', 'e', 'l', 'l', 'o', 0x07})
	testing.expect(t, term.title_dirty, "OSC 0 must mark title dirty")
	testing.expect(t, tg.terminal_take_title(&term) == "Hello", "take_title must return stored title")
	testing.expect(t, !term.title_dirty, "take_title must clear dirty flag")

	// Same title again: no dirty flag (no redundant SDL update).
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '0', ';', 'H', 'e', 'l', 'l', 'o', 0x07})
	testing.expect(t, !term.title_dirty, "identical title must not re-mark dirty")

	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '2', ';', 'n', 'e', 'w', 0x07})
	testing.expect(t, tg.terminal_take_title(&term) == "new", "OSC 2 must also set title")
}

@(test)
test_fx_osc_title_truncated_skipped :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// 600-byte title overflows the 512-byte OSC buffer.
	payload := make([dynamic]u8, 0, 610)
	append(&payload, 0x1B, ']', '0', ';')
	for _ in 0..<600 {
		append(&payload, 'x')
	}
	append(&payload, 0x07)
	p.parse_chunk(&parser, &term, payload[:])
	delete(payload)
	testing.expect(t, !term.title_dirty, "truncated title must be skipped")
}

@(test)
test_fx_osc7_cwd :: proc(t: ^testing.T) {
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, ']', '7', ';', 'f', 'i', 'l', 'e', ':', '/', '/', 'h', '/', 'd', 'i', 'r', 0x07},
	)
	testing.expect(t, term.cwd_len == 12, "OSC 7 payload tail must be retained")
	testing.expect(t, string(term.cwd[:term.cwd_len]) == "file://h/dir", "cwd content must match")
}

@(test)
test_fx_osc11_bg_query :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '1', '1', ';', '?', 0x07})
	// Catppuccin base 0xFF1E1E2E -> rgb:1e1e/1e1e/2e2e
	_fx_bytes_eq(
		t,
		_fx_response(),
		[]u8{
			0x1B,
			']',
			'1',
			'1',
			';',
			'r',
			'g',
			'b',
			':',
			'1',
			'e',
			'1',
			'e',
			'/',
			'1',
			'e',
			'1',
			'e',
			'/',
			'2',
			'e',
			'2',
			'e',
			0x1B,
			'\\',
		},
		"OSC 11 query must answer theme background",
	)
}

@(test)
test_fx_osc52_clipboard :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// "hi" -> base64 "aGk="
	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, ']', '5', '2', ';', 'c', ';', 'a', 'G', 'k', '=', 0x07},
	)
	_fx_bytes_eq(t, _fx_clipboard(), []u8{'h', 'i'}, "OSC 52 must deliver decoded clipboard")

	// Query form is ignored.
	_fx_reset()
	p.parse_chunk(&parser, &term, []u8{0x1B, ']', '5', '2', ';', 'c', ';', '?', 0x07})
	testing.expect(t, len(_fx_clipboard()) == 0, "OSC 52 query must not fire clipboard")
}

@(test)
test_fx_osc52_truncated_skipped :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// 600 valid base64 chars overflow the OSC buffer; must not set clipboard.
	payload := make([dynamic]u8, 0, 612)
	append(&payload, 0x1B, ']', '5', '2', ';', 'c', ';')
	for _ in 0..<600 {
		append(&payload, 'A')
	}
	append(&payload, 0x07)
	p.parse_chunk(&parser, &term, payload[:])
	delete(payload)
	testing.expect(t, len(_fx_clipboard()) == 0, "truncated OSC 52 must be skipped")
}

// --- XTGETTCAP (DCS) ---

@(test)
test_fx_da_canonical :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, '[', '0', 'c'})
	_fx_bytes_eq(
		t,
		_fx_response(),
		[]u8{0x1B, '[', '?', '6', '2', 'c'},
		"DA must answer canonical CSI ? 62 c (no trailing separator)",
	)
}

@(test)
test_fx_xtgettcap_indn :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// DCS + q 696e646e ("indn") ST. The response uses +r (xterm): fish
	// rejects +q echo and dumps the payload as typed input.
	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, 'P', '+', 'q', '6', '9', '6', 'e', '6', '4', '6', 'e', 0x1B, '\\'},
	)
	_fx_bytes_eq(
		t,
		_fx_response(),
		[]u8{
			0x1B,
			'P',
			'1',
			'+',
			'r',
			'6',
			'9',
			'6',
			'e',
			'6',
			'4',
			'6',
			'e',
			0x1B,
			'\\',
		},
		"XTGETTCAP indn must answer DCS 1+r boolean true",
	)
}

@(test)
test_fx_xtgettcap_os :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	// DCS + q <hex of "query-os-name"> ST
	req := "71756572792d6f732d6e616d65"
	payload := make([dynamic]u8, 0, 40)
	append(&payload, 0x1B, 'P', '+', 'q')
	for i in 0..<len(req) {
		append(&payload, req[i])
	}
	append(&payload, 0x1B, '\\')
	p.parse_chunk(&parser, &term, payload[:])
	delete(payload)

	got := _fx_response()
	testing.expect(t, len(got) > 0, "XTGETTCAP query-os-name must respond")
	// Response form: DCS 1 + r <param> = <hexos> ST ('r', not 'q').
	testing.expect(t, len(got) >= 8, "response must carry the string form")
	if len(got) >= 8 {
		testing.expect(
			t,
			got[0] == 0x1B && got[1] == 'P' && got[2] == '1' && got[3] == '+' && got[4] == 'r',
			"response must be DCS 1+r",
		)
		found_eq := false
		for b in got {
			if b == '=' {
				found_eq = true
			}
		}
		testing.expect(t, found_eq, "os response must use the string variant")
	}
}

@(test)
test_fx_xtgettcap_unknown_ignored :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(
		&parser,
		&term,
		[]u8{0x1B, 'P', '+', 'q', 'd', 'e', 'a', 'd', 'b', 'e', 'e', 'f', 0x1B, '\\'},
	)
	testing.expect(t, len(_fx_response()) == 0, "unknown XTGETTCAP must not respond")
}

@(test)
test_fx_dcs_split_across_chunks :: proc(t: ^testing.T) {
	_fx_reset()
	term := _fx_term(24, 80)
	defer tg.terminal_destroy(&term)
	parser := _fx_parser()

	p.parse_chunk(&parser, &term, []u8{0x1B, 'P', '+', 'q', '6', '9'})
	testing.expect(t, len(_fx_response()) == 0, "partial DCS must not respond yet")
	p.parse_chunk(&parser, &term, []u8{'6', 'e', '6', '4', '6', 'e', 0x1B, '\\'})
	testing.expect(t, len(_fx_response()) > 0, "completed split DCS must respond")
}

package parser

import "base:runtime"
import termgrid "../terminal"

// Parser is the top-level VT parser state.
Parser :: struct {
	state: Parser_State,
	
	// CSI parameter storage
	csi_values: [16]u32,
	csi_count:  u8,
	
	// UTF-8 decoder state
	utf8_state:  UTF8_State,
	utf8_buffer: [4]u8,
	utf8_len:    u8,
	
	// Small persistent state
	intermediate: u8,
	string_esc_pending: bool,
	
	// Print run accumulator (for Level 1 fast path)
	print_run_start: int,
	print_run_len:   int,
}

// parser_init initializes a parser.
parser_init :: proc(p: ^Parser) {
	// Initialize global tables (idempotent)
	init()
	
	p.state = .Ground
	p.csi_count = 0
	p.utf8_state = .Ground
	p.utf8_len = 0
	p.intermediate = 0
	p.string_esc_pending = false
	p.print_run_start = 0
	p.print_run_len = 0
	
	// Clear CSI values
	for i in 0..<16 {
		p.csi_values[i] = 0
	}
	
	// Clear UTF-8 buffer
	for i in 0..<4 {
		p.utf8_buffer[i] = 0
	}
}

// parser_destroy frees parser state (currently no-op, but future-proof).
parser_destroy :: proc(p: ^Parser) {
	// No-op: Parser is stack-allocated, no heap allocations to free
}

// parse_chunk parses a chunk of bytes and mutates terminal state.
// This is the main entry point called by the I/O layer.
parse_chunk :: proc(p: ^Parser, t: ^termgrid.Terminal, input: []u8) {
	pos := 0
	
	for pos < len(input) {
		// OSC/DCS strings are opaque to the terminal but their terminators
		// are part of the parser state, including when split across reads.
		if p.state == .OSC || p.state == .DCS {
			byte := input[pos]
			if p.string_esc_pending {
				p.string_esc_pending = false
				if byte == '\\' {
					p.state = .Ground
					pos += 1
					continue
				}
				if byte == 0x1B {
					p.string_esc_pending = true
				}
				pos += 1
				continue
			}
			if byte == 0x07 || byte == 0x9C {
				p.state = .Ground
				pos += 1
				continue
			}
			if byte == 0x18 || byte == 0x1A {
				parser_reset(p)
				pos += 1
				continue
			}
			if byte == 0x1B {
				p.string_esc_pending = true
			}
			pos += 1
			continue
		}
		// Level 1: Block Scanner (ASCII fast path)
		if p.state == .Ground {
			run := scan_ascii_run(input[pos:])
			if run.length > 0 {
				terminal_print_run(t, run.data, t.current_style)
				pos += run.length
				continue
			}
		}
		
		// Level 2: VT State Machine
		byte := input[pos]
		transition := TRANSITION_TABLE[p.state][byte]
		
		// Execute the action
		#partial switch transition.action {
		case .Print:
			// Accumulate print run (for non-fast-path cases)
			accumulate_print_run(p, byte)
		case .Execute:
			execute_c0(t, byte)
		case .Clear:
			clear_parser_state(p)
		case .Collect:
			p.intermediate = byte
		case .Param:
			csi_collect_param(p, byte)
		case .CsiDispatch:
			csi_dispatch(p, t, byte)
		case .EscDispatch:
			esc_dispatch(p, t, byte)
		case .OscStart:
			p.state = .OSC
			p.string_esc_pending = false
		case .OscPut:
			// Discard OSC payload
		case .OscEnd:
			p.state = .Ground
		case .DcsHook:
			p.state = .DCS
			p.string_esc_pending = false
		case .DcsPut:
			// Discard DCS payload
		case .DcsUnhook:
			p.state = .Ground
		case .Utf8:
			utf8_feed(p, t, byte)
		case .Ignore:
			// Do nothing
		case .Error:
			// Invalid transition - reset to Ground
			p.state = .Ground
		}
		
		// Update state (unless action already changed it)
		if transition.action != .OscStart &&
		   transition.action != .OscEnd &&
		   transition.action != .DcsHook &&
		   transition.action != .DcsUnhook {
			p.state = transition.next_state
		}

		// UTF-8 completion sync: utf8_feed consumes the byte and returns the
		// decoder to Ground on completion (valid rune, FFFD, or invalid
		// lead). The parser must follow, or the next byte would be handled
		// in the stale Utf8 state (ASCII would hit Print/accumulate and be
		// dropped). A re-fed new lead leaves the decoder pending, so the
		// parser correctly stays in Utf8.
		if transition.action == .Utf8 && p.utf8_state == .Ground {
			p.state = .Ground
		}
		
		pos += 1
	}
}

// parser_get_state returns the current parser state (for testing/debugging).
parser_get_state :: proc(p: ^Parser) -> Parser_State {
	return p.state
}

// parser_reset resets the parser to Ground state.
parser_reset :: proc(p: ^Parser) {
	p.state = .Ground
	csi_reset(p)
	utf8_reset(p)
	p.intermediate = 0
	p.string_esc_pending = false
	p.print_run_start = 0
	p.print_run_len = 0
}

// accumulate_print_run accumulates a byte into the print run buffer.
accumulate_print_run :: proc(p: ^Parser, b: u8) {
	// For now, we don't accumulate - just emit directly
	// Future optimization: batch ASCII runs
	_ = p
	_ = b
}

// clear_parser_state clears the parser state (called on ESC or CAN).
clear_parser_state :: proc(p: ^Parser) {
	csi_reset(p)
	p.intermediate = 0
}

// terminal_print_run writes a run of bytes to the terminal.
terminal_print_run :: proc(t: ^termgrid.Terminal, data: []u8, style: termgrid.Style_Id) {
	// For each byte in the run, emit as a character
	for i in 0..<len(data) {
		termgrid.terminal_put_char(t, rune(data[i]))
	}
}

// execute_c0 executes a C0 control character.
execute_c0 :: proc(t: ^termgrid.Terminal, b: u8) {
	switch b {
	case 0x08: // BS (Backspace)
		termgrid.terminal_backspace(t)
	case 0x09: // TAB
		// Advance to next tab stop (simplified: advance 8 columns)
		tab_stop := 8 - (t.cursor.col % 8)
		termgrid.terminal_cursor_right(t, tab_stop)
	case 0x0A: // LF (Line Feed)
		termgrid.terminal_linefeed(t)
	case 0x0D: // CR (Carriage Return)
		t.cursor.col = 0
	}
}

// esc_dispatch dispatches an escape sequence.
esc_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8) {
	_ = p
	switch final_byte {
	case '7':
		termgrid.terminal_save_cursor(t)
	case '8':
		termgrid.terminal_restore_cursor(t)
	case 'c':
		termgrid.terminal_reset(t)
	case 'M':
		termgrid.terminal_reverse_index(t)
	case 'D':
		termgrid.terminal_index(t)
	case 'E':
		termgrid.terminal_next_line(t)
	}
}

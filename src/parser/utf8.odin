package parser

import termgrid "../terminal"

// UTF8_State is the UTF-8 decoder state.
UTF8_State :: enum u8 {
	Ground, // expecting lead byte
	Byte2,  // expecting 1 continuation byte
	Byte3,  // expecting 2 continuation bytes
	Byte4,  // expecting 3 continuation bytes
}

// utf8_feed feeds a byte to the UTF-8 decoder.
// If the sequence is complete, emits the rune to the terminal.
// If the sequence is invalid, emits replacement char (U+FFFD).
utf8_feed :: proc(p: ^Parser, t: ^termgrid.Terminal, b: u8) {
	if p.utf8_state == .Ground {
		// Expecting lead byte
		expected_len, initial_value := _utf8_decode_lead(b)
		
		if expected_len == 1 {
			// ASCII byte - emit directly
			termgrid.terminal_put_char(t, rune(initial_value))
			return
		}
		
		if expected_len == 0 {
			// Invalid lead byte - emit replacement char
			termgrid.terminal_put_char(t, 0xFFFD)
			return
		}
		
		// Start multi-byte sequence
		p.utf8_state = UTF8_State(expected_len - 1)
		p.utf8_buffer[0] = b
		p.utf8_len = 1
		return
	}
	
	// Expecting continuation byte
	complete, rune_value := _utf8_decode_cont(p, b)

	if complete {
		if rune_value != 0 {
			// Valid sequence - emit rune
			termgrid.terminal_put_char(t, rune(rune_value))
		} else {
			// Invalid sequence - emit replacement char
			termgrid.terminal_put_char(t, 0xFFFD)
		}

		// Reset state
		p.utf8_state = .Ground
		p.utf8_len = 0

		if rune_value == 0 && b >= 0xC0 {
			// The byte was never consumed as a continuation: it is a new
			// lead byte (new lead mid-sequence). Re-feed it so the dropped
			// lead is never swallowed. (ASCII mid-sequence self-heals at
			// the VT table level: Utf8 + ASCII is a Print transition that
			// never reaches utf8_feed, so only b >= 0xC0 re-feeds here.)
			expected_len, _ := _utf8_decode_lead(b)
			if expected_len == 0 {
				termgrid.terminal_put_char(t, 0xFFFD)
				return
			}
			p.utf8_state = UTF8_State(expected_len - 1)
			p.utf8_buffer[0] = b
			p.utf8_len = 1
		}
	}
}

// utf8_reset resets the UTF-8 decoder state.
utf8_reset :: proc(p: ^Parser) {
	p.utf8_state = .Ground
	p.utf8_len = 0
}

// _utf8_decode_lead decodes a UTF-8 lead byte.
// Returns expected length (0 = invalid, 1 = ASCII) and initial value.
_utf8_decode_lead :: proc(b: u8) -> (expected_len: u8, initial_value: u32) {
	if b < 0x80 {
		// ASCII
		return 1, u32(b)
	}
	
	if b < 0xC0 {
		// Invalid: continuation byte as lead
		return 0, 0
	}
	
	if b < 0xE0 {
		// 2-byte sequence: 110xxxxx
		return 2, u32(b & 0x1F)
	}
	
	if b < 0xF0 {
		// 3-byte sequence: 1110xxxx
		return 3, u32(b & 0x0F)
	}
	
	if b < 0xF8 {
		// 4-byte sequence: 11110xxx
		return 4, u32(b & 0x07)
	}
	
	// Invalid: b >= 0xF8
	return 0, 0
}

// _utf8_decode_cont decodes a UTF-8 continuation byte.
// Returns true if sequence is complete, and the decoded rune value (0 if invalid).
_utf8_decode_cont :: proc(p: ^Parser, b: u8) -> (complete: bool, rune: u32) {
	// Check if it's a valid continuation byte (10xxxxxx)
	if b < 0x80 || b >= 0xC0 {
		// Invalid continuation byte
		return true, 0
	}
	
	// Accumulate the continuation byte
	p.utf8_buffer[p.utf8_len] = b
	p.utf8_len += 1
	
	// Calculate expected total length
	expected_total := u8(p.utf8_state) + 1
	
	if p.utf8_len == expected_total {
		// Sequence complete - decode the rune
		value: u32
		
		switch expected_total {
		case 2:
			// 2-byte: 110xxxxx 10xxxxxx
			value = (u32(p.utf8_buffer[0] & 0x1F) << 6) |
			        (u32(p.utf8_buffer[1] & 0x3F))
		case 3:
			// 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
			value = (u32(p.utf8_buffer[0] & 0x0F) << 12) |
			        (u32(p.utf8_buffer[1] & 0x3F) << 6) |
			        (u32(p.utf8_buffer[2] & 0x3F))
		case 4:
			// 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
			value = (u32(p.utf8_buffer[0] & 0x07) << 18) |
			        (u32(p.utf8_buffer[1] & 0x3F) << 12) |
			        (u32(p.utf8_buffer[2] & 0x3F) << 6) |
			        (u32(p.utf8_buffer[3] & 0x3F))
		case:
			return true, 0
		}
		
		// Validate the rune value
		if value > 0x10FFFF {
			return true, 0
		}
		
		// Check for overlong encodings
		if expected_total == 2 && value < 0x80 {
			return true, 0
		}
		if expected_total == 3 && value < 0x800 {
			return true, 0
		}
		if expected_total == 4 && value < 0x10000 {
			return true, 0
		}

		// Reject surrogates U+D800..U+DFFF (never valid UTF-8).
		if value >= 0xD800 && value <= 0xDFFF {
			return true, 0
		}

		return true, value
	}
	
	// Sequence not complete yet
	return false, 0
}

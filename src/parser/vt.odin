package parser

// Parser_State is the VT parser state.
Parser_State :: enum u8 {
	Ground,
	Escape,
	CSI_Entry,
	CSI_Param,
	CSI_Intermediate,
	OSC,
	DCS,
	Utf8,
}

// Action is the action to perform on a state transition.
Action :: enum u8 {
	None,
	Print,
	Execute,
	Ignore,
	Clear,
	Collect,
	Param,
	EscDispatch,
	CsiDispatch,
	OscStart,
	OscPut,
	OscEnd,
	DcsHook,
	DcsPut,
	DcsUnhook,
	Utf8,
	Error,
}

// Transition is a state transition (action + next state).
Transition :: struct {
	action:     Action,
	next_state: Parser_State,
}

// Byte_Class is the classification of a byte.
Byte_Class :: enum u8 {
	PRINT,        // 0x20-0x7E (printable ASCII)
	C0,           // 0x00-0x1F (C0 controls)
	UTF8_LEAD,    // 0xC0-0xFF (UTF-8 lead bytes)
	UTF8_CONT,    // 0x80-0xBF (UTF-8 continuation bytes)
	ESC,          // 0x1B (escape)
	DIGIT,        // 0x30-0x39 (0-9)
	SEMI,         // 0x3B (;)
	COLON,        // 0x3A (:)
	INTERMEDIATE, // 0x20-0x2F (space to /)
	PRIVATE,      // 0x3C-0x3F (< = > ?)
	ALPHA,        // 0x40-0x7E (A-Z, a-z, etc.)
}

// BYTE_CLASS is the byte classification lookup table.
// 256 entries, one per byte value.
BYTE_CLASS: [256]Byte_Class

init :: proc() {
	BYTE_CLASS = init_byte_class_table()
	TRANSITION_TABLE = init_transition_table()
}

init_byte_class_table :: proc() -> [256]Byte_Class {
	table: [256]Byte_Class
	
	// 0x00-0x1A: C0 controls (except ESC at 0x1B)
	for i in 0x00..=0x1A {
		table[i] = .C0
	}
	
	// 0x1B: ESC
	table[0x1B] = .ESC
	
	// 0x1C-0x1F: C0 controls
	for i in 0x1C..=0x1F {
		table[i] = .C0
	}
	
	// 0x20-0x2F: INTERMEDIATE (space to /)
	for i in 0x20..=0x2F {
		table[i] = .INTERMEDIATE
	}
	
	// 0x30-0x39: DIGIT (0-9)
	for i in 0x30..=0x39 {
		table[i] = .DIGIT
	}
	
	// 0x3A: COLON
	table[0x3A] = .COLON
	
	// 0x3B: SEMI
	table[0x3B] = .SEMI
	
	// 0x3C-0x3F: PRIVATE (< = > ?)
	for i in 0x3C..=0x3F {
		table[i] = .PRIVATE
	}
	
	// 0x40-0x7E: ALPHA (A-Z, [, \, ], ^, _, `, a-z, {, |, }, ~)
	for i in 0x40..=0x7E {
		table[i] = .ALPHA
	}
	
	// 0x7F: DEL (treated as C0 for simplicity)
	table[0x7F] = .C0
	
	// 0x80-0xBF: UTF8_CONT
	for i in 0x80..=0xBF {
		table[i] = .UTF8_CONT
	}
	
	// 0xC0-0xFF: UTF8_LEAD
	for i in 0xC0..=0xFF {
		table[i] = .UTF8_LEAD
	}
	
	return table
}

// byte_class returns the byte class for classification.
byte_class :: proc(b: u8) -> Byte_Class {
	return BYTE_CLASS[b]
}

// TRANSITION_TABLE is the VT state machine transition table.
// Indexed by [state][byte] → Transition.
// 256 bytes × 8 states = 2KB (fits in L1 cache).
TRANSITION_TABLE: [len(Parser_State)][256]Transition

init_transition_table :: proc() -> [len(Parser_State)][256]Transition {
	table: [len(Parser_State)][256]Transition
	
	// Initialize all transitions to (Error, Ground) as default
	for state in 0..<len(Parser_State) {
		for byte in 0..<256 {
			table[state][byte] = Transition{.Error, .Ground}
		}
	}
	
	// Ground state
	for byte in 0x00..=0x07 {
		table[0][byte] = Transition{.Execute, .Ground}
	}
	table[0][0x08] = Transition{.Execute, .Ground} // BS
	table[0][0x09] = Transition{.Execute, .Ground} // TAB
	table[0][0x0A] = Transition{.Execute, .Ground} // LF
	for byte in 0x0B..=0x1A {
		table[0][byte] = Transition{.Execute, .Ground}
	}
	table[0][0x1B] = Transition{.Clear, .Escape} // ESC
	for byte in 0x1C..=0x1F {
		table[0][byte] = Transition{.Execute, .Ground}
	}
	for byte in 0x20..=0x7E {
		table[0][byte] = Transition{.Print, .Ground}
	}
	table[0][0x7F] = Transition{.Ignore, .Ground} // DEL
	for byte in 0x80..=0xBF {
		table[0][byte] = Transition{.Utf8, .Utf8} // UTF-8 continuation (invalid)
	}
	for byte in 0xC0..=0xFF {
		table[0][byte] = Transition{.Utf8, .Utf8} // UTF-8 lead
	}
	
	// Escape state
	for byte in 0x00..=0x17 {
		table[1][byte] = Transition{.Execute, .Escape}
	}
	table[1][0x18] = Transition{.Execute, .Ground} // CAN
	table[1][0x19] = Transition{.Execute, .Escape} // EM
	table[1][0x1A] = Transition{.Execute, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[1][byte] = Transition{.Execute, .Escape}
	}
	table[1][0x1B] = Transition{.Clear, .Escape} // ESC
	for byte in 0x20..=0x2F {
		table[1][byte] = Transition{.Collect, .Escape} // intermediate
	}
	for byte in 0x30..=0x4F {
		table[1][byte] = Transition{.EscDispatch, .Ground}
	}
	table[1][0x50] = Transition{.DcsHook, .DCS} // DCS
	table[1][0x51] = Transition{.EscDispatch, .Ground}
	table[1][0x52] = Transition{.EscDispatch, .Ground}
	table[1][0x53] = Transition{.EscDispatch, .Ground}
	table[1][0x54] = Transition{.EscDispatch, .Ground}
	table[1][0x55] = Transition{.EscDispatch, .Ground}
	table[1][0x56] = Transition{.EscDispatch, .Ground}
	table[1][0x57] = Transition{.EscDispatch, .Ground}
	table[1][0x58] = Transition{.Ignore, .Ground} // SOS
	table[1][0x59] = Transition{.EscDispatch, .Ground}
	table[1][0x5A] = Transition{.EscDispatch, .Ground}
	table[1][0x5B] = Transition{.Clear, .CSI_Entry} // CSI
	table[1][0x5C] = Transition{.EscDispatch, .Ground}
	table[1][0x5D] = Transition{.OscStart, .OSC} // OSC
	table[1][0x5E] = Transition{.Ignore, .Ground} // PM
	table[1][0x5F] = Transition{.Ignore, .Ground} // APC
	for byte in 0x60..=0x7E {
		table[1][byte] = Transition{.EscDispatch, .Ground}
	}
	table[1][0x7F] = Transition{.Ignore, .Escape} // DEL
	for byte in 0x80..=0xFF {
		table[1][byte] = Transition{.Utf8, .Utf8}
	}
	
	// CSI_Entry state
	for byte in 0x00..=0x17 {
		table[2][byte] = Transition{.Execute, .CSI_Entry}
	}
	table[2][0x18] = Transition{.Execute, .Ground} // CAN
	table[2][0x19] = Transition{.Execute, .CSI_Entry} // EM
	table[2][0x1A] = Transition{.Execute, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[2][byte] = Transition{.Execute, .CSI_Entry}
	}
	table[2][0x1B] = Transition{.Clear, .Escape} // ESC
	for byte in 0x20..=0x2F {
		table[2][byte] = Transition{.Collect, .CSI_Intermediate}
	}
	for byte in 0x30..=0x39 {
		table[2][byte] = Transition{.Param, .CSI_Param}
	}
	table[2][0x3A] = Transition{.Param, .CSI_Param} // colon
	table[2][0x3B] = Transition{.Param, .CSI_Param} // semicolon
	for byte in 0x3C..=0x3F {
		table[2][byte] = Transition{.Collect, .CSI_Param} // private marker
	}
	for byte in 0x40..=0x7E {
		table[2][byte] = Transition{.CsiDispatch, .Ground}
	}
	table[2][0x7F] = Transition{.Ignore, .CSI_Entry} // DEL
	for byte in 0x80..=0xFF {
		table[2][byte] = Transition{.Utf8, .Utf8}
	}
	
	// CSI_Param state
	for byte in 0x00..=0x17 {
		table[3][byte] = Transition{.Execute, .CSI_Param}
	}
	table[3][0x18] = Transition{.Execute, .Ground} // CAN
	table[3][0x19] = Transition{.Execute, .CSI_Param} // EM
	table[3][0x1A] = Transition{.Execute, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[3][byte] = Transition{.Execute, .CSI_Param}
	}
	table[3][0x1B] = Transition{.Clear, .Escape} // ESC
	for byte in 0x20..=0x2F {
		table[3][byte] = Transition{.Collect, .CSI_Intermediate}
	}
	for byte in 0x30..=0x39 {
		table[3][byte] = Transition{.Param, .CSI_Param}
	}
	table[3][0x3A] = Transition{.Param, .CSI_Param} // colon
	table[3][0x3B] = Transition{.Param, .CSI_Param} // semicolon
	for byte in 0x3C..=0x3F {
		table[3][byte] = Transition{.Collect, .CSI_Param}
	}
	for byte in 0x40..=0x7E {
		table[3][byte] = Transition{.CsiDispatch, .Ground}
	}
	table[3][0x7F] = Transition{.Ignore, .CSI_Param} // DEL
	for byte in 0x80..=0xFF {
		table[3][byte] = Transition{.Utf8, .Utf8}
	}
	
	// CSI_Intermediate state
	for byte in 0x00..=0x17 {
		table[4][byte] = Transition{.Execute, .CSI_Intermediate}
	}
	table[4][0x18] = Transition{.Execute, .Ground} // CAN
	table[4][0x19] = Transition{.Execute, .CSI_Intermediate} // EM
	table[4][0x1A] = Transition{.Execute, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[4][byte] = Transition{.Execute, .CSI_Intermediate}
	}
	table[4][0x1B] = Transition{.Clear, .Escape} // ESC
	for byte in 0x20..=0x2F {
		table[4][byte] = Transition{.Collect, .CSI_Intermediate}
	}
	for byte in 0x40..=0x7E {
		table[4][byte] = Transition{.CsiDispatch, .Ground}
	}
	table[4][0x7F] = Transition{.Ignore, .CSI_Intermediate} // DEL
	for byte in 0x80..=0xFF {
		table[4][byte] = Transition{.Utf8, .Utf8}
	}
	
	// OSC state
	for byte in 0x00..=0x17 {
		table[5][byte] = Transition{.Ignore, .OSC}
	}
	table[5][0x18] = Transition{.Ignore, .Ground} // CAN
	table[5][0x19] = Transition{.Ignore, .OSC} // EM
	table[5][0x1A] = Transition{.Ignore, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[5][byte] = Transition{.Ignore, .OSC}
	}
	table[5][0x1B] = Transition{.Ignore, .OSC} // ESC (start of ST)
	for byte in 0x20..=0x7E {
		table[5][byte] = Transition{.OscPut, .OSC}
	}
	table[5][0x7F] = Transition{.Ignore, .OSC} // DEL
	table[5][0x9C] = Transition{.OscEnd, .Ground} // ST
	for byte in 0x80..=0xFF {
		if byte != 0x9C {
			table[5][byte] = Transition{.OscPut, .OSC}
		}
	}
	
	// DCS state
	for byte in 0x00..=0x17 {
		table[6][byte] = Transition{.Ignore, .DCS}
	}
	table[6][0x18] = Transition{.Ignore, .Ground} // CAN
	table[6][0x19] = Transition{.Ignore, .DCS} // EM
	table[6][0x1A] = Transition{.Ignore, .Ground} // SUB
	for byte in 0x1C..=0x1F {
		table[6][byte] = Transition{.Ignore, .DCS}
	}
	table[6][0x1B] = Transition{.Ignore, .DCS} // ESC (start of ST)
	for byte in 0x20..=0x7E {
		table[6][byte] = Transition{.DcsPut, .DCS}
	}
	table[6][0x7F] = Transition{.Ignore, .DCS} // DEL
	table[6][0x9C] = Transition{.DcsUnhook, .Ground} // ST
	for byte in 0x80..=0xFF {
		if byte != 0x9C {
			table[6][byte] = Transition{.DcsPut, .DCS}
		}
	}
	
	// Utf8 state
	for byte in 0x00..=0x7F {
		table[7][byte] = Transition{.Print, .Ground} // ASCII resets to Ground
	}
	for byte in 0x80..=0xBF {
		table[7][byte] = Transition{.Utf8, .Utf8} // continuation
	}
	for byte in 0xC0..=0xFF {
		table[7][byte] = Transition{.Utf8, .Utf8} // new lead byte
	}
	
	return table
}

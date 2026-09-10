package render

// Atlas prewarm set: defines the pinned codepoints that are pre-rasterized at initialization.
// The pinned set is organized into contiguous ranges for O(1) slot lookup.
//
// Layout:
//   ASCII (32-126):        95 glyphs, slots 0-94
//   Box Drawing (2500-257F): 128 glyphs, slots 95-222
//   Block Elements (2580-259F): 32 glyphs, slots 223-254
//   Powerline (E0B0-E0BF): 16 glyphs, slots 255-270
//
// Total: 271 glyphs

// ASCII range (printable characters)
PINNED_ASCII_START :: 32
PINNED_ASCII_END   :: 126
PINNED_ASCII_COUNT :: PINNED_ASCII_END - PINNED_ASCII_START + 1  // 95

// Box Drawing range
PINNED_BOX_START :: 0x2500
PINNED_BOX_END   :: 0x257F
PINNED_BOX_COUNT :: PINNED_BOX_END - PINNED_BOX_START + 1  // 128

// Block Elements range
PINNED_BLOCK_START :: 0x2580
PINNED_BLOCK_END   :: 0x259F
PINNED_BLOCK_COUNT :: PINNED_BLOCK_END - PINNED_BLOCK_START + 1  // 32

// Powerline range
PINNED_POWERLINE_START :: 0xE0B0
PINNED_POWERLINE_END   :: 0xE0BF
PINNED_POWERLINE_COUNT :: PINNED_POWERLINE_END - PINNED_POWERLINE_START + 1  // 16

// Total pinned glyphs
PINNED_TOTAL :: PINNED_ASCII_COUNT + PINNED_BOX_COUNT + PINNED_BLOCK_COUNT + PINNED_POWERLINE_COUNT  // 271

// Slot offsets (contiguous layout)
PINNED_SLOT_ASCII    :: 0
PINNED_SLOT_BOX      :: PINNED_ASCII_COUNT  // 95
PINNED_SLOT_BLOCK    :: PINNED_SLOT_BOX + PINNED_BOX_COUNT  // 223
PINNED_SLOT_POWERLINE :: PINNED_SLOT_BLOCK + PINNED_BLOCK_COUNT  // 255

// atlas_prewarm_set returns a static slice of all pinned codepoints.
atlas_prewarm_set :: proc() -> []rune {
	// Build the complete set at compile time
	set := make([]rune, PINNED_TOTAL)
	idx := 0

	// ASCII range
	for cp in PINNED_ASCII_START..=PINNED_ASCII_END {
		set[idx] = rune(cp)
		idx += 1
	}

	// Box Drawing range
	for cp in PINNED_BOX_START..=PINNED_BOX_END {
		set[idx] = rune(cp)
		idx += 1
	}

	// Block Elements range
	for cp in PINNED_BLOCK_START..=PINNED_BLOCK_END {
		set[idx] = rune(cp)
		idx += 1
	}

	// Powerline range
	for cp in PINNED_POWERLINE_START..=PINNED_POWERLINE_END {
		set[idx] = rune(cp)
		idx += 1
	}

	return set
}

// atlas_pinned_slot_index returns the slot index for a pinned codepoint.
// Returns (index, true) if the codepoint is pinned, (0, false) otherwise.
// This is O(1) via range checks.
atlas_pinned_slot_index :: proc(codepoint: u32) -> (index: int, ok: bool) {
	// ASCII range
	if codepoint >= PINNED_ASCII_START && codepoint <= PINNED_ASCII_END {
		return PINNED_SLOT_ASCII + int(codepoint - PINNED_ASCII_START), true
	}

	// Box Drawing range
	if codepoint >= PINNED_BOX_START && codepoint <= PINNED_BOX_END {
		return PINNED_SLOT_BOX + int(codepoint - PINNED_BOX_START), true
	}

	// Block Elements range
	if codepoint >= PINNED_BLOCK_START && codepoint <= PINNED_BLOCK_END {
		return PINNED_SLOT_BLOCK + int(codepoint - PINNED_BLOCK_START), true
	}

	// Powerline range
	if codepoint >= PINNED_POWERLINE_START && codepoint <= PINNED_POWERLINE_END {
		return PINNED_SLOT_POWERLINE + int(codepoint - PINNED_POWERLINE_START), true
	}

	// Not pinned
	return 0, false
}

// atlas_nerd_present probes Nerd sentinel codepoints through the fallback
// chain. Pure read: counters stay untouched (nil passed to resolve).
atlas_nerd_present :: proc(chain: ^Fallback_Chain) -> bool {
	if chain == nil {
		return false
	}
	sentinels := [3]u32{0xE0B0, 0xE5FA, 0xF09B}
	for s in sentinels {
		if _, covered := fallback_resolve(chain, s, nil); covered {
			return true
		}
	}
	return false
}

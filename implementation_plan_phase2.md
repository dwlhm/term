# Phase 2 Implementation Plan: Scalar VT Parser

## Overview

Phase 2 implements a scalar VT parser that reads byte streams from the PTY and mutates terminal state. This is a two-level architecture: block scanner (ASCII fast path) + scalar VT state machine (for special bytes). No SIMD yet (Phase 13).

## Architectural Invariants (from vt-parser-invariants.md)

1. **Two-Level Architecture**: Block scanner (ASCII fast path) + state machine (special bytes only)
2. **State Machine Completeness**: Every byte has a defined action in every state
3. **CSI Parameter Storage**: Fixed [16]u32 array, zero allocation
4. **No Per-Character Callbacks**: PrintRun(start_col, length, style), not Print('h'); Print('e')
5. **Byte Classification**: 256-entry lookup table, not nested range checks
6. **UTF-8 Decoder**: Separate state machine, ASCII never enters decoder
7. **OSC/DCS Skipping**: Recognize → scan delimiter → discard, no copy/allocate
8. **Compact State Transitions**: Table-driven, no virtual calls or function pointers

## File Structure

```
src/parser/
├── parser.odin         - Top-level parser API
├── vt.odin             - VT state machine (state transitions)
├── csi.odin            - CSI sequence parsing and dispatch
├── utf8.odin           - UTF-8 decoding
├── ascii_scan.odin     - ASCII fast path (scalar, not SIMD yet)
└── tests/
    └── parser_test.odin - Unit and integration tests
```

## Data Flow Diagram

```
PTY bytes (input: []u8)
    ↓
┌─────────────────────────────────────────────────────────────┐
│ parse_chunk(p: ^Parser, t: ^Terminal, input: []u8)          │
│                                                             │
│  pos := 0                                                   │
│  while pos < len(input):                                    │
│    ↓                                                        │
│    ┌─────────────────────────────────────────────────────┐  │
│    │ Level 1: Block Scanner (ascii_scan.odin)            │  │
│    │                                                     │  │
│    │ if p.state == Ground:                               │  │
│    │   run := scan_ascii_run(input[pos:])                │  │
│    │   if run.length > 0:                                │  │
│    │     terminal_print_run(t, run.data, t.current_style)│  │
│    │     pos += run.length                               │  │
│    │     continue                                        │  │
│    └─────────────────────────────────────────────────────┘  │
│    ↓                                                        │
│    ┌─────────────────────────────────────────────────────┐  │
│    │ Level 2: VT State Machine (vt.odin)                 │  │
│    │                                                     │  │
│    │ byte := input[pos]                                  │  │
│    │ transition := TRANSITION_TABLE[p.state][byte]       │  │
│    │                                                     │  │
│    │ switch transition.action:                           │  │
│    │   case .Print:                                      │  │
│    │     accumulate_print_run(p, byte)                   │  │
│    │   case .Execute:                                    │  │
│    │     execute_c0(t, byte)                             │  │
│    │   case .Clear:                                      │  │
│    │     clear_parser_state(p)                           │  │
│    │   case .Param:                                      │  │
│    │     csi_collect_param(p, byte)                      │  │
│    │   case .CsiDispatch:                                │  │
│    │     csi_dispatch(p, t, byte)                        │  │
│    │   case .EscDispatch:                                │  │
│    │     esc_dispatch(p, t, byte)                        │  │
│    │   case .OscStart:                                   │  │
│    │     p.state = .OSC                                  │  │
│    │   case .OscPut:                                     │  │
│    │     // discard OSC payload                          │  │
│    │   case .OscEnd:                                     │  │
│    │     p.state = .Ground                               │  │
│    │   case .Utf8:                                       │  │
│    │     utf8_feed(p, t, byte)                           │  │
│    │                                                     │  │
│    │ p.state = transition.next_state                     │  │
│    │ pos += 1                                            │  │
│    └─────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
    ↓
Terminal state mutated (grid, cursor, damage)
```

## Symbol Signatures

### 1. parser.odin (Top-Level API)

```odin
package parser

import "base:runtime"
import "../terminal"

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
    
    // Print run accumulator (for Level 1 fast path)
    print_run_start: int,
    print_run_len:   int,
}

// parser_init initializes a parser.
parser_init :: proc(p: ^Parser)

// parser_destroy frees parser state (currently no-op, but future-proof).
parser_destroy :: proc(p: ^Parser)

// parse_chunk parses a chunk of bytes and mutates terminal state.
// This is the main entry point called by the I/O layer.
parse_chunk :: proc(p: ^Parser, t: ^termgrid.Terminal, input: []u8)

// parser_get_state returns the current parser state (for testing/debugging).
parser_get_state :: proc(p: ^Parser) -> Parser_State

// parser_reset resets the parser to Ground state.
parser_reset :: proc(p: ^Parser)
```

### 2. ascii_scan.odin (Block Scanner)

```odin
package parser

// ASCII_Run represents a run of printable ASCII bytes.
ASCII_Run :: struct {
    data:   []u8,  // slice of printable ASCII bytes
    length: int,   // number of bytes in run
}

// scan_ascii_run scans for a run of printable ASCII bytes (0x20-0x7E).
// Returns the run and the number of bytes consumed.
// Stops at first non-printable byte (ESC, C0 control, UTF-8 lead, etc.).
scan_ascii_run :: proc(input: []u8) -> ASCII_Run

// is_printable_ascii returns true if byte is printable ASCII (0x20-0x7E).
is_printable_ascii :: proc(b: u8) -> bool
```

### 3. vt.odin (VT State Machine)

```odin
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

// TRANSITION_TABLE is the VT state machine transition table.
// Indexed by [state][byte] → Transition.
// 256 bytes × 8 states = 2KB (fits in L1 cache).
TRANSITION_TABLE: [len(Parser_State)][256]Transition = {...}

// byte_class returns the byte class for classification.
byte_class :: proc(b: u8) -> Byte_Class

// Byte_Class is the classification of a byte.
Byte_Class :: enum u8 {
    PRINT,         // 0x20-0x7E (printable ASCII)
    C0,            // 0x00-0x1F (C0 controls)
    UTF8_LEAD,     // 0xC0-0xFF (UTF-8 lead bytes)
    UTF8_CONT,     // 0x80-0xBF (UTF-8 continuation bytes)
    ESC,           // 0x1B (escape)
    DIGIT,         // 0x30-0x39 (0-9)
    SEMI,          // 0x3B (;)
    COLON,         // 0x3A (:)
    INTERMEDIATE,  // 0x20-0x2F (space to /)
    PRIVATE,       // 0x3C-0x3F (< = > ?)
    ALPHA,         // 0x40-0x7E (A-Z, a-z, etc.)
}

// BYTE_CLASS is the byte classification lookup table.
// 256 entries, one per byte value.
BYTE_CLASS: [256]Byte_Class = {...}
```

### 4. csi.odin (CSI Sequence Parsing)

```odin
package parser

// CSI_Params holds CSI parameters.
CSI_Params :: struct {
    values: [16]u32,  // max 16 parameters (DEC limit)
    count:  u8,       // number of parameters collected
}

// csi_collect_param collects a CSI parameter byte.
// Handles digits (0-9), semicolon (;), and colon (:).
csi_collect_param :: proc(p: ^Parser, b: u8)

// csi_dispatch dispatches a CSI sequence.
// Called when the final byte of a CSI sequence is received.
csi_dispatch :: proc(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8)

// csi_reset resets CSI parameter state.
csi_reset :: proc(p: ^Parser)

// Internal helpers
_csi_execute_cuu :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Cursor Up
_csi_execute_cud :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Cursor Down
_csi_execute_cuf :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Cursor Forward
_csi_execute_cub :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Cursor Back
_csi_execute_cup :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Cursor Position
_csi_execute_el  :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Erase in Line
_csi_execute_ed  :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Erase in Display
_csi_execute_su  :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Scroll Up
_csi_execute_sd  :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Scroll Down
_csi_execute_sgr :: proc(t: ^termgrid.Terminal, params: CSI_Params)  // Select Graphic Rendition
```

### 5. utf8.odin (UTF-8 Decoder)

```odin
package parser

// UTF8_State is the UTF-8 decoder state.
UTF8_State :: enum u8 {
    Ground,  // expecting lead byte
    Byte2,   // expecting 1 continuation byte
    Byte3,   // expecting 2 continuation bytes
    Byte4,   // expecting 3 continuation bytes
}

// utf8_feed feeds a byte to the UTF-8 decoder.
// If the sequence is complete, emits the rune to the terminal.
// If the sequence is invalid, emits replacement char (U+FFFD).
utf8_feed :: proc(p: ^Parser, t: ^termgrid.Terminal, b: u8)

// utf8_reset resets the UTF-8 decoder state.
utf8_reset :: proc(p: ^Parser)

// Internal helpers
_utf8_decode_lead :: proc(b: u8) -> (expected_len: u8, initial_value: u32)
_utf8_decode_cont :: proc(p: ^Parser, b: u8) -> (complete: bool, rune: u32)
```

### 6. Terminal Integration (parser calls terminal API)

```odin
// These functions are called by the parser to mutate terminal state.
// They wrap the terminal API to provide the parser's view of the terminal.

terminal_print_run :: proc(t: ^termgrid.Terminal, data: []u8, style: termgrid.Style_Id) {
    // For each rune in data:
    //   terminal_put_char(t, rune)
    // Future optimization: batch write for ASCII runs
}

execute_c0 :: proc(t: ^termgrid.Terminal, b: u8) {
    switch b {
    case 0x08: // BS (Backspace)
        terminal_cursor_left(t, 1)
    case 0x09: // TAB
        // Advance to next tab stop (simplified: advance 8 columns)
        terminal_cursor_right(t, 8 - (t.cursor.col % 8))
    case 0x0A: // LF (Line Feed)
        terminal_newline(t)
    case 0x0D: // CR (Carriage Return)
        t.cursor.col = 0
    }
}
```

## MECE Completeness Tables

### Table 1: Parser State Transitions (Ground State)

| Input Byte | Action | Next State | Result/Crack |
|------------|--------|------------|--------------|
| 0x00-0x07, 0x0E-0x1A, 0x1C-0x1F | Execute | Ground | Result: execute C0 control |
| 0x08 (BS) | Execute | Ground | Result: cursor left 1 |
| 0x09 (TAB) | Execute | Ground | Result: cursor to next tab stop |
| 0x0A (LF) | Execute | Ground | Result: newline |
| 0x0D (CR) | Execute | Ground | Result: cursor to column 0 |
| 0x1B (ESC) | Clear | Escape | Result: clear state, enter Escape |
| 0x20-0x7E | Print | Ground | Result: accumulate print run |
| 0x7F (DEL) | Ignore | Ground | Result: no-op |
| 0x80-0xBF | Utf8 | Utf8 | Crack: invalid UTF-8 start → replacement char |
| 0xC0-0xFF | Utf8 | Utf8 | Result: enter UTF-8 decode state |

### Table 2: Parser State Transitions (Escape State)

| Input Byte | Action | Next State | Result/Crack |
|------------|--------|------------|--------------|
| 0x00-0x17, 0x19, 0x1C-0x1F | Execute | Escape | Result: execute C0 control |
| 0x1B (ESC) | Clear | Escape | Result: clear state, stay in Escape |
| 0x20-0x2F | Collect | Escape_Intermediate | Result: collect intermediate byte |
| 0x30-0x4F, 0x51-0x5A, 0x5C, 0x60-0x7E | EscDispatch | Ground | Result: dispatch escape sequence |
| 0x5B ('[') | Clear | CSI_Entry | Result: enter CSI sequence |
| 0x5D (']') | OscStart | OSC | Result: enter OSC sequence |
| 0x50 ('P') | DcsHook | DCS | Result: enter DCS sequence |
| 0x58, 0x5E, 0x5F | Ignore | SOS_PM_APC | Result: ignore (not supported) |
| 0x7F (DEL) | Ignore | Escape | Result: no-op |
| 0x80-0xFF | Utf8 | Utf8 | Result: enter UTF-8 decode state |

### Table 3: Parser State Transitions (CSI_Param State)

| Input Byte | Action | Next State | Result/Crack |
|------------|--------|------------|--------------|
| 0x00-0x17, 0x19, 0x1C-0x1F | Execute | CSI_Param | Result: execute C0 control |
| 0x1B (ESC) | Clear | Escape | Result: cancel CSI, enter Escape |
| 0x20-0x2F | Collect | CSI_Intermediate | Result: collect intermediate byte |
| 0x30-0x39 (0-9) | Param | CSI_Param | Result: accumulate digit |
| 0x3A (:) | Param | CSI_Param | Result: accumulate colon (sub-parameter) |
| 0x3B (;) | Param | CSI_Param | Result: next parameter |
| 0x3C-0x3F (< = > ?) | Collect | CSI_Param | Result: collect private marker |
| 0x40-0x7E | CsiDispatch | Ground | Result: dispatch CSI sequence |
| 0x7F (DEL) | Ignore | CSI_Param | Result: no-op |
| 0x80-0xFF | Utf8 | Utf8 | Result: enter UTF-8 decode state |

### Table 4: CSI Sequence Dispatch (Final Byte)

| Final Byte | Mnemonic | Action | Parameters |
|------------|----------|--------|------------|
| 'A' (0x41) | CUU | Cursor Up | params[0] = n (default 1) |
| 'B' (0x42) | CUD | Cursor Down | params[0] = n (default 1) |
| 'C' (0x43) | CUF | Cursor Forward | params[0] = n (default 1) |
| 'D' (0x44) | CUB | Cursor Back | params[0] = n (default 1) |
| 'H' (0x48) | CUP | Cursor Position | params[0] = row, params[1] = col (default 1,1) |
| 'J' (0x4A) | ED | Erase in Display | params[0] = mode (0=to end, 1=to beginning, 2=entire) |
| 'K' (0x4B) | EL | Erase in Line | params[0] = mode (0=to end, 1=to beginning, 2=entire) |
| 'S' (0x53) | SU | Scroll Up | params[0] = n (default 1) |
| 'T' (0x54) | SD | Scroll Down | params[0] = n (default 1) |
| 'm' (0x6D) | SGR | Select Graphic Rendition | params[0..n] = SGR codes |

### Table 5: UTF-8 Decoding

| Lead Byte | Expected Length | Initial Value | Result/Crack |
|-----------|-----------------|---------------|--------------|
| 0x00-0x7F | 1 | byte value | Result: ASCII, emit rune directly |
| 0x80-0xBF | — | — | Crack: invalid lead byte → replacement char |
| 0xC0-0xDF | 2 | byte & 0x1F | Result: 2-byte sequence |
| 0xE0-0xEF | 3 | byte & 0x0F | Result: 3-byte sequence |
| 0xF0-0xF7 | 4 | byte & 0x07 | Result: 4-byte sequence |
| 0xF8-0xFF | — | — | Crack: invalid lead byte → replacement char |

| Continuation Byte | Action | Result/Crack |
|-------------------|--------|--------------|
| 0x80-0xBF | Accumulate | Result: continue decoding |
| 0x00-0x7F, 0xC0-0xFF | — | Crack: invalid continuation → replacement char |

### Table 6: OSC/DCS Skipping

| State | Input Byte | Action | Next State | Result/Crack |
|-------|------------|--------|------------|--------------|
| OSC | 0x00-0x17, 0x19, 0x1C-0x1F | Ignore | OSC | Result: ignore C0 control |
| OSC | 0x1B (ESC) | Ignore | OSC_End | Result: scan for ST terminator |
| OSC | 0x20-0x7E | OscPut | OSC | Result: discard payload byte |
| OSC | 0x9C (ST) | OscEnd | Ground | Result: end OSC sequence |
| DCS | 0x00-0x17, 0x19, 0x1C-0x1F | Ignore | DCS | Result: ignore C0 control |
| DCS | 0x1B (ESC) | Ignore | DCS_End | Result: scan for ST terminator |
| DCS | 0x20-0x7E | DcsPut | DCS | Result: discard payload byte |
| DCS | 0x9C (ST) | DcsUnhook | Ground | Result: end DCS sequence |

## Implementation Order

### Step 1: utf8.odin (UTF-8 Decoder)

**Rationale**: UTF-8 decoding is orthogonal to VT parsing. Implement and test independently.

**Symbols**:
- `UTF8_State` (enum)
- `utf8_feed(p: ^Parser, t: ^termgrid.Terminal, b: u8)`
- `utf8_reset(p: ^Parser)`
- `_utf8_decode_lead(b: u8) -> (expected_len: u8, initial_value: u32)`
- `_utf8_decode_cont(p: ^Parser, b: u8) -> (complete: bool, rune: u32)`

**Tests**:
1. ASCII byte (0x41) → rune U+0041
2. 2-byte UTF-8 (0xC3 0xA9) → rune U+00E9 (é)
3. 3-byte UTF-8 (0xE2 0x82 0xAC) → rune U+20AC (€)
4. 4-byte UTF-8 (0xF0 0x9F 0x98 0x80) → rune U+1F600 (😀)
5. Invalid lead byte (0x80) → replacement char U+FFFD
6. Invalid continuation (0xC3 0x20) → replacement char U+FFFD
7. Truncated sequence (0xC3 at end of input) → replacement char U+FFFD

### Step 2: ascii_scan.odin (Block Scanner)

**Rationale**: Block scanner is the fast path. Implement and test independently.

**Symbols**:
- `ASCII_Run` (struct)
- `scan_ascii_run(input: []u8) -> ASCII_Run`
- `is_printable_ascii(b: u8) -> bool`

**Tests**:
1. All printable ASCII ("hello") → run length 5
2. Empty input → run length 0
3. ESC in middle ("hel\x1blo") → run length 3
4. UTF-8 lead byte ("hel\xC3lo") → run length 3
5. C0 control ("hel\x0Alo") → run length 3
6. All printable ASCII (256 bytes) → run length 256

### Step 3: vt.odin (VT State Machine)

**Rationale**: State machine is the core. Implement after UTF-8 and scanner are tested.

**Symbols**:
- `Parser_State` (enum)
- `Action` (enum)
- `Transition` (struct)
- `TRANSITION_TABLE: [len(Parser_State)][256]Transition`
- `Byte_Class` (enum)
- `BYTE_CLASS: [256]Byte_Class`
- `byte_class(b: u8) -> Byte_Class`

**Tests**:
1. Ground + 'A' (0x41) → (Print, Ground)
2. Ground + ESC (0x1B) → (Clear, Escape)
3. Escape + '[' (0x5B) → (Clear, CSI_Entry)
4. CSI_Entry + '1' (0x31) → (Param, CSI_Param)
5. CSI_Param + ';' (0x3B) → (Param, CSI_Param)
6. CSI_Param + 'H' (0x48) → (CsiDispatch, Ground)
7. Ground + UTF-8 lead (0xC3) → (Utf8, Utf8)

### Step 4: csi.odin (CSI Sequence Parsing)

**Rationale**: CSI parsing is high-frequency. Implement after state machine is tested.

**Symbols**:
- `CSI_Params` (struct)
- `csi_collect_param(p: ^Parser, b: u8)`
- `csi_dispatch(p: ^Parser, t: ^termgrid.Terminal, final_byte: u8)`
- `csi_reset(p: ^Parser)`
- `_csi_execute_cuu`, `_csi_execute_cud`, `_csi_execute_cuf`, `_csi_execute_cub`, `_csi_execute_cup`, `_csi_execute_el`, `_csi_execute_ed`, `_csi_execute_su`, `_csi_execute_sd`, `_csi_execute_sgr`

**Tests**:
1. `ESC[1;2H` → cursor to row 1, col 2
2. `ESC[3A` → cursor up 3
3. `ESC[2B` → cursor down 2
4. `ESC[4C` → cursor forward 4
5. `ESC[5D` → cursor back 5
6. `ESC[K` → erase to end of line
7. `ESC[1K` → erase to beginning of line
8. `ESC[2K` → erase entire line
9. `ESC[J` → erase to end of display
10. `ESC[2S` → scroll up 2
11. `ESC[3T` → scroll down 3
12. `ESC[31m` → set foreground color to red
13. `ESC[0m` → reset style to default
14. `ESC[1;2;3;...;16H` → 16 parameters stored
15. `ESC[1;2;3;...;17H` → 17th parameter ignored

### Step 5: parser.odin (Top-Level API)

**Rationale**: Top-level API integrates all components. Implement last.

**Symbols**:
- `Parser` (struct)
- `parser_init(p: ^Parser)`
- `parser_destroy(p: ^Parser)`
- `parse_chunk(p: ^Parser, t: ^termgrid.Terminal, input: []u8)`
- `parser_get_state(p: ^Parser) -> Parser_State`
- `parser_reset(p: ^Parser)`
- `terminal_print_run(t: ^termgrid.Terminal, data: []u8, style: termgrid.Style_Id)`
- `execute_c0(t: ^termgrid.Terminal, b: u8)`

**Tests**: Integration tests (see below).

### Step 6: tests/parser_test.odin (Unit and Integration Tests)

**Unit Tests**:
1. ASCII fast path (printable runs)
2. Control characters (CR, LF, BS, TAB)
3. CSI sequences (SGR, CUP, CUU/CUD/CUF/CUB, EL, ED)
4. UTF-8 decoding (2-byte, 3-byte, 4-byte sequences)
5. OSC/DCS skipping
6. Parser state transitions
7. Invalid/truncated sequences

**Integration Tests**:
1. Simple text: "hello world"
   - Input: `"hello world"`
   - Expected: row 0 = "hello world", cursor at (0, 11)
2. Colored text: "ESC[31mRED ESC[0m"
   - Input: `"\x1B[31mRED \x1B[0m"`
   - Expected: row 0 = "RED ", cells 0-2 have red foreground, cell 3 has default style
3. Cursor movement: "ESC[2;5H" (move to row 2, col 5)
   - Input: `"\x1B[2;5H"`
   - Expected: cursor at (1, 4) (0-indexed)
4. Erase operations: "ESC[K" (erase to end of line)
   - Input: `"hello\x1B[K"`
   - Expected: row 0 = "hello", cells 5+ are blank
5. Scroll: "ESC[2S" (scroll up 2 lines)
   - Input: `"\x1B[2S"`
   - Expected: grid scrolled up 2 rows, bottom 2 rows cleared
6. Mixed: text + colors + cursor movement
   - Input: `"hello \x1B[31mRED\x1B[0m \x1B[2;1Hworld"`
   - Expected: row 0 = "hello RED", row 1 = "world", cursor at (1, 5)

**Correctness Oracle**:
- Parser input → semantic state → snapshot
- Compare expected cursor, cells, styles, scroll region
- Golden tests for common sequences

**Performance Tests** (using Phase 0 benchmark):
- Bytes/sec throughput (target: > 100 MB/s for ASCII)
- Cycles/byte (target: < 10 cycles/byte for ASCII)
- ASCII fast-path ratio (target: > 95% for typical terminal output)
- CSI sequences/sec (target: > 1M sequences/sec)

## Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| ASCII throughput | > 100 MB/s | PTY bandwidth is ~10-50 MB/s, parser should not be bottleneck |
| Cycles/byte (ASCII) | < 10 cycles/byte | Block scanner should be very fast |
| ASCII fast-path ratio | > 95% | Typical terminal output is 95%+ printable ASCII |
| CSI sequences/sec | > 1M sequences/sec | High-frequency TUI apps (vim, htop) should not be bottleneck |
| Memory allocation | Zero in steady state | All data structures pre-allocated |

## Future Work (Phase 13: SIMD)

Phase 2 is scalar. Phase 13 will add SIMD optimization:
- Replace `scan_ascii_run` with SIMD scanner (NEON/SSE)
- Process 16-32 bytes per iteration
- Same API, faster implementation
- Scalar fallback for non-SIMD platforms

## Delta Report

**Zero deviations from the approved plan.** This plan follows all architectural invariants from vt-parser-invariants.md.

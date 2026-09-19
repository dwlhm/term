# Phase 1 Implementation Plan — Terminal Grid

## Executive Summary

Phase 1 implements the semantic state layer of a high-performance terminal emulator in Odin: grid with ring buffer row storage, hierarchical damage tracking, and scroll operations. This layer receives parsed input (Phase 2) and produces damage journals for the renderer (Phase 3).

**Key Invariants**:
- O(1) scroll via ring buffer rotation (no row movement)
- O(1) cell mutation with damage tracking at mutation time
- Style table deduplication (cells store style_id, not full style)
- Zero allocations in steady state (after initialization)

---

## 1. Localized Architecture Data Flow

```mermaid
graph TD
    subgraph "Terminal API Layer"
        A[terminal_put_char] --> B[grid_set_cell]
        A --> C[cursor_advance]
        D[terminal_scroll_up] --> E[grid_scroll_up]
        F[terminal_take_damage] --> G[damage_take_journal]
    end
    
    subgraph "Grid Layer (Ring Buffer)"
        B --> H[physical_row = logical_row & mask]
        H --> I[row.cells[col] = cell]
        I --> J[row.generation += 1]
        E --> K[origin = (origin + n) & mask]
        K --> L[clear_rows(bottom-n+1, bottom)]
    end
    
    subgraph "Damage Tracking Layer"
        J --> M[damage_mark_cell]
        L --> N[damage_mark_row]
        M --> O[dirty_row.spans[span_count++] = {col, col+1}]
        N --> P[dirty_row.full = true]
        G --> Q[journal = {dirty_rows, scroll_ops}]
        Q --> R[damage_clear]
    end
    
    subgraph "Style Table"
        B --> S[style_table[cell.style]]
        S --> T[Style{fg, bg, underline, flags}]
    end
    
    subgraph "Scroll Operations"
        E --> U[damage_record_scroll]
        U --> V[scroll_ops = append{top, bottom, n}]
    end
    
    style A fill:#e1f5ff
    style B fill:#fff4e1
    style E fill:#fff4e1
    style F fill:#e1f5ff
    style M fill:#ffe1f5
    style U fill:#ffe1f5
```

**Data Flow Annotations**:

| Node | Result | Crack | Need |
|------|--------|-------|------|
| `terminal_put_char` | Cell written, cursor advanced | Cursor out of bounds → clamp | Grid, Cursor, Damage |
| `grid_set_cell` | Cell updated, generation incremented | Row/col out of bounds → no-op | Ring buffer, Style table |
| `grid_scroll_up` | Origin incremented, rows cleared | n > rows → clamp to rows | Ring buffer, Damage |
| `damage_mark_cell` | Span added to dirty row | Span overflow (>4) → mark full row | Dirty row array |
| `damage_take_journal` | Journal returned, damage cleared | No damage → empty journal | Dirty rows, Scroll ops |

---

## 2. MECE State Table

### Grid Operations

| Input Variant | `grid_set_cell` | `grid_scroll_up` | `grid_clear` |
|---------------|-----------------|------------------|--------------|
| **Happy path** (valid row/col, n ≤ rows) | Result: cell updated, generation++, damage marked | Result: origin incremented, bottom n rows cleared, damage marked | Result: all cells cleared, all generations = 0, all rows marked dirty |
| **Edge: row/col out of bounds** | Crack: InvalidIndex → no-op, return | — | — |
| **Edge: n > rows** | — | Crack: Overflow → clamp n to rows, scroll all | — |
| **Edge: n = 0** | — | Result: no-op (origin unchanged) | — |
| **Edge: empty grid (rows=0)** | Crack: EmptyGrid → no-op | Crack: EmptyGrid → no-op | Crack: EmptyGrid → no-op |
| **Edge: style_id invalid** | Crack: InvalidStyle → use default style (id=0) | — | — |

### Damage Operations

| Input Variant | `damage_mark_cell` | `damage_mark_span` | `damage_take_journal` |
|---------------|-------------------|-------------------|----------------------|
| **Happy path** (valid row/col, span_count < 4) | Result: span added to dirty_row.spans | Result: span added to dirty_row.spans | Result: journal returned, damage cleared |
| **Edge: row out of bounds** | Crack: InvalidRow → no-op | Crack: InvalidRow → no-op | — |
| **Edge: col out of bounds** | Crack: InvalidCol → clamp to [0, cols-1] | Crack: InvalidCol → clamp to [0, cols-1] | — |
| **Edge: span overflow (span_count ≥ 4)** | — | Crack: Overflow → set dirty_row.full = true, clear spans | — |
| **Edge: no damage** | — | — | Result: return empty journal |
| **Edge: col_start > col_end** | — | Crack: InvalidSpan → swap col_start and col_end | — |

### Terminal Operations

| Input Variant | `terminal_put_char` | `terminal_scroll_up` | `terminal_move_cursor` |
|---------------|---------------------|----------------------|----------------------|
| **Happy path** (valid cursor position) | Result: cell written, cursor.col++ | Result: origin incremented, rows cleared, scroll op recorded | Result: cursor position updated, row marked dirty |
| **Edge: cursor at right edge (col = cols-1)** | Result: cursor.col = 0, cursor.row++ (wrap) | — | — |
| **Edge: cursor at bottom (row = rows-1)** | Result: scroll_up(1), cursor.row unchanged | — | — |
| **Edge: wide char (width=2)** | Result: cell written, next cell marked as continuation | — | — |
| **Edge: n > rows** | — | Crack: Overflow → clamp n to rows | — |
| **Edge: row/col out of bounds** | — | — | Crack: InvalidPosition → clamp to [0, rows-1] × [0, cols-1] |

---

## 3. Exact Symbol Signatures

### File: `src/terminal/cell.odin`

```odin
package terminal

// Content_Handle represents a reference to character content (codepoint or grapheme).
// Phase 1: only codepoints (rune). Phase 2: grapheme clusters.
Content_Handle :: u32

// Cell_Flags is a bitfield for cell metadata.
Cell_Flags :: bit_field u8 {
    .None              = 0,
    .Wide_Continuation = 1 << 0,  // this cell is the right half of a wide char
    .Dirty             = 1 << 1,  // cell has been modified (for internal tracking)
}

// Semantic_Cell represents a single cell in the terminal grid.
// Size: 12 bytes (target: ≤ 16 bytes)
Semantic_Cell :: struct {
    content:   Content_Handle,  // codepoint or grapheme handle
    style:     Style_Id,        // index into style table
    width:     u8,              // character width (1 or 2 for wide chars)
    flags:     Cell_Flags,      // bitfield metadata
}

// CELL_DEFAULT is the default cell (empty, default style, width 1).
CELL_DEFAULT :: Semantic_Cell{
    content = 0,
    style   = 0,
    width   = 1,
    flags   = .None,
}
```

### File: `src/terminal/style.odin`

```odin
package terminal

// Style_Id is an index into the style table.
Style_Id :: u16

// Style represents the visual attributes of a cell.
// Size: 16 bytes
Style :: struct {
    fg:        u32,  // foreground color (ARGB or palette index)
    bg:        u32,  // background color
    underline: u32,  // underline color
    flags:     u16,  // bitfield: bold, italic, underline_style, etc.
}

// STYLE_DEFAULT is the default style (white on black, no decoration).
STYLE_DEFAULT :: Style{
    fg        = 0xFFFFFFFF,  // white
    bg        = 0xFF000000,  // black
    underline = 0,
    flags     = 0,
}

// Style_Table is a deduplication table for styles.
// Capacity: 1024 entries (configurable).
Style_Table :: struct {
    entries: [1024]Style,
    count:   u16,
}

// style_table_init initializes a style table with the default style at index 0.
style_table_init :: proc(t: ^Style_Table)

// style_table_insert inserts a style into the table and returns its ID.
// If the style already exists, returns the existing ID (deduplication).
// If the table is full, returns 0 (default style).
style_table_insert :: proc(t: ^Style_Table, s: Style) -> Style_Id

// style_table_get retrieves a style by ID.
// If the ID is invalid, returns STYLE_DEFAULT.
style_table_get :: proc(t: ^Style_Table, id: Style_Id) -> Style
```

### File: `src/terminal/row.odin`

```odin
package terminal

// Row represents a single row in the terminal grid.
// Each row has a generation counter for damage tracking.
Row :: struct {
    cells:       []Semantic_Cell,  // length = grid.col_count
    generation:  u32,              // incremented on every mutation
}

// row_init initializes a row with the specified number of columns.
// All cells are set to CELL_DEFAULT, generation = 0.
row_init :: proc(r: ^Row, cols: int, allocator: runtime.Allocator = context.allocator)

// row_destroy frees the cells array.
row_destroy :: proc(r: ^Row, allocator: runtime.Allocator = context.allocator)

// row_clear resets all cells to CELL_DEFAULT and increments generation.
row_clear :: proc(r: ^Row)

// row_set_cell sets a cell at the specified column and increments generation.
// Returns false if col is out of bounds.
row_set_cell :: proc(r: ^Row, col: int, cell: Semantic_Cell) -> bool
```

### File: `src/terminal/grid.odin`

```odin
package terminal

// Grid represents the terminal grid with ring buffer row storage.
// Capacity is always a power of 2 for fast modulo.
Grid :: struct {
    rows:       []Row,      // length = capacity (power of 2)
    row_count:  int,        // logical number of rows (visible area)
    col_count:  int,        // number of columns
    capacity:   int,        // power of 2, ≥ row_count
    origin:     int,        // ring buffer origin (physical index of logical row 0)
    mask:       int,        // capacity - 1 (for fast modulo)
    style_table: Style_Table,
}

// grid_init initializes a grid with the specified dimensions.
// Capacity is rounded up to the next power of 2.
grid_init :: proc(g: ^Grid, rows, cols: int, allocator: runtime.Allocator = context.allocator)

// grid_destroy frees all rows and the style table.
grid_destroy :: proc(g: ^Grid, allocator: runtime.Allocator = context.allocator)

// grid_get_cell retrieves a cell at the specified logical position.
// Returns CELL_DEFAULT if row/col is out of bounds.
grid_get_cell :: proc(g: ^Grid, row, col: int) -> Semantic_Cell

// grid_set_cell sets a cell at the specified logical position.
// Returns false if row/col is out of bounds.
grid_set_cell :: proc(g: ^Grid, row, col: int, cell: Semantic_Cell) -> bool

// grid_clear resets all cells to CELL_DEFAULT and marks all rows dirty.
grid_clear :: proc(g: ^Grid)

// grid_scroll_up scrolls the grid up by n rows (ring buffer rotation).
// Returns the number of rows actually scrolled (may be clamped).
grid_scroll_up :: proc(g: ^Grid, n: int) -> int

// grid_scroll_down scrolls the grid down by n rows (ring buffer rotation).
// Returns the number of rows actually scrolled (may be clamped).
grid_scroll_down :: proc(g: ^Grid, n: int) -> int

// _grid_physical_row converts a logical row index to a physical index.
_inline :: proc(g: ^Grid, logical_row: int) -> int {
    return (g.origin + logical_row) & g.mask
}
```

### File: `src/terminal/damage.odin`

```odin
package terminal

// Span represents a contiguous range of dirty cells in a row.
Span :: struct {
    col_start: u16,
    col_end:   u16,  // exclusive
}

// Dirty_Row represents the dirty state of a single row.
// Uses a fixed-size array of spans (max 4). If overflow, degrades to full row.
Dirty_Row :: struct {
    generation:  u32,       // matches row.generation for validation
    span_count:  u8,        // number of spans (0-4)
    spans:       [4]Span,   // fixed array
    full:        bool,      // true if entire row is dirty
}

// Scroll_Op represents a structural scroll operation.
Scroll_Op :: struct {
    top:    u16,  // top of scroll region (inclusive)
    bottom: u16,  // bottom of scroll region (inclusive)
    rows:   i16,  // positive = scroll up, negative = scroll down
}

// Damage tracks all mutations since last clear.
Damage :: struct {
    dirty_rows:  []Dirty_Row,  // length = grid.row_count
    scroll_ops:  []Scroll_Op,  // dynamic array (rarely used)
    row_count:   int,
}

// Damage_Journal is a snapshot of all damage for the renderer.
Damage_Journal :: struct {
    dirty_rows:  []Dirty_Row,
    scroll_ops:  []Scroll_Op,
}

// damage_init initializes damage tracking for the specified number of rows.
damage_init :: proc(d: ^Damage, rows: int, allocator: runtime.Allocator = context.allocator)

// damage_destroy frees all damage tracking state.
damage_destroy :: proc(d: ^Damage, allocator: runtime.Allocator = context.allocator)

// damage_mark_cell marks a single cell as dirty.
damage_mark_cell :: proc(d: ^Damage, row, col: int, generation: u32)

// damage_mark_span marks a range of cells as dirty.
damage_mark_span :: proc(d: ^Damage, row, col_start, col_end: int, generation: u32)

// damage_mark_row marks an entire row as dirty.
damage_mark_row :: proc(d: ^Damage, row: int, generation: u32)

// damage_mark_all marks all rows as dirty.
damage_mark_all :: proc(d: ^Damage, generations: []u32)

// damage_record_scroll records a structural scroll operation.
damage_record_scroll :: proc(d: ^Damage, top, bottom: int, rows: int)

// damage_take_journal returns a snapshot of all damage and clears it.
// The caller owns the returned journal and must call damage_journal_destroy.
damage_take_journal :: proc(d: ^Damage, allocator: runtime.Allocator = context.allocator) -> Damage_Journal

// damage_journal_destroy frees the journal.
damage_journal_destroy :: proc(j: ^Damage_Journal, allocator: runtime.Allocator = context.allocator)

// damage_clear clears all damage without returning a journal.
damage_clear :: proc(d: ^Damage)
```

### File: `src/terminal/scroll.odin`

```odin
package terminal

// scroll_up scrolls the grid up by n rows within the specified region.
// Returns the number of rows actually scrolled.
scroll_up :: proc(g: ^Grid, d: ^Damage, top, bottom, n: int) -> int

// scroll_down scrolls the grid down by n rows within the specified region.
// Returns the number of rows actually scrolled.
scroll_down :: proc(g: ^Grid, d: ^Damage, top, bottom, n: int) -> int

// _scroll_region scrolls a specific region of the grid.
// This is the core implementation used by scroll_up and scroll_down.
_scroll_region :: proc(g: ^Grid, top, bottom, n: int) -> int
```

### File: `src/terminal/cursor.odin`

```odin
package terminal

// Cursor represents the cursor position and state.
Cursor :: struct {
    row:      int,
    col:      int,
    visible:  bool,
}

// cursor_init initializes the cursor at position (0, 0).
cursor_init :: proc(c: ^Cursor)

// cursor_move moves the cursor to the specified position.
// Clamps to grid bounds.
cursor_move :: proc(c: ^Cursor, row, col, row_count, col_count: int)

// cursor_advance advances the cursor after writing a character.
// Handles wrapping and scrolling.
cursor_advance :: proc(c: ^Cursor, width: int, row_count, col_count: int, scroll_needed: ^bool)
```

### File: `src/terminal/terminal.odin`

```odin
package terminal

// Terminal is the top-level terminal emulator state.
Terminal :: struct {
    grid:          Grid,
    cursor:        Cursor,
    current_style: Style_Id,
    damage:        Damage,
}

// Erase_Mode specifies how to erase content.
Erase_Mode :: enum {
    .To_End,        // erase from cursor to end
    .To_Beginning,  // erase from beginning to cursor
    .Entire,        // erase entire line/display
}

// terminal_init initializes a terminal with the specified dimensions.
terminal_init :: proc(t: ^Terminal, rows, cols: int, allocator: runtime.Allocator = context.allocator)

// terminal_destroy frees all terminal state.
terminal_destroy :: proc(t: ^Terminal, allocator: runtime.Allocator = context.allocator)

// terminal_put_char writes a character at the cursor position and advances the cursor.
terminal_put_char :: proc(t: ^Terminal, c: rune)

// terminal_put_string writes a string at the cursor position.
terminal_put_string :: proc(t: ^Terminal, s: string)

// terminal_move_cursor moves the cursor to the specified position.
terminal_move_cursor :: proc(t: ^Terminal, row, col: int)

// terminal_cursor_up moves the cursor up by n rows.
terminal_cursor_up :: proc(t: ^Terminal, n: int)

// terminal_cursor_down moves the cursor down by n rows.
terminal_cursor_down :: proc(t: ^Terminal, n: int)

// terminal_cursor_left moves the cursor left by n columns.
terminal_cursor_left :: proc(t: ^Terminal, n: int)

// terminal_cursor_right moves the cursor right by n columns.
terminal_cursor_right :: proc(t: ^Terminal, n: int)

// terminal_erase_line erases content on the current line.
terminal_erase_line :: proc(t: ^Terminal, mode: Erase_Mode)

// terminal_erase_display erases content on the display.
terminal_erase_display :: proc(t: ^Terminal, mode: Erase_Mode)

// terminal_scroll_up scrolls the terminal up by n rows.
terminal_scroll_up :: proc(t: ^Terminal, n: int)

// terminal_scroll_down scrolls the terminal down by n rows.
terminal_scroll_down :: proc(t: ^Terminal, n: int)

// terminal_newline moves the cursor to the beginning of the next line, scrolling if needed.
terminal_newline :: proc(t: ^Terminal)

// terminal_set_style sets the current style for subsequent character output.
terminal_set_style :: proc(t: ^Terminal, style: Style_Id)

// terminal_get_style returns the current style.
terminal_get_style :: proc(t: ^Terminal) -> Style_Id

// terminal_get_cell retrieves a cell at the specified position.
terminal_get_cell :: proc(t: ^Terminal, row, col: int) -> Semantic_Cell

// terminal_get_cursor returns the current cursor state.
terminal_get_cursor :: proc(t: ^Terminal) -> Cursor

// terminal_take_damage returns a damage journal and clears the damage.
terminal_take_damage :: proc(t: ^Terminal, allocator: runtime.Allocator = context.allocator) -> Damage_Journal

// terminal_clear_damage clears all damage without returning a journal.
terminal_clear_damage :: proc(t: ^Terminal)
```

---

## 4. Side-Effect Isolation

### Global State Mutations

**None.** All state is contained within the `Terminal` struct. No global variables.

### Side Effects by Operation

| Operation | Side Effect | Containment |
|-----------|-------------|-------------|
| `grid_set_cell` | Mutates `row.cells[col]`, increments `row.generation` | Confined to single row |
| `grid_scroll_up` | Mutates `grid.origin`, clears bottom rows | Confined to grid struct |
| `damage_mark_cell` | Mutates `dirty_rows[row]` | Confined to single dirty row |
| `damage_record_scroll` | Appends to `scroll_ops` array | Dynamic array, may allocate (rare) |
| `terminal_put_char` | Mutates grid, cursor, damage | Confined to terminal struct |

### Edge Cases Triggering Side Effects

1. **Span overflow in damage tracking**: When `span_count ≥ 4`, the dirty row is marked as `full = true` and spans are cleared. This is a degradation, not a failure.

2. **Style table full**: When the style table reaches capacity (1024 entries), `style_table_insert` returns 0 (default style). This is a silent fallback, not an error.

3. **Scroll ops array growth**: `scroll_ops` is a dynamic array and may allocate when appending. This is rare (scroll operations are infrequent compared to cell mutations).

### Allocation Points

All allocations occur during initialization:
- `grid_init`: allocates `rows` array and each row's `cells` array
- `damage_init`: allocates `dirty_rows` array
- `style_table_init`: no allocation (fixed-size array)

Steady-state operations (character output, cursor movement, scroll) perform zero allocations.

---

## 5. Implementation Order

### Phase 1A: Core Data Structures (Days 1-2)

1. **cell.odin** — `Semantic_Cell`, `Content_Handle`, `Cell_Flags`
   - Define cell struct and constants
   - No dependencies

2. **style.odin** — `Style`, `Style_Id`, `Style_Table`
   - Implement style table with deduplication
   - Test: insert, lookup, round-trip, capacity overflow

3. **row.odin** — `Row` with generation tracking
   - Implement row init/destroy/clear/set_cell
   - Test: generation increment, bounds checking

### Phase 1B: Grid and Ring Buffer (Days 3-4)

4. **grid.odin** — `Grid` with ring buffer
   - Implement grid init/destroy, cell access, ring buffer rotation
   - Test: physical/logical row mapping, scroll up/down, capacity rounding

5. **scroll.odin** — Scroll operations
   - Implement scroll_up, scroll_down with region support
   - Test: full scroll, partial scroll, clamp, empty region

### Phase 1C: Damage Tracking (Days 5-6)

6. **damage.odin** — Damage tracking system
   - Implement mark_cell, mark_span, mark_row, take_journal
   - Test: span coalescing, overflow to full row, journal consumption

### Phase 1D: Terminal API (Day 7)

7. **cursor.odin** — Cursor position and state
   - Implement cursor init/move/advance
   - Test: wrapping, clamping

8. **terminal.odin** — Top-level API
   - Integrate grid, cursor, damage, style
   - Test: put_char, put_string, scroll, erase

### Phase 1E: Testing and Benchmarking (Days 8-9)

9. **Unit tests** — All components
   - Grid, style, damage, cursor, terminal
   - Edge cases from MECE table

10. **Integration test** — "hello\nworld" scenario
    - Verify grid state, cursor position, damage journal

11. **Performance tests** — Using Phase 0 benchmark harness
    - Cell mutation: ns/cell
    - Scroll operation: ns/scroll
    - Damage tracking: ns/dirty_cell

---

## 6. Testing Strategy

### Unit Tests

**Grid Tests**:
- `test_grid_init`: verify capacity is power of 2, origin = 0
- `test_grid_set_get_cell`: verify cell read/write, generation increment
- `test_grid_scroll_up`: verify origin increment, row clearing
- `test_grid_scroll_down`: verify origin decrement, row clearing
- `test_grid_bounds`: verify out-of-bounds returns CELL_DEFAULT / false

**Style Table Tests**:
- `test_style_insert`: verify deduplication (same style → same ID)
- `test_style_get`: verify round-trip (insert then get)
- `test_style_capacity`: verify overflow returns default style

**Damage Tests**:
- `test_damage_mark_cell`: verify span added to dirty row
- `test_damage_mark_span`: verify span added, coalescing
- `test_damage_overflow`: verify span overflow → full row
- `test_damage_take_journal`: verify journal returned, damage cleared

**Cursor Tests**:
- `test_cursor_move`: verify clamping to bounds
- `test_cursor_advance`: verify wrapping, scrolling

**Terminal Tests**:
- `test_terminal_put_char`: verify cell written, cursor advanced
- `test_terminal_put_string`: verify multiple characters
- `test_terminal_scroll`: verify scroll operations
- `test_terminal_erase`: verify erase modes

### Integration Test

```odin
test_integration_hello_world :: proc() {
    t: Terminal
    terminal_init(&t, 24, 80)
    defer terminal_destroy(&t)
    
    terminal_put_string(&t, "hello\nworld")
    
    // Verify grid state
    assert(grid_get_cell(&t.grid, 0, 0).content == 'h')
    assert(grid_get_cell(&t.grid, 0, 1).content == 'e')
    assert(grid_get_cell(&t.grid, 0, 2).content == 'l')
    assert(grid_get_cell(&t.grid, 0, 3).content == 'l')
    assert(grid_get_cell(&t.grid, 0, 4).content == 'o')
    
    assert(grid_get_cell(&t.grid, 1, 0).content == 'w')
    assert(grid_get_cell(&t.grid, 1, 1).content == 'o')
    assert(grid_get_cell(&t.grid, 1, 2).content == 'r')
    assert(grid_get_cell(&t.grid, 1, 3).content == 'l')
    assert(grid_get_cell(&t.grid, 1, 4).content == 'd')
    
    // Verify cursor position
    cursor := terminal_get_cursor(&t)
    assert(cursor.row == 1)
    assert(cursor.col == 5)
    
    // Verify damage
    journal := terminal_take_damage(&t)
    defer damage_journal_destroy(&journal)
    
    assert(journal.dirty_rows[0].full == true)
    assert(journal.dirty_rows[1].full == true)
}
```

### Performance Tests

Using Phase 0 benchmark harness:

```odin
bench_cell_mutation :: proc(ctx: ^Benchmark_Context) {
    t: Terminal
    terminal_init(&t, 24, 80)
    defer terminal_destroy(&t)
    
    for i in 0..<1000 {
        terminal_put_char(&t, 'a')
    }
}

bench_scroll :: proc(ctx: ^Benchmark_Context) {
    t: Terminal
    terminal_init(&t, 24, 80)
    defer terminal_destroy(&t)
    
    for _ in 0..<100 {
        terminal_scroll_up(&t, 1)
    }
}

bench_damage_tracking :: proc(ctx: ^Benchmark_Context) {
    t: Terminal
    terminal_init(&t, 24, 80)
    defer terminal_destroy(&t)
    
    for i in 0..<1000 {
        terminal_put_char(&t, 'a')
    }
    
    journal := terminal_take_damage(&t)
    damage_journal_destroy(&journal)
}
```

**Performance Targets**:
- Cell mutation: < 10 ns/cell
- Scroll operation: < 50 ns/scroll
- Damage tracking: < 5 ns/dirty_cell

---

## 7. Acceptance Criteria

### Functional

1. ✅ Grid initialization with power-of-2 capacity
2. ✅ O(1) cell mutation with damage tracking
3. ✅ O(1) scroll via ring buffer rotation
4. ✅ Style table deduplication
5. ✅ Hierarchical damage tracking (cell → span → row)
6. ✅ Damage journal consumption
7. ✅ Cursor movement with wrapping and scrolling
8. ✅ Erase operations (line, display)
9. ✅ Zero allocations in steady state

### Performance

1. ✅ Cell mutation: < 10 ns/cell
2. ✅ Scroll operation: < 50 ns/scroll
3. ✅ Damage tracking: < 5 ns/dirty_cell

### Code Quality

1. ✅ All public APIs documented
2. ✅ All edge cases handled (MECE table)
3. ✅ Unit tests for all components
4. ✅ Integration test passes
5. ✅ Performance tests meet targets

---

## 8. Risk Mitigation

### Risk 1: Ring Buffer Complexity

**Risk**: Off-by-one errors in logical/physical row mapping.

**Mitigation**:
- Extensive unit tests for scroll operations
- Helper function `_grid_physical_row` with inline annotation
- Debug assertions in development builds

### Risk 2: Damage Tracking Overflow

**Risk**: Span overflow (>4 spans per row) degrades to full row, losing precision.

**Mitigation**:
- Monitor span overflow frequency in benchmarks
- If overflow is common, increase span array size from 4 to 8
- Document degradation behavior in API docs

### Risk 3: Style Table Capacity

**Risk**: Style table reaches capacity (1024 entries), falls back to default style.

**Mitigation**:
- Monitor style table usage in benchmarks
- If capacity is reached, increase to 2048 or 4096
- Document fallback behavior in API docs

### Risk 4: Memory Usage

**Risk**: Pre-allocating all data structures uses too much memory.

**Mitigation**:
- Profile memory usage in benchmarks
- Optimize cell size (target: ≤ 16 bytes)
- Consider lazy initialization for large grids

---

## 9. Future Work (Phase 2+)

**Phase 2**: Parser integration
- VT100/ANSI escape sequence parser
- Connect parser output to terminal API

**Phase 3**: GPU renderer
- Consume damage journals
- Render dirty regions only
- Optimize scroll operations (texture shift)

**Phase 4**: Advanced features
- Grapheme cluster support (Content_Handle → grapheme table)
- Alternate screen buffer
- Scrollback history
- Selection and copy/paste

---

## 10. Conclusion

This plan provides a complete, unambiguous specification for Phase 1 implementation. All data structures, APIs, edge cases, and performance targets are defined. The implementer can execute this plan without guessing or making architectural decisions.

**Key Success Factors**:
1. Strict adherence to ring buffer invariants (no row movement)
2. Damage tracking at mutation time (not comparison)
3. Zero allocations in steady state
4. Comprehensive testing (unit, integration, performance)

**Next Step**: Implementer executes Phase 1A (cell.odin, style.odin, row.odin).

package render

import "core:math"
import instance "instance"
import termgrid "../terminal"

// Packed 64-bit render cell for GPU upload.
// Layout (64 bits total):
//   [0..23]  codepoint  (24 bits, up to 16M codepoints)
//   [24..39] fg_color   (16 bits: R5G6B5 packed)
//   [40..55] bg_color   (16 bits: R5G6B5 packed)
//   [56..63] flags      (8 bits: style flags + width)
//
// This packing fits in a single u64, enabling efficient GPU buffer uploads
// and cache-friendly iteration over cell arrays.
//
// NOTE (deprecated-in-place): the V1 Render_Cell layout below is superseded
// by the Render_Cell_V2 benchmark layout further down this file. V1 is kept
// functional for the existing renderer_frame path; new code must use V2.

// Render_Cell is a packed 64-bit representation of a terminal cell for rendering.
Render_Cell :: u64

// Bit field positions and masks
_CELL_CODEPOINT_SHIFT :: 0
_CELL_CODEPOINT_MASK  :: 0x00FFFFFF // 24 bits

_CELL_FG_SHIFT  :: 24
_CELL_FG_MASK   :: 0xFFFF000000 // 16 bits

_CELL_BG_SHIFT  :: 40
_CELL_BG_MASK   :: 0xFFFF0000000000 // 16 bits

_CELL_FLAGS_SHIFT :: 56
_CELL_FLAGS_MASK  :: 0xFF00000000000000 // 8 bits

// Render_Cell_Flags encodes style flags and character width in 8 bits.
// [0..3] width (1-16)
// [4]    bold
// [5]    italic
// [6]    underline
// [7]    reserved
Render_Cell_Flags :: u8

// render_cell_pack packs a codepoint, fg/bg colors (R5G6B5), and flags into a Render_Cell.
render_cell_pack :: proc(codepoint: u32, fg, bg: u16, flags: Render_Cell_Flags) -> Render_Cell {
	cp := u64(codepoint & u32(_CELL_CODEPOINT_MASK))
	f := u64(fg & u16(_CELL_FG_MASK >> _CELL_FG_SHIFT)) << _CELL_FG_SHIFT
	b := u64(bg & u16(_CELL_BG_MASK >> _CELL_BG_SHIFT)) << _CELL_BG_SHIFT
	fl := u64(flags) << _CELL_FLAGS_SHIFT
	return Render_Cell(cp | f | b | fl)
}

// render_cell_unpack extracts codepoint, fg, bg, and flags from a Render_Cell.
render_cell_unpack :: proc(cell: Render_Cell) -> (codepoint: u32, fg, bg: u16, flags: Render_Cell_Flags) {
	codepoint = u32(u64(cell) & _CELL_CODEPOINT_MASK) >> _CELL_CODEPOINT_SHIFT
	fg = u16((u64(cell) & _CELL_FG_MASK) >> _CELL_FG_SHIFT)
	bg = u16((u64(cell) & _CELL_BG_MASK) >> _CELL_BG_SHIFT)
	flags = Render_Cell_Flags((u64(cell) & _CELL_FLAGS_MASK) >> _CELL_FLAGS_SHIFT)
	return
}

// render_cell_empty returns the default empty render cell (space, white on black).
render_cell_empty :: proc() -> Render_Cell {
	return render_cell_pack(0x20, 0xFFFF, 0x0000, Render_Cell_Flags(1))
}

// color_to_r5g6b5 converts an 8-bit ARGB color to packed R5G6B5 (16 bits).
color_to_r5g6b5 :: proc(argb: u32) -> u16 {
	r := u16((argb >> 16) & 0xFF) >> 3 // 8 bits -> 5 bits
	g := u16((argb >> 8) & 0xFF) >> 2  // 8 bits -> 6 bits
	b := u16(argb & 0xFF) >> 3         // 8 bits -> 5 bits
	return (r << 11) | (g << 5) | b
}

// r5g6b5_to_rgba unpacks R5G6B5 to u32 RGBA (8 bits per channel).
r5g6b5_to_rgba :: proc(packed: u16) -> u32 {
	r := u32((packed >> 11) & 0x1F)
	g := u32((packed >> 5) & 0x3F)
	b := u32(packed & 0x1F)
	// Expand to 8 bits
	r8 := (r << 3) | (r >> 2)
	g8 := (g << 2) | (g >> 4)
	b8 := (b << 3) | (b >> 2)
	return (r8 << 24) | (g8 << 16) | (b8 << 8) | 0xFF
}

// ============================================================================
// Render_Cell_V2: packed GPU cell value benchmark layout (candidate, NOT permanent API).
//
// Hot path produces this value directly from Semantic_Cell. Layout is a
// benchmarked choice:
//   [0..20]  codepoint  (21 bits)
//   [21..30] style_id   (10 bits, capacity 1024)
//   [31..32] width      (2 bits: 0=continuation, 1=narrow, 2=wide-lead; 3 normalizes to 1)
//   [33..39] cflags     (7 bits: bit0 wide_cont, bit1 zero-width, bits2-6 reserved=0)
//   [40..48] glyph_slot (9 bits, 0x1FF=UNRESOLVED)
//   [49..63] reserved=0
// ============================================================================

// Render_Cell_V2 is a packed 64-bit GPU cell value (style pre-resolved via Style_LUT).
Render_Cell_V2 :: u64

RENDER_CELL_V2_CODEPOINT_BITS :: 21
RENDER_CELL_V2_STYLE_BITS     :: 10
RENDER_CELL_V2_CODEPOINT_MASK :: u64(0x1FFFFF)
RENDER_CELL_V2_STYLE_MASK     :: u64(0x3FF)
RENDER_CELL_V2_WIDTH_SHIFT    :: u64(31)
RENDER_CELL_V2_CFLAGS_SHIFT   :: u64(33)
RENDER_CELL_V2_SLOT_SHIFT     :: u64(40)

RENDER_CELL_V2_SLOT_UNRESOLVED :: u16(0x1FF)

RENDER_CELL_V2_WIDTH_CONTINUATION :: u8(0)
RENDER_CELL_V2_WIDTH_NARROW       :: u8(1)
RENDER_CELL_V2_WIDTH_WIDE_LEAD    :: u8(2)

RENDER_CELL_V2_CFLAG_WIDE_CONT :: u8(1 << 0)
RENDER_CELL_V2_CFLAG_SELECTED  :: u8(1 << 1)
RENDER_CELL_V2_CFLAG_EMOJI     :: u8(1 << 2) // cell contains color emoji (route to emoji atlas)

// _RENDER_CELL_V2_STYLE_SHIFT is the bit position of the style_id field (== codepoint width).
_RENDER_CELL_V2_STYLE_SHIFT :: u64(RENDER_CELL_V2_CODEPOINT_BITS)
// _RENDER_CELL_V2_WIDTH_MASK masks the 2-bit width field.
_RENDER_CELL_V2_WIDTH_MASK :: u64(0x3)
// _RENDER_CELL_V2_CFLAGS_MASK masks the 7-bit cflags field.
_RENDER_CELL_V2_CFLAGS_MASK :: u64(0x7F)
// _RENDER_CELL_V2_SLOT_MASK masks the 9-bit glyph slot field.
_RENDER_CELL_V2_SLOT_MASK :: u64(0x1FF)

// Render_Cell_P48 is a packed 6-byte candidate layout: codepoint + style +
// packed (u16: [0..1]width, [2..8]cflags, [9..15]reserved).
Render_Cell_P48 :: struct {
	codepoint: u32,
	style:     u16,
	packed:    u16,
}

// Render_Cell_P96 is a 12-byte candidate layout: full V2 value + explicit slot.
Render_Cell_P96 :: struct {
	v2:   Render_Cell_V2,
	slot: u32,
}

// Render_Cells_SoA is a struct-of-arrays candidate layout.
// styles_flags packs: [0..9]style, [10..11]width, [12..18]cflags, [19..27]slot, [28..31]reserved.
Render_Cells_SoA :: struct {
	codepoints:   []u32,
	styles_flags: []u32,
}

// Style_LUT pre-resolves Style_Table colors to R5G6B5 fg/bg (1024 entries, no alloc on rebuild).
Style_LUT :: struct {
	fg_r5g6b5: [1024]u16,
	bg_r5g6b5: [1024]u16,
	selection_fg_r5g6b5: u16,
	selection_bg_r5g6b5: u16,
	count:     u16,
}

// render_cell_pack_v2 packs content/style/width/cflags/glyph_slot into a Render_Cell_V2.
// Pure: no style table access, no color conversion.
// Cracks: CodepointOverflow (truncate 21b), StyleOverflow (mask 10b),
// SlotOverflow (>=512 → UNRESOLVED), FlagsReserved (masked), WidthReserved (3 → 1).
render_cell_pack_v2 :: proc(content: u32, style: u16, width: u8, cflags: u8, glyph_slot: u16) -> Render_Cell_V2 {
	cp := u64(content) & RENDER_CELL_V2_CODEPOINT_MASK
	st := u64(style) & RENDER_CELL_V2_STYLE_MASK
	w := u64(width) & _RENDER_CELL_V2_WIDTH_MASK
	if w == 3 {
		w = 1
	}
	cf := u64(cflags) & _RENDER_CELL_V2_CFLAGS_MASK
	sl := u64(glyph_slot) & _RENDER_CELL_V2_SLOT_MASK
	if glyph_slot >= 512 {
		sl = u64(RENDER_CELL_V2_SLOT_UNRESOLVED)
	}
	return Render_Cell_V2(cp | (st << _RENDER_CELL_V2_STYLE_SHIFT) | (w << RENDER_CELL_V2_WIDTH_SHIFT) | (cf << RENDER_CELL_V2_CFLAGS_SHIFT) | (sl << RENDER_CELL_V2_SLOT_SHIFT))
}

// render_cell_unpack_v2 extracts content/style/width/cflags/glyph_slot from a Render_Cell_V2. Pure.
render_cell_unpack_v2 :: proc(cell: Render_Cell_V2) -> (content: u32, style: u16, width: u8, cflags: u8, glyph_slot: u16) {
	v := u64(cell)
	content = u32(v & RENDER_CELL_V2_CODEPOINT_MASK)
	style = u16((v >> _RENDER_CELL_V2_STYLE_SHIFT) & RENDER_CELL_V2_STYLE_MASK)
	width = u8((v >> RENDER_CELL_V2_WIDTH_SHIFT) & _RENDER_CELL_V2_WIDTH_MASK)
	cflags = u8((v >> RENDER_CELL_V2_CFLAGS_SHIFT) & _RENDER_CELL_V2_CFLAGS_MASK)
	glyph_slot = u16((v >> RENDER_CELL_V2_SLOT_SHIFT) & _RENDER_CELL_V2_SLOT_MASK)
	return
}

// render_cell_from_semantic packs a Semantic_Cell directly into a Render_Cell_V2.
// Pure: NO style_table_get, NO color conversion; slot is always UNRESOLVED.
render_cell_from_semantic :: proc(cell: termgrid.Semantic_Cell, selected: bool = false) -> Render_Cell_V2 {
	w := RENDER_CELL_V2_WIDTH_NARROW
	cf := u8(0)
	if u8(cell.flags) & u8(termgrid.Cell_Flags.Wide_Continuation) != 0 {
		w = RENDER_CELL_V2_WIDTH_CONTINUATION
		cf = RENDER_CELL_V2_CFLAG_WIDE_CONT
	} else if cell.width == 2 {
		w = RENDER_CELL_V2_WIDTH_WIDE_LEAD
	}
	if termgrid.is_emoji_codepoint(rune(cell.content)) {
		cf |= RENDER_CELL_V2_CFLAG_EMOJI
	}
	if selected {
		cf |= RENDER_CELL_V2_CFLAG_SELECTED
	}
	return render_cell_pack_v2(cell.content, u16(cell.style), w, cf, RENDER_CELL_V2_SLOT_UNRESOLVED)
}

// render_cell_empty_v2 returns the default empty V2 cell (space, style 0, narrow).
render_cell_empty_v2 :: proc() -> Render_Cell_V2 {
	return render_cell_pack_v2(0x20, 0, RENDER_CELL_V2_WIDTH_NARROW, 0, RENDER_CELL_V2_SLOT_UNRESOLVED)
}

// _style_lut_dim_argb scales an ARGB color's RGB channels for DIM (SGR 2).
// Matches the standard half-intensity dim used for fish autosuggestions.
_style_lut_dim_argb :: proc(argb: u32) -> u32 {
	r := (argb >> 16) & 0xFF
	g := (argb >> 8) & 0xFF
	b := argb & 0xFF
	return (argb & 0xFF000000) | ((r / 2) << 16) | ((g / 2) << 8) | (b / 2)
}

// style_lut_rebuild pre-resolves every Style_Table entry to R5G6B5 fg/bg.
// DIM-flagged styles resolve to half-intensity foreground (SGR 2, used by
// fish autosuggestions). 1024-entry struct rewrite, no allocation.
style_lut_rebuild :: proc(lut: ^Style_LUT, table: ^termgrid.Style_Table) {
	if lut == nil || table == nil {
		return
	}
	count := int(table.count)
	if count > 1024 {
		count = 1024
	}
	default_style := termgrid.style_table_default(table)
	for i in 0..<1024 {
		style := default_style
		if i < count {
			style = table.entries[i]
		}
		fg := style.fg
		if style.flags & termgrid.STYLE_FLAG_DIM != 0 {
			fg = _style_lut_dim_argb(fg)
		}
		lut.fg_r5g6b5[i] = color_to_r5g6b5(fg)
		lut.bg_r5g6b5[i] = color_to_r5g6b5(style.bg)
	}
	lut.selection_fg_r5g6b5 = color_to_r5g6b5(table.theme.selection_foreground)
	lut.selection_bg_r5g6b5 = color_to_r5g6b5(table.theme.selection_background)
	lut.count = u16(count)
}

// render_cell_expand_instance expands one packed V2 cell into bg/glyph instances.
// Owns the empty + continuation skip rules. Atlas is read read-only.
// MUST NOT call style_table_get or color_to_r5g6b5 (colors come pre-resolved from lut).
// Cracks: StyleIdStale (lut index out of range → entry 0),
// GlyphSlotInvalid (invalid slot → skip glyph, keep bg),
// ContinuationLeak (continuation cell → emits nothing, never indexes col-1).
render_cell_expand_instance :: proc(
	cell: Render_Cell_V2,
	lut: ^Style_LUT,
	atlas: ^Atlas,
	x, y, cell_w, cell_h: f32,
	bg_out: ^instance.Instance_Data,
	glyph_out: ^instance.Instance_Data,
	emoji_out: ^instance.Instance_Data = nil,
	emoji_atlas_ptr: ^Emoji_Atlas = nil,
	store: ^termgrid.Grapheme_Store = nil,
) -> (emit_bg: bool, emit_glyph: bool, emit_emoji: bool) {
	content, style, width, cflags, slot := render_cell_unpack_v2(cell)

	// Continuation cells emit nothing.
	if width == RENDER_CELL_V2_WIDTH_CONTINUATION {
		return false, false, false
	}

	// LUT lookup with bounds fallback to entry 0.
	lut_idx := 0
	if int(style) < int(lut.count) && int(style) < 1024 {
		lut_idx = int(style)
	}
	fg := lut.fg_r5g6b5[lut_idx]
	bg := lut.bg_r5g6b5[lut_idx]
	if cflags & RENDER_CELL_V2_CFLAG_SELECTED != 0 {
		fg = lut.selection_fg_r5g6b5
		bg = lut.selection_bg_r5g6b5
	}

	// Empty skip: space or NUL with default/black bg emits nothing.
	if (content == 0x20 || content == 0) && (bg == 0x0000 || bg == lut.bg_r5g6b5[0]) {
		return false, false, false
	}

	// Background instance. Wide leads span double width.
	if bg_out != nil {
		bg_r, bg_g, bg_b := instance.unpack_r5g6b5(bg)
		bg_cw := cell_w
		if width == RENDER_CELL_V2_WIDTH_WIDE_LEAD {
			bg_cw = cell_w * 2.0
		}
		bg_out^ = instance.Instance_Data{
			x = x, y = y,
			cw = bg_cw, ch = cell_h,
			u0 = 0, v0 = 0, u1 = 0, v1 = 0,
			r = bg_r, g = bg_g, b = bg_b, a = 1.0,
		}
	}
	emit_bg = true

	// Spaces and NUL emit no glyph.
	if content == 0x20 || content == 0 {
		return true, false, false
	}

	is_emoji := cflags & RENDER_CELL_V2_CFLAG_EMOJI != 0
	if is_emoji && emoji_out != nil && emoji_atlas_ptr != nil {
		when ODIN_OS == .Darwin {
			key := u64(content)
			emoji_info, found := emoji_atlas_ptr.glyphs[key]
			if !found {
				ok: bool
				if termgrid.content_is_grapheme(termgrid.Content_Handle(content)) {
					buf: [64]u8
					str := termgrid.grapheme_to_utf8(termgrid.Content_Handle(content), store, buf[:])
					emoji_info, ok = emoji_atlas_get_cluster(emoji_atlas_ptr, str)
				} else {
					emoji_info, ok = emoji_atlas_get_glyph(emoji_atlas_ptr, rune(content))
				}
				if ok {
					emoji_atlas_ptr.glyphs[key] = emoji_info
					found = true
				}
			}
			if found {
				gw := emoji_info.size[0]
				gh := emoji_info.size[1]
				total_w := width == RENDER_CELL_V2_WIDTH_WIDE_LEAD ? cell_w * 2.0 : cell_w
				scale := min(total_w / gw, cell_h / gh, 1.0)
				draw_w := gw * scale
				draw_h := gh * scale
				offset_x := math.floor((total_w - draw_w) * 0.5 + 0.5)
				offset_y := math.floor((cell_h - draw_h) * 0.5 + 0.5)
				emoji_out^ = instance.Instance_Data{
					x = x + offset_x,
					y = y + offset_y,
					cw = draw_w,
					ch = draw_h,
					u0 = emoji_info.uv[0],
					v0 = emoji_info.uv[1],
					u1 = emoji_info.uv[2],
					v1 = emoji_info.uv[3],
					r = 1.0, g = 1.0, b = 1.0, a = 1.0,
				}
				return true, false, true
			}
		}
		return true, false, false
	}

	// Resolve the glyph slot: pinned slot when unresolved, stored slot otherwise.
	slot_entry: ^Atlas_Slot = nil
	if slot == RENDER_CELL_V2_SLOT_UNRESOLVED {
		_, slot_entry = atlas_get_slot(atlas, content)
	} else if int(slot) < ATLAS_SLOT_COUNT {
		slot_entry = &atlas.slots[slot]
	} else {
		_, slot_entry = atlas_get_slot(atlas, content)
	}
	if slot_entry == nil || !slot_entry.valid {
		// Dynamic fallback branch (slow path only): a legacy UNRESOLVED
		// pack for non-ASCII content may already live in a dynamic slot
		// claimed by an earlier shaped compile. ASCII never reaches here
		// with an invalid slot, so the pinned flow is unchanged.
		if content >= 0x80 {
			for i in 0..<FALLBACK_SLOT_COUNT {
				tag := atlas.fallback_tag[i]
				if tag == 0 || u32(tag & 0xFFFFFFFF) != content {
					continue
				}
				dyn := FALLBACK_SLOT_BASE + i
				if dyn < ATLAS_SLOT_COUNT && atlas.slots[dyn].valid {
					slot_entry = &atlas.slots[dyn]
					break
				}
			}
		}
	}
	if slot_entry == nil || !slot_entry.valid {
		// GlyphSlotInvalid → skip glyph, keep bg.
		return true, false, false
	}

	// Glyph instance (wide leads span double width).
	if glyph_out != nil {
		fg_r, fg_g, fg_b := instance.unpack_r5g6b5(fg)
		gw := cell_w
		if width == RENDER_CELL_V2_WIDTH_WIDE_LEAD {
			gw = cell_w * 2.0
		}
		glyph_out^ = instance.Instance_Data{
			x = x, y = y,
			cw = gw, ch = cell_h,
			u0 = slot_entry.u0, v0 = slot_entry.v0,
			u1 = slot_entry.u1, v1 = slot_entry.v1,
			r = fg_r, g = fg_g, b = fg_b, a = 1.0,
		}
	}
	return true, true, false
}

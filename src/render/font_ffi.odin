package render

import "core:c"

when ODIN_OS == .Darwin {
	foreign import libfreetype "system:freetype"
	foreign import libharfbuzz "system:harfbuzz"
} else when ODIN_OS == .Linux {
	foreign import libfreetype "system:freetype"
	foreign import libharfbuzz "system:harfbuzz"
} else when ODIN_OS == .Windows {
	foreign import libfreetype "system:freetype"
	foreign import libharfbuzz "system:harfbuzz"
}

// -------------------------------------------------------------------------
// FreeType 2 Types and Structures
// -------------------------------------------------------------------------

FT_Library    :: distinct rawptr
FT_Face       :: ^FT_FaceRec
FT_Size       :: ^FT_SizeRec
FT_GlyphSlot  :: ^FT_GlyphSlotRec

FT_Pos        :: c.long
FT_Fixed      :: c.long
FT_F26Dot6    :: c.long
FT_Error      :: c.int
FT_Long       :: c.long
FT_ULong      :: c.ulong
FT_Int        :: c.int
FT_UInt       :: c.uint
FT_Short      :: c.short
FT_UShort     :: c.ushort
FT_String     :: c.char

FT_Vector :: struct {
	x: FT_Pos,
	y: FT_Pos,
}

FT_BBox :: struct {
	xMin, yMin: FT_Pos,
	xMax, yMax: FT_Pos,
}

FT_Generic_Finalizer :: #type proc "c" (object: rawptr)
FT_Generic :: struct {
	data:      rawptr,
	finalizer: FT_Generic_Finalizer,
}

FT_Glyph_Metrics :: struct {
	width:        FT_Pos,
	height:       FT_Pos,
	horiBearingX: FT_Pos,
	horiBearingY: FT_Pos,
	horiAdvance:  FT_Pos,
	vertBearingX: FT_Pos,
	vertBearingY: FT_Pos,
	vertAdvance:  FT_Pos,
}

FT_Bitmap :: struct {
	rows:         c.uint,
	width:        c.uint,
	pitch:        c.int,
	_pad0:        u32,
	buffer:       [^]u8,
	num_grays:    c.ushort,
	pixel_mode:   u8,
	palette_mode: u8,
	_pad1:        u32,
	palette:      rawptr,
}

FT_Outline :: struct {
	n_contours: c.short,
	n_points:   c.short,
	points:     [^]FT_Vector,
	tags:       [^]u8,
	contours:   [^]c.short,
	flags:      c.int,
}

FT_GlyphSlotRec :: struct {
	library:           FT_Library,
	face:              FT_Face,
	next:              FT_GlyphSlot,
	glyph_index:       FT_UInt,
	_pad0:             u32,
	generic:           FT_Generic,
	metrics:           FT_Glyph_Metrics,
	linearHoriAdvance: FT_Fixed,
	linearVertAdvance: FT_Fixed,
	advance:           FT_Vector,
	format:            u32,
	_pad1:             u32,
	bitmap:            FT_Bitmap,
	bitmap_left:       FT_Int,
	bitmap_top:        FT_Int,
	outline:           FT_Outline,
	num_subglyphs:     FT_UInt,
	subglyphs:         rawptr,
	control_data:      rawptr,
	control_len:       c.long,
	lsb_delta:         FT_Pos,
	rsb_delta:         FT_Pos,
	other:             rawptr,
	internal:          rawptr,
}

FT_Size_Metrics :: struct {
	x_ppem:      c.ushort,
	y_ppem:      c.ushort,
	_pad0:       u32,
	x_scale:     FT_Fixed,
	y_scale:     FT_Fixed,
	ascender:    FT_Pos,
	descender:   FT_Pos,
	height:      FT_Pos,
	max_advance: FT_Pos,
}

FT_SizeRec :: struct {
	face:     FT_Face,
	generic:  FT_Generic,
	metrics:  FT_Size_Metrics,
	internal: rawptr,
}

FT_FaceRec :: struct {
	num_faces:           FT_Long,
	face_index:          FT_Long,
	face_flags:          FT_Long,
	style_flags:         FT_Long,
	num_glyphs:          FT_Long,
	family_name:         cstring,
	style_name:          cstring,
	num_fixed_sizes:     FT_Int,
	available_sizes:     rawptr,
	num_charmaps:        FT_Int,
	charmaps:            rawptr,
	generic:             FT_Generic,
	bbox:                FT_BBox,
	units_per_EM:        c.ushort,
	ascender:            c.short,
	descender:           c.short,
	height:              c.short,
	max_advance_width:   c.short,
	max_advance_height:  c.short,
	underline_position:  c.short,
	underline_thickness: c.short,
	glyph:               FT_GlyphSlot,
	size:                FT_Size,
	charmap:             rawptr,
}

// FreeType Constants
FT_LOAD_DEFAULT                     :: 0x0000
FT_LOAD_NO_SCALE                    :: 1 << 0
FT_LOAD_NO_HINTING                  :: 1 << 1
FT_LOAD_RENDER                      :: 1 << 2
FT_LOAD_NO_BITMAP                   :: 1 << 3
FT_LOAD_VERTICAL_LAYOUT             :: 1 << 4
FT_LOAD_FORCE_AUTOHINT              :: 1 << 5
FT_LOAD_CROP_BITMAP                 :: 1 << 6
FT_LOAD_PEDANTIC                    :: 1 << 7
FT_LOAD_IGNORE_GLOBAL_ADVANCE_WIDTH :: 1 << 9
FT_LOAD_NO_RECURSE                  :: 1 << 10
FT_LOAD_IGNORE_TRANSFORM            :: 1 << 11
FT_LOAD_MONOCHROME                  :: 1 << 12
FT_LOAD_LINEAR_DESIGN               :: 1 << 13
FT_LOAD_NO_AUTOHINT                 :: 1 << 15
FT_LOAD_COLOR                       :: 1 << 20
FT_LOAD_COMPUTE_METRICS             :: 1 << 21
FT_LOAD_BITMAP_METRICS_ONLY         :: 1 << 22

FT_LOAD_TARGET_NORMAL               :: 0 << 16
FT_LOAD_TARGET_LIGHT                :: 1 << 16
FT_LOAD_TARGET_MONO                 :: 2 << 16
FT_LOAD_TARGET_LCD                  :: 3 << 16
FT_LOAD_TARGET_LCD_V                :: 4 << 16

FT_Render_Mode :: enum c.int {
	NORMAL = 0,
	LIGHT  = 1,
	MONO   = 2,
	LCD    = 3,
	LCD_V  = 4,
	MAX,
}

FT_Pixel_Mode :: enum u8 {
	NONE = 0,
	MONO,
	GRAY,
	GRAY2,
	GRAY4,
	LCD,
	LCD_V,
	BGRA,
}

// -------------------------------------------------------------------------
// FreeType 2 C API
// -------------------------------------------------------------------------

@(default_calling_convention="c")
foreign libfreetype {
	FT_Init_FreeType   :: proc(alibrary: ^FT_Library) -> FT_Error ---
	FT_Done_FreeType   :: proc(library: FT_Library) -> FT_Error ---
	FT_New_Memory_Face :: proc(library: FT_Library, file_base: [^]u8, file_size: FT_Long, face_index: FT_Long, aface: ^FT_Face) -> FT_Error ---
	FT_Done_Face       :: proc(face: FT_Face) -> FT_Error ---
	FT_Set_Pixel_Sizes :: proc(face: FT_Face, pixel_width: FT_UInt, pixel_height: FT_UInt) -> FT_Error ---
	FT_Set_Char_Size   :: proc(face: FT_Face, char_width: FT_F26Dot6, char_height: FT_F26Dot6, horz_resolution: FT_UInt, vert_resolution: FT_UInt) -> FT_Error ---
	FT_Load_Glyph      :: proc(face: FT_Face, glyph_index: FT_UInt, load_flags: i32) -> FT_Error ---
	FT_Load_Char       :: proc(face: FT_Face, char_code: FT_ULong, load_flags: i32) -> FT_Error ---
	FT_Render_Glyph    :: proc(slot: FT_GlyphSlot, render_mode: FT_Render_Mode) -> FT_Error ---
	FT_Get_Char_Index  :: proc(face: FT_Face, charcode: FT_ULong) -> FT_UInt ---
	FT_Select_Charmap  :: proc(face: FT_Face, encoding: u32) -> FT_Error ---
}

// -------------------------------------------------------------------------
// HarfBuzz Types and Structures
// -------------------------------------------------------------------------

hb_blob_t     :: distinct rawptr
hb_face_t     :: distinct rawptr
hb_font_t     :: distinct rawptr
hb_buffer_t   :: distinct rawptr
hb_language_t :: distinct rawptr
hb_script_t   :: distinct u32

hb_direction_t :: enum c.int {
	INVALID = 0,
	LTR     = 4,
	RTL     = 5,
	TTB     = 6,
	BTT     = 7,
}

hb_glyph_info_t :: struct {
	codepoint: u32, // shaped glyph ID
	mask:      u32,
	cluster:   u32,
	var1:      u32,
	var2:      u32,
}

hb_glyph_position_t :: struct {
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
	var:       u32,
}

hb_feature_t :: struct {
	tag:   u32,
	value: u32,
	start: c.uint,
	end:   c.uint,
}

// -------------------------------------------------------------------------
// HarfBuzz C API
// -------------------------------------------------------------------------

@(default_calling_convention="c")
foreign libharfbuzz {
	hb_buffer_create                   :: proc() -> hb_buffer_t ---
	hb_buffer_destroy                  :: proc(buffer: hb_buffer_t) ---
	hb_buffer_reset                    :: proc(buffer: hb_buffer_t) ---
	hb_buffer_add_utf8                 :: proc(buffer: hb_buffer_t, text: [^]u8, text_length: c.int, item_offset: c.uint, item_length: c.int) ---
	hb_buffer_add_codepoints           :: proc(buffer: hb_buffer_t, text: [^]u32, text_length: c.int, item_offset: c.uint, item_length: c.int) ---
	hb_buffer_set_direction            :: proc(buffer: hb_buffer_t, direction: hb_direction_t) ---
	hb_buffer_set_script               :: proc(buffer: hb_buffer_t, script: hb_script_t) ---
	hb_buffer_set_language             :: proc(buffer: hb_buffer_t, language: hb_language_t) ---
	hb_buffer_guess_segment_properties :: proc(buffer: hb_buffer_t) ---
	hb_buffer_get_length               :: proc(buffer: hb_buffer_t) -> c.uint ---
	hb_buffer_get_glyph_infos          :: proc(buffer: hb_buffer_t, length: ^c.uint) -> [^]hb_glyph_info_t ---
	hb_buffer_get_glyph_positions      :: proc(buffer: hb_buffer_t, length: ^c.uint) -> [^]hb_glyph_position_t ---

	hb_ft_font_create                  :: proc(ft_face: FT_Face, destroy: rawptr) -> hb_font_t ---
	hb_ft_font_create_referenced       :: proc(ft_face: FT_Face) -> hb_font_t ---
	hb_ft_font_changed                 :: proc(font: hb_font_t) ---
	hb_font_destroy                    :: proc(font: hb_font_t) ---
	hb_shape                           :: proc(font: hb_font_t, buffer: hb_buffer_t, features: [^]hb_feature_t, num_features: c.uint) ---
}

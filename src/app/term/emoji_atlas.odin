package term

// Color Emoji Atlas (RGBA8) for the modern terminal shell.
// Ported from legacy/src/render/emoji_atlas.odin and adapted to the
// contract GPU backend. FreeType delivers Apple Color Emoji bitmaps as BGRA;
// harness_helper.font_rasterize_color_glyph converts them to RGBA so they can
// be packed here and sampled by the emoji pipeline unchanged.

import "core:mem"
import "core:os"
import contract "../../core/render/contract"
import helper "../../cmd/harness_helper"

EMOJI_ATLAS_DIM :: 1024

EMOJI_FONT_CANDIDATES := []string{
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/Supplemental/Apple Color Emoji.ttc",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/usr/share/fonts/google-noto-color-emoji/NotoColorEmoji.ttf",
	"/usr/share/fonts/NotoColorEmoji.ttf",
	"assets/fonts/NotoColorEmoji.ttf",
}

Emoji_Glyph :: struct {
	u0, v0, u1, v1: f32,
	width:          f32,
	height:         f32,
}

Emoji_Atlas_Manager :: struct {
	face:        helper.Font_Rasterizer,
	has_font:    bool,
	pixels:      []u8, // RGBA8 (DIM * DIM * 4)
	cursor_x:    int,
	cursor_y:    int,
	row_height:  int,
	glyphs:      map[u64]Emoji_Glyph, // keyed by FNV1a hash of cluster runes
	gpu_texture: contract.Gpu_Texture,
	gpu_view:    contract.Gpu_TextureView,
	gpu_dirty:   bool,
}

emoji_atlas_init :: proc(ea: ^Emoji_Atlas_Manager, pixel_size: f32) -> bool {
	if ea == nil do return false
	ea.pixels = make([]u8, EMOJI_ATLAS_DIM * EMOJI_ATLAS_DIM * 4)
	if ea.pixels == nil do return false
	mem.zero_slice(ea.pixels)
	ea.glyphs = make(map[u64]Emoji_Glyph, 64)
	ea.cursor_x = 1
	ea.cursor_y = 1
	ea.row_height = 0
	ea.has_font = false

	for path in EMOJI_FONT_CANDIDATES {
		if os.is_file(path) {
			err: helper.Font_Error
			if helper.font_rasterizer_init(&ea.face, path, pixel_size, &err) {
				ea.has_font = true
				break
			}
		}
	}
	return true
}

emoji_atlas_destroy :: proc(ea: ^Emoji_Atlas_Manager) {
	if ea == nil do return
	if ea.has_font do helper.font_rasterizer_destroy(&ea.face)
	ea.has_font = false
	delete(ea.glyphs)
	if len(ea.pixels) > 0 {
		delete(ea.pixels)
		ea.pixels = nil
	}
	if rawptr(ea.gpu_view) != nil && contract.destroy_texture_view != nil {
		contract.destroy_texture_view(ea.gpu_view)
		ea.gpu_view = contract.Gpu_TextureView(nil)
	}
	if rawptr(ea.gpu_texture) != nil && contract.destroy_texture != nil {
		contract.destroy_texture(ea.gpu_texture)
		ea.gpu_texture = contract.Gpu_Texture(nil)
	}
}

emoji_atlas_has_codepoint :: proc(ea: ^Emoji_Atlas_Manager, cp: rune) -> bool {
	if ea == nil || !ea.has_font do return false
	return helper.font_rasterizer_find_glyph_index(&ea.face, u32(cp)) != 0
}

_cluster_hash :: proc(runes: []rune) -> u64 {
	hash: u64 = 14695981039346656037
	bytes := mem.slice_to_bytes(runes)
	for b in bytes {
		hash ~= u64(b)
		hash *= 1099511628211
	}
	return hash
}

// emoji_atlas_get rasterizes and packs a single color emoji codepoint.
emoji_atlas_get :: proc(ea: ^Emoji_Atlas_Manager, cp: rune) -> (Emoji_Glyph, bool) {
	runes := [1]rune{cp}
	return emoji_atlas_get_runes(ea, runes[:])
}

// emoji_atlas_get_runes shapes a grapheme cluster (ZWJ emoji, keycap, regional
// indicator pair, VS16) with HarfBuzz and packs the resulting color ligature
// into the atlas, keyed by an FNV1a hash of the cluster runes.
emoji_atlas_get_runes :: proc(ea: ^Emoji_Atlas_Manager, runes: []rune) -> (glyph: Emoji_Glyph, ok: bool) {
	if ea == nil || !ea.has_font || len(runes) == 0 do return {}, false
	key := _cluster_hash(runes)
	if g, found := ea.glyphs[key]; found do return g, true

	glyph_id: u32 = 0
	if shaped, shaped_ok := helper.font_shape_cluster(&ea.face, runes); shaped_ok && shaped.glyph_count > 0 {
		glyph_id = shaped.glyphs[0].glyph_id
	} else {
		glyph_id = helper.font_rasterizer_find_glyph_index(&ea.face, u32(runes[0]))
	}
	if glyph_id == 0 do return {}, false

	bmp := helper.font_rasterize_color_glyph_index(&ea.face, glyph_id)
	defer if bmp.pixels != nil do delete(bmp.pixels)
	if bmp.width <= 0 || bmp.height <= 0 || bmp.pixels == nil do return {}, false

	if ea.cursor_x + bmp.width + 1 > EMOJI_ATLAS_DIM {
		ea.cursor_x = 1
		ea.cursor_y += ea.row_height + 1
		ea.row_height = 0
	}
	if ea.cursor_y + bmp.height + 1 > EMOJI_ATLAS_DIM {
		ea.cursor_x = 1
		ea.cursor_y = 1
		ea.row_height = 0
		clear(&ea.glyphs)
		mem.zero_slice(ea.pixels)
	}

	dst_x := ea.cursor_x
	dst_y := ea.cursor_y
	for y in 0..<bmp.height {
		for x in 0..<bmp.width {
			src := (y * bmp.width + x) * 4
			dst := ((dst_y + y) * EMOJI_ATLAS_DIM + (dst_x + x)) * 4
			ea.pixels[dst + 0] = bmp.pixels[src + 0]
			ea.pixels[dst + 1] = bmp.pixels[src + 1]
			ea.pixels[dst + 2] = bmp.pixels[src + 2]
			ea.pixels[dst + 3] = bmp.pixels[src + 3]
		}
	}

	glyph = Emoji_Glyph{
		u0     = f32(dst_x) / f32(EMOJI_ATLAS_DIM),
		v0     = f32(dst_y) / f32(EMOJI_ATLAS_DIM),
		u1     = f32(dst_x + bmp.width) / f32(EMOJI_ATLAS_DIM),
		v1     = f32(dst_y + bmp.height) / f32(EMOJI_ATLAS_DIM),
		width  = f32(bmp.width),
		height = f32(bmp.height),
	}
	ea.glyphs[key] = glyph
	ea.cursor_x += bmp.width + 1
	ea.row_height = max(ea.row_height, bmp.height)
	ea.gpu_dirty = true
	return glyph, true
}

emoji_atlas_upload :: proc(ea: ^Emoji_Atlas_Manager, device: contract.Gpu_Device, queue: contract.Gpu_Queue) -> bool {
	if ea == nil do return false
	if !ea.gpu_dirty && rawptr(ea.gpu_texture) != nil do return true

	if rawptr(ea.gpu_texture) == nil {
		usage := contract.Gpu_Texture_Usage.Copy_Dst | contract.Gpu_Texture_Usage.Texture_Binding
		ea.gpu_texture = contract.create_texture(device, EMOJI_ATLAS_DIM, EMOJI_ATLAS_DIM, .RGBA8_Unorm, usage)
		if rawptr(ea.gpu_texture) == nil do return false
		ea.gpu_view = contract.create_texture_view(ea.gpu_texture)
		if rawptr(ea.gpu_view) == nil do return false
	}

	if contract.write_texture != nil && len(ea.pixels) > 0 {
		contract.write_texture(queue, ea.gpu_texture, ea.pixels, EMOJI_ATLAS_DIM, EMOJI_ATLAS_DIM)
		ea.gpu_dirty = false
		return true
	}
	return false
}

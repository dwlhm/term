package render

// Emoji atlas: shapes and rasterizes emoji clusters into a dynamic RGBA8 texture atlas.
// Uses FreeType2 (color glyphs) and HarfBuzz (CTL cluster shaping) cross-platform.

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "gpu"

Emoji_Glyph_Info :: struct {
	uv:      [4]f32,
	size:    [2]f32,
	offset:  [2]f32,
	advance: f32,
}

DEFAULT_EMOJI_ATLAS_DIM :: 1024

Emoji_Atlas :: struct {
	pixels:         []u8, // 4 bytes per pixel (RGBA8)
	width, height:  int,
	cursor_x, cursor_y, row_height: int,
	font_size_px:   f32,
	display_scale:  f32,
	glyphs:         map[u64]Emoji_Glyph_Info,
	gpu_dirty:      bool,
	eviction_count: u32,
	gpu_texture:    gpu.Gpu_Texture,
	gpu_view:       gpu.Gpu_TextureView,
	// FreeType & HarfBuzz font engine handles (cross-platform)
	ft_lib:         FT_Library,
	face:           FT_Face,
	hb_font:        hb_font_t,
	has_font:       bool,
}

// System emoji font search candidates
EMOJI_FONT_CANDIDATES := []string{
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/Supplemental/Apple Color Emoji.ttc",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/usr/share/fonts/google-noto-color-emoji/NotoColorEmoji.ttf",
	"/usr/share/fonts/NotoColorEmoji.ttf",
	"assets/fonts/NotoColorEmoji.ttf",
}

emoji_atlas_init :: proc(a: ^Emoji_Atlas, font_size_px: f32, display_scale: f32 = 1.0) -> bool {
	a.display_scale = display_scale > 0 ? display_scale : 1.0
	a.font_size_px = font_size_px
	a.width = DEFAULT_EMOJI_ATLAS_DIM
	a.height = DEFAULT_EMOJI_ATLAS_DIM
	a.pixels = make([]u8, a.width * a.height * 4)
	a.cursor_x = 1
	a.cursor_y = 1
	a.row_height = 0
	a.glyphs = make(map[u64]Emoji_Glyph_Info)
	a.gpu_dirty = false
	a.eviction_count = 0
	a.gpu_texture = gpu.Gpu_Texture(nil)
	a.gpu_view = gpu.Gpu_TextureView(nil)
	a.has_font = false

	// Initialize FreeType
	if FT_Init_FreeType(&a.ft_lib) != 0 {
		return false
	}

	// Probe candidate emoji font files
	for path in EMOJI_FONT_CANDIDATES {
		actual_path := path
		if strings.has_prefix(path, "~/") {
			if home, ok := os.lookup_env("HOME", context.temp_allocator); ok {
				actual_path = strings.concatenate({home, path[1:]}, context.temp_allocator)
			}
		}
		c_path := strings.clone_to_cstring(actual_path, context.temp_allocator)
		if FT_New_Face(a.ft_lib, c_path, 0, &a.face) == 0 && a.face != nil {
			FT_Set_Pixel_Sizes(a.face, 0, FT_UInt(font_size_px))
			a.hb_font = hb_ft_font_create_referenced(a.face)
			a.has_font = true
			break
		}
	}

	return true
}

emoji_atlas_destroy :: proc(a: ^Emoji_Atlas, backend: ^gpu.Gpu_Backend_VTable = nil) {
	if a == nil do return
	if backend != nil {
		if rawptr(a.gpu_view) != nil {
			backend.destroy_texture_view(a.gpu_view)
		}
		if rawptr(a.gpu_texture) != nil {
			backend.destroy_texture(a.gpu_texture)
		}
	}
	if a.hb_font != nil {
		hb_font_destroy(a.hb_font)
		a.hb_font = nil
	}
	if a.face != nil {
		FT_Done_Face(a.face)
		a.face = nil
	}
	if a.ft_lib != nil {
		FT_Done_FreeType(a.ft_lib)
		a.ft_lib = nil
	}
	if len(a.pixels) > 0 {
		delete(a.pixels)
		a.pixels = nil
	}
	if a.glyphs != nil {
		delete(a.glyphs)
		a.glyphs = nil
	}
	a.gpu_texture = gpu.Gpu_Texture(nil)
	a.gpu_view = gpu.Gpu_TextureView(nil)
	a.has_font = false
}

emoji_atlas_evict_or_reset :: proc(a: ^Emoji_Atlas) {
	if a == nil do return
	a.cursor_x = 1
	a.cursor_y = 1
	a.row_height = 0
	clear(&a.glyphs)
	if len(a.pixels) > 0 {
		mem.zero_slice(a.pixels)
	}
	a.eviction_count += 1
	a.gpu_dirty = true
}

FNV1A_64_OFFSET_BASIS :: 14695981039346656037
FNV1A_64_PRIME        :: 1099511628211

cluster_hash_fnv1a :: proc(s: string) -> u64 {
	hash: u64 = FNV1A_64_OFFSET_BASIS
	bytes := transmute([]u8)s
	for b in bytes {
		hash ~= u64(b)
		hash *= FNV1A_64_PRIME
	}
	return hash
}

// emoji_atlas_get_cluster shapes the emoji cluster with HarfBuzz and rasterizes with FreeType.
emoji_atlas_get_cluster :: proc(a: ^Emoji_Atlas, cluster: string, target_h: f32 = 0.0) -> (info: Emoji_Glyph_Info, found: bool) {
	if a == nil || !a.has_font || a.face == nil || a.hb_font == nil || len(cluster) == 0 {
		return {}, false
	}

	key := cluster_hash_fnv1a(cluster)
	if key in a.glyphs {
		return a.glyphs[key], true
	}

	// HarfBuzz cluster shaping
	buf := hb_buffer_create()
	defer hb_buffer_destroy(buf)

	hb_buffer_add_utf8(buf, raw_data(cluster), c.int(len(cluster)), 0, c.int(len(cluster)))
	hb_buffer_guess_segment_properties(buf)
	hb_shape(a.hb_font, buf, nil, 0)

	glyph_count: c.uint
	infos := hb_buffer_get_glyph_infos(buf, &glyph_count)
	positions := hb_buffer_get_glyph_positions(buf, &glyph_count)

	if glyph_count == 0 {
		return {}, false
	}

	// Load first glyph (most emoji sequences collapse to 1 or 2 ligature glyphs)
	glyph_id := infos[0].codepoint
	load_flags := FT_LOAD_COLOR | FT_LOAD_RENDER
	if FT_Load_Glyph(a.face, FT_UInt(glyph_id), i32(load_flags)) != 0 {
		// Fallback without COLOR flag
		if FT_Load_Glyph(a.face, FT_UInt(glyph_id), FT_LOAD_RENDER) != 0 {
			return {}, false
		}
	}

	slot := a.face.glyph
	gw := int(slot.bitmap.width)
	gh := int(slot.bitmap.rows)

	if gw <= 0 || gh <= 0 {
		gw = int(a.font_size_px)
		gh = int(a.font_size_px)
	}

	// Atlas packing
	if a.cursor_x + gw + 1 > a.width {
		a.cursor_y += a.row_height + 1
		a.cursor_x = 1
		a.row_height = 0
	}
	if a.cursor_y + gh + 1 > a.height {
		emoji_atlas_evict_or_reset(a)
		if a.cursor_y + gh + 1 > a.height {
			return {}, false
		}
	}

	// Copy glyph bitmap into atlas
	pitch := int(slot.bitmap.pitch)
	src_buf := slot.bitmap.buffer
	mode := slot.bitmap.pixel_mode

	if gw > 0 && gh > 0 && src_buf != nil {
		for row in 0..<min(gh, int(slot.bitmap.rows)) {
			dst_y := a.cursor_y + row
			if dst_y >= a.height do break
			for col in 0..<min(gw, int(slot.bitmap.width)) {
				dst_x := a.cursor_x + col
				if dst_x >= a.width do break
				dst_idx := (dst_y * a.width + dst_x) * 4

				if mode == u8(FT_Pixel_Mode.BGRA) {
					// FreeType color bitmap is BGRA: convert to RGBA
					src_idx := row * pitch + col * 4
					b := src_buf[src_idx + 0]
					g := src_buf[src_idx + 1]
					r := src_buf[src_idx + 2]
					alpha := src_buf[src_idx + 3]
					a.pixels[dst_idx + 0] = r
					a.pixels[dst_idx + 1] = g
					a.pixels[dst_idx + 2] = b
					a.pixels[dst_idx + 3] = alpha
				} else if mode == u8(FT_Pixel_Mode.GRAY) {
					src_idx := row * pitch + col
					v := src_buf[src_idx]
					a.pixels[dst_idx + 0] = 255
					a.pixels[dst_idx + 1] = 255
					a.pixels[dst_idx + 2] = 255
					a.pixels[dst_idx + 3] = v
				} else if mode == u8(FT_Pixel_Mode.MONO) {
					byte_val := src_buf[row * pitch + (col >> 3)]
					bit_val := (byte_val >> uint(7 - (col & 7))) & 1
					v := u8(bit_val != 0 ? 255 : 0)
					a.pixels[dst_idx + 0] = 255
					a.pixels[dst_idx + 1] = 255
					a.pixels[dst_idx + 2] = 255
					a.pixels[dst_idx + 3] = v
				}
			}
		}
	}

	adv := f32(positions[0].x_advance) / 64.0
	if adv <= 0 {
		adv = f32(gw)
	}

	info.uv = {
		f32(a.cursor_x) / f32(a.width),
		f32(a.cursor_y) / f32(a.height),
		f32(a.cursor_x + gw) / f32(a.width),
		f32(a.cursor_y + gh) / f32(a.height),
	}
	info.size = { f32(gw), f32(gh) }
	info.offset = { f32(slot.bitmap_left), -f32(slot.bitmap_top) }
	info.advance = adv

	if gh > a.row_height {
		a.row_height = gh
	}
	a.cursor_x += gw + 1
	a.gpu_dirty = true

	a.glyphs[key] = info
	return info, true
}

emoji_atlas_get_glyph :: proc(a: ^Emoji_Atlas, ch: rune) -> (info: Emoji_Glyph_Info, found: bool) {
	if a == nil do return {}, false
	if u64(ch) in a.glyphs {
		return a.glyphs[u64(ch)], true
	}
	buf, n := utf8.encode_rune(ch)
	if n <= 0 do return {}, false
	info, found = emoji_atlas_get_cluster(a, string(buf[:n]))
	if found {
		a.glyphs[u64(ch)] = info
	}
	return info, found
}

emoji_atlas_upload_gpu :: proc(
	a: ^Emoji_Atlas,
	backend: ^gpu.Gpu_Backend_VTable,
	device: gpu.Gpu_Device,
	queue: gpu.Gpu_Queue,
) {
	if backend == nil || rawptr(device) == nil || rawptr(queue) == nil || a == nil || len(a.pixels) == 0 {
		return
	}
	if a.gpu_dirty || rawptr(a.gpu_texture) == nil {
		if rawptr(a.gpu_texture) == nil {
			a.gpu_texture = backend.create_texture(
				device,
				u32(a.width),
				u32(a.height),
				gpu.Gpu_Format.RGBA8_Unorm,
				gpu.Gpu_Texture_Usage.Texture_Binding | gpu.Gpu_Texture_Usage.Copy_Dst,
			)
			a.gpu_view = backend.create_texture_view(a.gpu_texture)
		}
		backend.write_texture(queue, a.gpu_texture, a.pixels, u32(a.width), u32(a.height))
		a.gpu_dirty = false
	}
}

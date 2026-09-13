package render

import "base:runtime"
import "core:c"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import "core:unicode/utf16"
import CF "core:sys/darwin/CoreFoundation"
import "gpu"

when ODIN_OS == .Darwin {
	foreign import CoreText "system:CoreText.framework"
	foreign import CoreGraphics "system:CoreGraphics.framework"
	foreign import CoreFoundation "system:CoreFoundation.framework"

	CTFontRef :: distinct rawptr
	CGContextRef :: distinct rawptr
	CGColorSpaceRef :: distinct rawptr
	CFAttributedStringRef :: distinct rawptr
	CTLineRef :: distinct rawptr
	CFDictionaryRef :: distinct rawptr

	kCGBitmapByteOrder32Big :: 4 << 12
	kCGImageAlphaPremultipliedLast :: 1
	kCFStringEncodingUTF8 :: 0x08000100

	@(default_calling_convention="c")
	foreign CoreFoundation {
		CFStringCreateWithCString :: proc(alloc: CF.TypeRef, cstr: cstring, encoding: u32) -> CF.String ---
		CFDictionaryCreate :: proc(allocator: CF.TypeRef, keys: [^]rawptr, values: [^]rawptr, numValues: CF.Index, keyCallBacks: rawptr, valueCallBacks: rawptr) -> CFDictionaryRef ---
		CFAttributedStringCreate :: proc(alloc: CF.TypeRef, str: CF.String, attributes: CFDictionaryRef) -> CFAttributedStringRef ---
	}

	@(default_calling_convention="c")
	foreign CoreText {
		kCTFontAttributeName: CF.String
		CTFontCreateWithName :: proc(name: CF.String, size: CF.CGFloat, mat: rawptr) -> CTFontRef ---
		CTFontGetGlyphsForCharacters :: proc(font: CTFontRef, characters: [^]u16, glyphs: [^]u16, count: int) -> bool ---
		CTFontGetBoundingRectsForGlyphs :: proc(font: CTFontRef, orientation: u32, glyphs: [^]u16, boundingRects: [^]CF.CGRect, count: int) -> CF.CGRect ---
		CTFontGetAdvancesForGlyphs :: proc(font: CTFontRef, orientation: u32, glyphs: [^]u16, advances: [^]CF.CGSize, count: int) -> f64 ---
		CTFontDrawGlyphs :: proc(font: CTFontRef, glyphs: [^]u16, positions: [^]CF.CGPoint, count: int, ctx: CGContextRef) ---
		CTLineCreateWithAttributedString :: proc(attrString: CFAttributedStringRef) -> CTLineRef ---
		CTLineGetImageBounds :: proc(line: CTLineRef, ctx: CGContextRef) -> CF.CGRect ---
		CTLineGetTypographicBounds :: proc(line: CTLineRef, ascent: ^CF.CGFloat, descent: ^CF.CGFloat, leading: ^CF.CGFloat) -> f64 ---
		CTLineDraw :: proc(line: CTLineRef, ctx: CGContextRef) ---
	}

	@(default_calling_convention="c")
	foreign CoreGraphics {
		CGBitmapContextCreate :: proc(data: rawptr, width, height, bitsPerComponent, bytesPerRow: uint, space: CGColorSpaceRef, bitmapInfo: u32) -> CGContextRef ---
		CGColorSpaceCreateDeviceRGB :: proc() -> CGColorSpaceRef ---
		CGColorSpaceRelease :: proc(space: CGColorSpaceRef) ---
		CGContextRelease :: proc(c: CGContextRef) ---
		CGContextTranslateCTM :: proc(c: CGContextRef, tx: CF.CGFloat, ty: CF.CGFloat) ---
	}

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
		ct_font:        CTFontRef,
		color_space:    CGColorSpaceRef,
	}

	emoji_atlas_init :: proc(a: ^Emoji_Atlas, font_size_px: f32, display_scale: f32 = 1.0) -> bool {
		a.display_scale = display_scale > 0 ? display_scale : 1.0
		a.font_size_px = font_size_px

		cf_name := CFStringCreateWithCString(nil, "AppleColorEmoji", 0x08000100)
		if cf_name == nil {
			return false
		}
		defer CF.Release(cf_name)

		a.ct_font = CTFontCreateWithName(cf_name, CF.CGFloat(font_size_px), nil)
		if a.ct_font == nil {
			return false
		}

		a.color_space = CGColorSpaceCreateDeviceRGB()
		if a.color_space == nil {
			CF.ReleaseObject(CF.TypeRef(a.ct_font))
			a.ct_font = nil
			return false
		}

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

		return true
	}

	emoji_atlas_destroy :: proc(a: ^Emoji_Atlas) {
		if a == nil do return
		if a.color_space != nil {
			CGColorSpaceRelease(a.color_space)
			a.color_space = nil
		}
		if a.ct_font != nil {
			CF.ReleaseObject(CF.TypeRef(a.ct_font))
			a.ct_font = nil
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

	emoji_atlas_get_cluster :: proc(a: ^Emoji_Atlas, cluster: string, target_h: f32 = 0.0) -> (info: Emoji_Glyph_Info, found: bool) {
		if a == nil || a.ct_font == nil || len(cluster) == 0 do return {}, false

		key := cluster_hash_fnv1a(cluster)
		if key in a.glyphs {
			return a.glyphs[key], true
		}

		cstr := strings.clone_to_cstring(cluster, context.temp_allocator)
		cf_str := CFStringCreateWithCString(nil, cstr, kCFStringEncodingUTF8)
		if cf_str == nil do return {}, false
		defer CF.Release(cf_str)

		keys := [1]rawptr{ rawptr(kCTFontAttributeName) }
		values := [1]rawptr{ rawptr(a.ct_font) }
		dict := CFDictionaryCreate(nil, raw_data(keys[:]), raw_data(values[:]), 1, nil, nil)
		if dict == nil do return {}, false
		defer CF.ReleaseObject(CF.TypeRef(dict))

		attr_str := CFAttributedStringCreate(nil, cf_str, dict)
		if attr_str == nil do return {}, false
		defer CF.ReleaseObject(CF.TypeRef(attr_str))

		line := CTLineCreateWithAttributedString(attr_str)
		if line == nil do return {}, false
		defer CF.ReleaseObject(CF.TypeRef(line))

		bounds := CTLineGetImageBounds(line, nil)
		ascent, descent, leading: CF.CGFloat
		adv := CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

		gw := int(math.ceil(f64(bounds.size.width)))
		gh := int(math.ceil(f64(bounds.size.height)))

		if gw <= 0 || gh <= 0 {
			gw = int(math.ceil(adv))
			gh = int(a.font_size_px)
			if gw <= 0 do gw = int(a.font_size_px)
		}

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

		if gw > 0 && gh > 0 {
			tmp_buf := make([]u8, gw * gh * 4)
			defer delete(tmp_buf)

			ctx := CGBitmapContextCreate(
				raw_data(tmp_buf),
				uint(gw),
				uint(gh),
				8,
				uint(gw * 4),
				a.color_space,
				kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast,
			)
			if ctx != nil {
				defer CGContextRelease(ctx)

				CGContextTranslateCTM(ctx, -bounds.origin.x, -bounds.origin.y)
				CTLineDraw(line, ctx)

				for row in 0..<gh {
					src_offset := row * gw * 4
					dst_offset := ((a.cursor_y + row) * a.width + a.cursor_x) * 4
					copy(a.pixels[dst_offset : dst_offset + gw * 4], tmp_buf[src_offset : src_offset + gw * 4])
				}
			}
		}

		info.uv = {
			f32(a.cursor_x) / f32(a.width),
			f32(a.cursor_y) / f32(a.height),
			f32(a.cursor_x + gw) / f32(a.width),
			f32(a.cursor_y + gh) / f32(a.height),
		}
		info.size = { f32(gw), f32(gh) }
		info.offset = { f32(bounds.origin.x), -f32(bounds.origin.y + bounds.size.height) }
		info.advance = f32(adv) > 0 ? f32(adv) : f32(gw)

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
}

when ODIN_OS != .Darwin {
	Emoji_Glyph_Info :: struct {
		uv:      [4]f32,
		size:    [2]f32,
		offset:  [2]f32,
		advance: f32,
	}

	Emoji_Atlas :: struct {
		pixels:         []u8,
		width, height:  int,
		cursor_x, cursor_y, row_height: int,
		font_size_px:   f32,
		display_scale:  f32,
		glyphs:         map[u64]Emoji_Glyph_Info,
		gpu_dirty:      bool,
		eviction_count: u32,
		gpu_texture:    gpu.Gpu_Texture,
		gpu_view:       gpu.Gpu_TextureView,
	}

	emoji_atlas_init :: proc(a: ^Emoji_Atlas, font_size_px: f32, display_scale: f32 = 1.0) -> bool { return false }
	emoji_atlas_destroy :: proc(a: ^Emoji_Atlas) {}
	emoji_atlas_get_cluster :: proc(a: ^Emoji_Atlas, cluster: string, target_h: f32 = 0.0) -> (Emoji_Glyph_Info, bool) { return {}, false }
	emoji_atlas_get_glyph :: proc(a: ^Emoji_Atlas, ch: rune) -> (Emoji_Glyph_Info, bool) { return {}, false }
	emoji_atlas_upload_gpu :: proc(a: ^Emoji_Atlas, backend: ^gpu.Gpu_Backend_VTable, device: gpu.Gpu_Device, queue: gpu.Gpu_Queue) {}
}

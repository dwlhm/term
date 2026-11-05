#+build linux
package platform_font

// Linux Font Discovery Fallbacks
// Platform Font Subsystem (src/platform/font/*).

import "base:runtime"
import "core:os"
import "core:strings"

@(private = "file")
LINUX_FIXED_PITCH_PATHS := []string{
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	"/usr/share/fonts/opentype/noto/NotoSansMono-Regular.otf",
}

@(private = "file")
LINUX_CASCADE_PATHS := []string{
	"/usr/share/fonts/opentype/noto/NotoSansArabic-Regular.otf",
	"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
}

@(private = "file")
LINUX_SANS_PATHS := []string{
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	"/usr/share/fonts/opentype/noto/NotoSans-Regular.otf",
}

linux_query_os_default_font :: proc(style: Font_Style_Class = .Mono, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	paths := LINUX_SANS_PATHS if style == .Sans else LINUX_FIXED_PITCH_PATHS
	for p in paths {
		if os.is_file(p) do return strings.clone(p, allocator), true
	}
	return "", false
}

linux_query_os_fixed_pitch_font :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	return linux_query_os_default_font(.Mono, allocator)
}

linux_query_os_cascade_fonts :: proc(max_count: int, allocator := context.temp_allocator, style: Font_Style_Class = .Mono) -> []string {
	results := make([dynamic]string, 0, max_count, allocator)
	for p in LINUX_CASCADE_PATHS {
		if len(results) >= max_count do break
		if os.is_file(p) do append(&results, strings.clone(p, allocator))
	}
	return results[:]
}

linux_query_font_by_name :: proc(name: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	return "", false
}

// Per-codepoint discovery needs Fontconfig (FcFontSort + FcCharSet), which is
// not bound yet; Linux relies on the static cascade above.
linux_query_font_for_codepoint :: proc(cp: u32, allocator := context.temp_allocator, style: Font_Style_Class = .Mono) -> (path: string, ok: bool) {
	return "", false
}

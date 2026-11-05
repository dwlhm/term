#+build darwin
package platform_font

// Native Apple CoreText & Cocoa Font Discovery
// Platform Font Subsystem (src/platform/font/*).

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"

foreign import CoreText "system:CoreText.framework"
foreign import CoreFoundation "system:CoreFoundation.framework"

@(private = "file")
CFTypeRef           :: distinct rawptr
@(private = "file")
CFStringRef         :: distinct rawptr
@(private = "file")
CFURLRef            :: distinct rawptr
@(private = "file")
CFArrayRef          :: distinct rawptr
@(private = "file")
CTFontRef           :: distinct rawptr
@(private = "file")
CTFontDescriptorRef :: distinct rawptr
@(private = "file")
Boolean             :: u8
@(private = "file")
CFIndex             :: c.long
@(private = "file")
CFRange             :: struct {
	location: CFIndex,
	length:   CFIndex,
}

@(private = "file")
kCFStringEncodingUTF8: u32 : 0x08000100

foreign CoreFoundation {
	@(private = "file")
	CFStringCreateWithCString        :: proc(alloc: rawptr, cStr: cstring, encoding: u32) -> CFStringRef ---
	@(private = "file")
	CFStringCreateWithCharacters     :: proc(alloc: rawptr, chars: [^]u16, numChars: CFIndex) -> CFStringRef ---
	@(private = "file")
	CFRelease                        :: proc(cf: CFTypeRef) ---
	@(private = "file")
	CFURLGetFileSystemRepresentation :: proc(url: CFURLRef, resolveAgainstBase: Boolean, buffer: [^]u8, maxBufLen: CFIndex) -> Boolean ---
	@(private = "file")
	CFArrayGetCount                  :: proc(theArray: CFArrayRef) -> CFIndex ---
	@(private = "file")
	CFArrayGetValueAtIndex           :: proc(theArray: CFArrayRef, idx: CFIndex) -> rawptr ---
}

foreign CoreText {
	@(private = "file")
	kCTFontURLAttribute                   : CFStringRef
	@(private = "file")
	CTFontCreateUIFontForLanguage         :: proc(uiType: u32, size: f64, language: CFStringRef) -> CTFontRef ---
	@(private = "file")
	CTFontCopyPostScriptName              :: proc(font: CTFontRef) -> CFStringRef ---
	@(private = "file")
	CTFontCopyDefaultCascadeListForLanguages :: proc(font: CTFontRef, languagePrefList: CFArrayRef) -> CFArrayRef ---
	@(private = "file")
	CTFontDescriptorCopyAttribute         :: proc(descriptor: CTFontDescriptorRef, attribute: CFStringRef) -> CFTypeRef ---
	@(private = "file")
	CTFontDescriptorCreateWithNameAndSize :: proc(name: CFStringRef, size: f64) -> CTFontDescriptorRef ---
	@(private = "file")
	CTFontCreateForString                 :: proc(currentFont: CTFontRef, str: CFStringRef, range: CFRange) -> CTFontRef ---
	@(private = "file")
	CTFontCopyAttribute                   :: proc(font: CTFontRef, attribute: CFStringRef) -> CFTypeRef ---
}

@(private = "file")
_darwin_url_to_path :: proc(url: CFURLRef, allocator: runtime.Allocator) -> (string, bool) {
	if url == nil do return "", false
	buf: [1024]u8
	if CFURLGetFileSystemRepresentation(url, 1, raw_data(buf[:]), len(buf)) != 0 {
		n := 0
		for n < len(buf) && buf[n] != 0 do n += 1
		p := string(buf[:n])
		if os.is_file(p) do return strings.clone(p, allocator), true
	}
	return "", false
}

@(private = "file")
_darwin_desc_to_path :: proc(desc: CTFontDescriptorRef, allocator: runtime.Allocator) -> (string, bool) {
	if desc == nil do return "", false
	attr := CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute)
	if attr == nil do return "", false
	defer CFRelease(attr)
	return _darwin_url_to_path(CFURLRef(attr), allocator)
}

darwin_query_font_by_name :: proc(name: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	if len(name) == 0 do return "", false
	c_name := strings.clone_to_cstring(name, context.temp_allocator)
	name_cf := CFStringCreateWithCString(nil, c_name, kCFStringEncodingUTF8)
	if name_cf == nil do return "", false
	defer CFRelease(CFTypeRef(name_cf))

	desc := CTFontDescriptorCreateWithNameAndSize(name_cf, 14.0)
	if desc == nil do return "", false
	defer CFRelease(CFTypeRef(desc))

	return _darwin_desc_to_path(desc, allocator)
}

@(private = "file")
_darwin_ui_font_type :: proc(style: Font_Style_Class) -> u32 {
	// kCTFontUIFontSystem = 0, kCTFontUIFontUserFixedPitch = 1
	return 0 if style == .Sans else 1
}

darwin_query_os_default_font :: proc(style: Font_Style_Class = .Mono, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	font := CTFontCreateUIFontForLanguage(_darwin_ui_font_type(style), 14.0, nil)
	if font == nil do return "", false
	defer CFRelease(CFTypeRef(font))

	if url := CTFontCopyAttribute(font, kCTFontURLAttribute); url != nil {
		defer CFRelease(url)
		if p, url_ok := _darwin_url_to_path(CFURLRef(url), allocator); url_ok {
			return p, true
		}
	}

	ps := CTFontCopyPostScriptName(font)
	if ps == nil do return "", false
	defer CFRelease(CFTypeRef(ps))

	desc := CTFontDescriptorCreateWithNameAndSize(ps, 14.0)
	if desc == nil do return "", false
	defer CFRelease(CFTypeRef(desc))

	return _darwin_desc_to_path(desc, allocator)
}

darwin_query_os_fixed_pitch_font :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	return darwin_query_os_default_font(.Mono, allocator)
}

darwin_query_os_cascade_fonts :: proc(max_count: int, allocator := context.temp_allocator, style: Font_Style_Class = .Mono) -> []string {
	if max_count <= 0 do return nil

	font := CTFontCreateUIFontForLanguage(_darwin_ui_font_type(style), 14.0, nil)
	if font == nil do return nil
	defer CFRelease(CFTypeRef(font))

	cascade := CTFontCopyDefaultCascadeListForLanguages(font, nil)
	if cascade == nil do return nil
	defer CFRelease(CFTypeRef(cascade))

	total := int(CFArrayGetCount(cascade))
	results := make([dynamic]string, 0, max_count, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	defer delete(seen)

	for i in 0..<total {
		if len(results) >= max_count do break
		desc := CTFontDescriptorRef(CFArrayGetValueAtIndex(cascade, CFIndex(i)))
		if path, ok := _darwin_desc_to_path(desc, allocator); ok {
			if !seen[path] {
				seen[path] = true
				append(&results, path)
			}
		}
	}
	return results[:]
}

// darwin_query_font_for_codepoint asks CoreText's per-character fallback which
// installed font covers `cp`, rejecting the LastResort placeholder font.
darwin_query_font_for_codepoint :: proc(cp: u32, allocator := context.temp_allocator, style: Font_Style_Class = .Mono) -> (path: string, ok: bool) {
	units: [2]u16
	n := 1
	if cp >= 0x10000 {
		v := cp - 0x10000
		units = {u16(0xD800 + (v >> 10)), u16(0xDC00 + (v & 0x3FF))}
		n = 2
	} else {
		units[0] = u16(cp)
	}
	str := CFStringCreateWithCharacters(nil, raw_data(units[:]), CFIndex(n))
	if str == nil do return "", false
	defer CFRelease(CFTypeRef(str))

	base := CTFontCreateUIFontForLanguage(_darwin_ui_font_type(style), 14.0, nil)
	if base == nil do return "", false
	defer CFRelease(CFTypeRef(base))

	font := CTFontCreateForString(base, str, CFRange{0, CFIndex(n)})
	if font == nil do return "", false
	defer CFRelease(CFTypeRef(font))

	url := CTFontCopyAttribute(font, kCTFontURLAttribute)
	if url == nil do return "", false
	defer CFRelease(url)
	path, ok = _darwin_url_to_path(CFURLRef(url), allocator)
	if ok && strings.has_suffix(path, "LastResort.otf") {
		delete(path, allocator)
		return "", false
	}
	return path, ok
}

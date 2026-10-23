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
kCFStringEncodingUTF8: u32 : 0x08000100

foreign CoreFoundation {
	@(private = "file")
	CFStringCreateWithCString        :: proc(alloc: rawptr, cStr: cstring, encoding: u32) -> CFStringRef ---
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

darwin_query_os_fixed_pitch_font :: proc(allocator := context.temp_allocator) -> (path: string, ok: bool) {
	// kCTFontUIFontUserFixedPitch = 1
	font := CTFontCreateUIFontForLanguage(1, 14.0, nil)
	if font == nil do return "", false
	defer CFRelease(CFTypeRef(font))

	ps := CTFontCopyPostScriptName(font)
	if ps == nil do return "", false
	defer CFRelease(CFTypeRef(ps))

	desc := CTFontDescriptorCreateWithNameAndSize(ps, 14.0)
	if desc == nil do return "", false
	defer CFRelease(CFTypeRef(desc))

	return _darwin_desc_to_path(desc, allocator)
}

darwin_query_os_cascade_fonts :: proc(max_count: int, allocator := context.temp_allocator) -> []string {
	if max_count <= 0 do return nil

	font := CTFontCreateUIFontForLanguage(1, 14.0, nil)
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

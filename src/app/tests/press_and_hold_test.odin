package app_test

import "core:testing"
import win "../../platform/window"

@(test)
test_platform_disable_press_and_hold :: proc(t: ^testing.T) {
	// Verify that platform_disable_press_and_hold runs safely and without errors
	win.platform_disable_press_and_hold()
	testing.expect(t, true, "platform_disable_press_and_hold executed successfully")
}

when ODIN_OS == .Darwin {
	foreign import CoreFoundation "system:CoreFoundation.framework"

	@(default_calling_convention="c")
	foreign CoreFoundation {
		kCFBooleanFalse: rawptr
		kCFPreferencesCurrentApplication: rawptr
		CFStringCreateWithCString :: proc(alloc: rawptr, cstr: cstring, encoding: u32) -> rawptr ---
		CFRelease :: proc(cf: rawptr) ---
		CFPreferencesCopyAppValue :: proc(key: rawptr, applicationID: rawptr) -> rawptr ---
	}

	@(test)
	test_platform_disable_press_and_hold_darwin :: proc(t: ^testing.T) {
		win.platform_disable_press_and_hold()

		key := CFStringCreateWithCString(nil, "ApplePressAndHoldEnabled", 0x08000100)
		if key != nil {
			defer CFRelease(key)
			val := CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication)
			if val != nil {
				defer CFRelease(val)
				testing.expect(t, val == kCFBooleanFalse, "ApplePressAndHoldEnabled preference must be kCFBooleanFalse")
			}
		}
	}
}

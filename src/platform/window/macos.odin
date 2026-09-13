package window

// macOS platform-specific window configuration.
// Disables Apple Press and Hold to allow continuous key repeat events for terminal applications.

APPLE_PRESS_AND_HOLD_ENABLED_KEY :: "ApplePressAndHoldEnabled"

when ODIN_OS == .Darwin {
	foreign import libobjc "system:objc"
	foreign import CoreFoundation "system:CoreFoundation.framework"

	id :: distinct rawptr
	SEL :: distinct rawptr
	Class :: distinct rawptr
	BOOL :: bool

	kCFStringEncodingUTF8 :: 0x08000100

	@(default_calling_convention="c")
	foreign libobjc {
		objc_getClass :: proc(name: cstring) -> Class ---
		sel_registerName :: proc(name: cstring) -> SEL ---
		object_getClass :: proc(obj: id) -> Class ---
		class_getMethodImplementation :: proc(cls: Class, name: SEL) -> rawptr ---
	}

	@(default_calling_convention="c")
	foreign CoreFoundation {
		kCFBooleanFalse: rawptr
		kCFPreferencesCurrentApplication: rawptr

		CFStringCreateWithCString :: proc(alloc: rawptr, cstr: cstring, encoding: u32) -> rawptr ---
		CFRelease :: proc(cf: rawptr) ---
		CFPreferencesSetAppValue :: proc(key: rawptr, value: rawptr, applicationID: rawptr) ---
		CFPreferencesAppSynchronize :: proc(applicationID: rawptr) -> b8 ---
	}

	// platform_disable_press_and_hold disables Apple Press and Hold for the process
	// so that holding down keys sends repeated keydown/textinput events instead of
	// popping up the accent picker.
	platform_disable_press_and_hold :: proc() {
		key_str := CFStringCreateWithCString(nil, APPLE_PRESS_AND_HOLD_ENABLED_KEY, kCFStringEncodingUTF8)
		if key_str == nil {
			return
		}
		defer CFRelease(key_str)

		// 1. NSUserDefaults standardUserDefaults -> setBool:false forKey:@"ApplePressAndHoldEnabled"
		cls_user_defaults := objc_getClass("NSUserDefaults")
		if cls_user_defaults != nil {
			meta_cls := object_getClass(id(cls_user_defaults))
			sel_standard_user_defaults := sel_registerName("standardUserDefaults")
			sel_set_bool := sel_registerName("setBool:forKey:")

			imp_standard := class_getMethodImplementation(meta_cls, sel_standard_user_defaults)
			if imp_standard != nil {
				Get_Defaults_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
				defaults := (Get_Defaults_Proc(imp_standard))(cls_user_defaults, sel_standard_user_defaults)

				if defaults != nil {
					imp_set_bool := class_getMethodImplementation(cls_user_defaults, sel_set_bool)
					if imp_set_bool != nil {
						Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, value: BOOL, key: rawptr)
						(Set_Bool_Proc(imp_set_bool))(defaults, sel_set_bool, false, key_str)
					}
				}
			}
		}

		// 2. CFPreferencesSetAppValue & CFPreferencesAppSynchronize
		CFPreferencesSetAppValue(key_str, kCFBooleanFalse, kCFPreferencesCurrentApplication)
		_ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
	}
} else {
	// platform_disable_press_and_hold is a no-op on non-Darwin platforms.
	platform_disable_press_and_hold :: proc() {
	}
}

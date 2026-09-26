package window

// macOS platform-specific window configuration.
// Disables Apple Press and Hold to allow continuous key repeat events for terminal applications.
// Configures unified titlebar with full-size content view and hidden title for custom tab bar.

import "vendor:sdl3"

APPLE_PRESS_AND_HOLD_ENABLED_KEY :: "ApplePressAndHoldEnabled"

// SDL consumes draggable mouse events before producing button events. Inspect
// AppKit's current event while SDL calls our hit test, then defer the action.
platform_titlebar_double_click :: proc(handle: ^sdl3.Window, last_event: ^i64) -> bool {
	when ODIN_OS == .Darwin {
		if handle == nil || last_event == nil do return false
		nswindow := id(sdl3.GetPointerProperty(sdl3.GetWindowProperties(handle), sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil do return false
		cls_app := objc_getClass("NSApplication")
		if cls_app == nil do return false
		Get_Object :: #type proc "c" (target: id, sel: SEL) -> id
		Get_Integer :: #type proc "c" (target: id, sel: SEL) -> int
		sel_shared := sel_registerName("sharedApplication")
		imp_shared := class_getMethodImplementation(object_getClass(id(cls_app)), sel_shared)
		if imp_shared == nil do return false
		app := Get_Object(imp_shared)(id(cls_app), sel_shared)
		if app == nil do return false
		sel_event := sel_registerName("currentEvent")
		imp_event := class_getMethodImplementation(object_getClass(app), sel_event)
		if imp_event == nil do return false
		event := Get_Object(imp_event)(app, sel_event)
		if event == nil do return false
		cls_event := object_getClass(event)
		sel_type := sel_registerName("type")
		imp_type := class_getMethodImplementation(cls_event, sel_type)
		if imp_type == nil do return false
		NS_EVENT_LEFT_MOUSE_DOWN :: 1
		if Get_Integer(imp_type)(event, sel_type) != NS_EVENT_LEFT_MOUSE_DOWN do return false
		sel_window := sel_registerName("window")
		imp_window := class_getMethodImplementation(cls_event, sel_window)
		if imp_window == nil || Get_Object(imp_window)(event, sel_window) != nswindow do return false
		sel_clicks := sel_registerName("clickCount")
		imp_clicks := class_getMethodImplementation(cls_event, sel_clicks)
		DOUBLE_CLICK_COUNT :: 2
		if imp_clicks == nil || Get_Integer(imp_clicks)(event, sel_clicks) != DOUBLE_CLICK_COUNT do return false
		sel_number := sel_registerName("eventNumber")
		imp_number := class_getMethodImplementation(cls_event, sel_number)
		if imp_number == nil do return false
		number := Get_Integer(imp_number)(event, sel_number)
		if number < 0 || number == max(int) do return false
		identity := i64(number) + 1
		if identity == last_event^ do return false
		last_event^ = identity
		return true
	} else {
		return false
	}
}

// platform_zoom_window invokes the native standard zoom action, never fullscreen.
platform_zoom_window :: proc(handle: ^sdl3.Window) -> bool {
	when ODIN_OS == .Darwin {
		if handle == nil do return false
		nswindow := id(sdl3.GetPointerProperty(sdl3.GetWindowProperties(handle), sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil do return false
		cls_window := object_getClass(nswindow)
		sel_mask := sel_registerName("styleMask")
		imp_mask := class_getMethodImplementation(cls_window, sel_mask)
		if imp_mask == nil do return false
		Get_Mask :: #type proc "c" (target: id, sel: SEL) -> uint
		NS_WINDOW_FULLSCREEN: uint : 1 << 14
		if Get_Mask(imp_mask)(nswindow, sel_mask) & NS_WINDOW_FULLSCREEN != 0 do return false
		sel_zoom := sel_registerName("performZoom:")
		imp_zoom := class_getMethodImplementation(cls_window, sel_zoom)
		if imp_zoom == nil do return false
		Perform_Zoom :: #type proc "c" (target: id, sel: SEL, sender: id)
		Perform_Zoom(imp_zoom)(nswindow, sel_zoom, nil)
		return true
	} else {
		return false
	}
}

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
		objc_autoreleasePoolPush :: proc() -> rawptr ---
		objc_autoreleasePoolPop  :: proc(pool: rawptr) ---
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

platform_autorelease_pool_push :: proc() -> rawptr {
	when ODIN_OS == .Darwin {
		return objc_autoreleasePoolPush()
	} else {
		return nil
	}
}

platform_autorelease_pool_pop :: proc(pool: rawptr) {
	when ODIN_OS == .Darwin {
		if pool != nil {
			objc_autoreleasePoolPop(pool)
		}
	}
}

platform_setup_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool {
	when ODIN_OS == .Darwin {
		if sdl_window == nil do return false
		props := sdl3.GetWindowProperties(sdl_window)
		nswindow := id(sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil {
			cls_app := objc_getClass("NSApplication")
			if cls_app != nil {
				sel_shared := sel_registerName("sharedApplication")
				sel_key_win := sel_registerName("keyWindow")
				imp_shared := class_getMethodImplementation(object_getClass(id(cls_app)), sel_shared)
				if imp_shared != nil {
					Get_App_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
					app := (Get_App_Proc(imp_shared))(cls_app, sel_shared)
					if app != nil {
						imp_key_win := class_getMethodImplementation(object_getClass(app), sel_key_win)
						if imp_key_win != nil {
							Get_Win_Proc :: #type proc "c" (target: id, sel: SEL) -> id
							nswindow = (Get_Win_Proc(imp_key_win))(app, sel_key_win)
						}
					}
				}
			}
		}
		if nswindow == nil do return false

		cls_win := object_getClass(nswindow)

		// 1. styleMask |= NSWindowStyleMaskFullSizeContentView (1 << 15)
		sel_style_mask := sel_registerName("styleMask")
		sel_set_style_mask := sel_registerName("setStyleMask:")
		imp_style_mask := class_getMethodImplementation(cls_win, sel_style_mask)
		imp_set_style_mask := class_getMethodImplementation(cls_win, sel_set_style_mask)
		if imp_style_mask != nil && imp_set_style_mask != nil {
			Get_Mask_Proc :: #type proc "c" (target: id, sel: SEL) -> uint
			Set_Mask_Proc :: #type proc "c" (target: id, sel: SEL, mask: uint)
			current_mask := (Get_Mask_Proc(imp_style_mask))(nswindow, sel_style_mask)
			NSWindowStyleMaskFullSizeContentView: uint : 1 << 15
			new_mask := current_mask | NSWindowStyleMaskFullSizeContentView
			(Set_Mask_Proc(imp_set_style_mask))(nswindow, sel_set_style_mask, new_mask)
		}

		// 2. titleVisibility = NSWindowTitleHidden (1)
		sel_set_title_vis := sel_registerName("setTitleVisibility:")
		imp_set_title_vis := class_getMethodImplementation(cls_win, sel_set_title_vis)
		if imp_set_title_vis != nil {
			Set_Title_Vis_Proc :: #type proc "c" (target: id, sel: SEL, vis: int)
			(Set_Title_Vis_Proc(imp_set_title_vis))(nswindow, sel_set_title_vis, 1)
		}

		// 3. titlebarAppearsTransparent = YES
		sel_set_transparent := sel_registerName("setTitlebarAppearsTransparent:")
		imp_set_transparent := class_getMethodImplementation(cls_win, sel_set_transparent)
		if imp_set_transparent != nil {
			Set_Transparent_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
			(Set_Transparent_Proc(imp_set_transparent))(nswindow, sel_set_transparent, true)
		}

		platform_setup_metal_layer(sdl_window)
		return true
	} else {
		return false
	}
}

when ODIN_OS == .Darwin {
	_platform_configure_metal_layer :: proc(v: id, cf_top_left: rawptr) {
		if v == nil do return
		cls_v := object_getClass(v)
		Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
		sel_layer := sel_registerName("layer")
		imp_layer := class_getMethodImplementation(cls_v, sel_layer)
		if imp_layer != nil {
			layer := (Get_Obj_Proc(imp_layer))(v, sel_layer)
			if layer != nil && cf_top_left != nil {
				cls_layer := object_getClass(layer)
				sel_set_gravity := sel_registerName("setContentsGravity:")
				imp_set_gravity := class_getMethodImplementation(cls_layer, sel_set_gravity)
				if imp_set_gravity != nil {
					Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, obj: id)
					(Set_Obj_Proc(imp_set_gravity))(layer, sel_set_gravity, id(cf_top_left))
				}
			}
		}
		sel_subviews := sel_registerName("subviews")
		imp_subviews := class_getMethodImplementation(cls_v, sel_subviews)
		if imp_subviews != nil {
			subviews := (Get_Obj_Proc(imp_subviews))(v, sel_subviews)
			if subviews != nil {
				cls_arr := object_getClass(subviews)
				sel_count := sel_registerName("count")
				sel_obj_at := sel_registerName("objectAtIndex:")
				imp_count := class_getMethodImplementation(cls_arr, sel_count)
				imp_obj_at := class_getMethodImplementation(cls_arr, sel_obj_at)
				if imp_count != nil && imp_obj_at != nil {
					Get_Count_Proc :: #type proc "c" (target: id, sel: SEL) -> uint
					Get_Obj_At_Proc :: #type proc "c" (target: id, sel: SEL, idx: uint) -> id
					cnt := (Get_Count_Proc(imp_count))(subviews, sel_count)
					for i in 0..<cnt {
						sub := (Get_Obj_At_Proc(imp_obj_at))(subviews, sel_obj_at, i)
						_platform_configure_metal_layer(sub, cf_top_left)
					}
				}
			}
		}
	}
}

// platform_setup_metal_layer anchors layer contents to topLeft so Core Animation
// does not bilinearly stretch stale frames during live window resize.
platform_setup_metal_layer :: proc(sdl_window: ^sdl3.Window) -> bool {
	when ODIN_OS == .Darwin {
		if sdl_window == nil do return false
		props := sdl3.GetWindowProperties(sdl_window)
		nswindow := id(sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil do return false
		cls_win := object_getClass(nswindow)

		sel_contentView := sel_registerName("contentView")
		imp_contentView := class_getMethodImplementation(cls_win, sel_contentView)
		if imp_contentView == nil do return false
		Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
		contentView := (Get_Obj_Proc(imp_contentView))(nswindow, sel_contentView)
		if contentView == nil do return false

		cf_top_left := CFStringCreateWithCString(nil, "topLeft", kCFStringEncodingUTF8)
		if cf_top_left != nil {
			defer CFRelease(cf_top_left)
		}

		_platform_configure_metal_layer(contentView, cf_top_left)
		return true
	} else {
		return false
	}
}

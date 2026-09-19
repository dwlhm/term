package window

// macOS platform-specific window configuration.
// Disables Apple Press and Hold to allow continuous key repeat events for terminal applications.
// Configures unified titlebar with full-size content view and hidden title for custom tab bar.

import "vendor:sdl3"

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

		return true
	} else {
		return false
	}
}

platform_show_close_tab_alert :: proc(sdl_window: ^Window, tab_title: string) -> bool {
	_ = sdl_window
	_ = tab_title
	when ODIN_OS == .Darwin {
		cls_alert := objc_getClass("NSAlert")
		if cls_alert == nil do return true

		sel_alloc := sel_registerName("alloc")
		sel_init := sel_registerName("init")
		sel_set_msg := sel_registerName("setMessageText:")
		sel_set_inf := sel_registerName("setInformativeText:")
		sel_add_btn := sel_registerName("addButtonWithTitle:")
		sel_set_style := sel_registerName("setAlertStyle:")
		sel_run_modal := sel_registerName("runModal")

		meta_alert := object_getClass(id(cls_alert))
		imp_alloc := class_getMethodImplementation(meta_alert, sel_alloc)
		if imp_alloc == nil do return true
		Alloc_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
		alert_inst := (Alloc_Proc(imp_alloc))(cls_alert, sel_alloc)
		if alert_inst == nil do return true

		imp_init := class_getMethodImplementation(object_getClass(alert_inst), sel_init)
		if imp_init == nil do return true
		Init_Proc :: #type proc "c" (inst: id, sel: SEL) -> id
		alert := (Init_Proc(imp_init))(alert_inst, sel_init)
		if alert == nil do return true

		cls_inst := object_getClass(alert)

		// Title: "Close Tab?"
		title_cf := CFStringCreateWithCString(nil, "Close Tab?", kCFStringEncodingUTF8)
		if title_cf != nil {
			defer CFRelease(title_cf)
			imp_msg := class_getMethodImplementation(cls_inst, sel_set_msg)
			if imp_msg != nil {
				Set_String_Proc :: #type proc "c" (inst: id, sel: SEL, str: rawptr)
				(Set_String_Proc(imp_msg))(alert, sel_set_msg, title_cf)
			}
		}

		// Informative text
		info_cf := CFStringCreateWithCString(nil, "Process is still running in this tab. Are you sure you want to close it?", kCFStringEncodingUTF8)
		if info_cf != nil {
			defer CFRelease(info_cf)
			imp_inf := class_getMethodImplementation(cls_inst, sel_set_inf)
			if imp_inf != nil {
				Set_String_Proc :: #type proc "c" (inst: id, sel: SEL, str: rawptr)
				(Set_String_Proc(imp_inf))(alert, sel_set_inf, info_cf)
			}
		}

		// Button 1 (Default): "Close Tab" (returns 1000)
		btn1_cf := CFStringCreateWithCString(nil, "Close Tab", kCFStringEncodingUTF8)
		if btn1_cf != nil {
			defer CFRelease(btn1_cf)
			imp_btn := class_getMethodImplementation(cls_inst, sel_add_btn)
			if imp_btn != nil {
				Add_Btn_Proc :: #type proc "c" (inst: id, sel: SEL, title: rawptr) -> id
				(Add_Btn_Proc(imp_btn))(alert, sel_add_btn, btn1_cf)
			}
		}

		// Button 2: "Cancel" (returns 1001)
		btn2_cf := CFStringCreateWithCString(nil, "Cancel", kCFStringEncodingUTF8)
		if btn2_cf != nil {
			defer CFRelease(btn2_cf)
			imp_btn := class_getMethodImplementation(cls_inst, sel_add_btn)
			if imp_btn != nil {
				Add_Btn_Proc :: #type proc "c" (inst: id, sel: SEL, title: rawptr) -> id
				(Add_Btn_Proc(imp_btn))(alert, sel_add_btn, btn2_cf)
			}
		}

		// Alert Style: NSAlertStyleWarning = 1
		imp_style := class_getMethodImplementation(cls_inst, sel_set_style)
		if imp_style != nil {
			Set_Style_Proc :: #type proc "c" (inst: id, sel: SEL, style: int)
			(Set_Style_Proc(imp_style))(alert, sel_set_style, 1)
		}

		// Run modal
		imp_run := class_getMethodImplementation(cls_inst, sel_run_modal)
		if imp_run != nil {
			Run_Proc :: #type proc "c" (inst: id, sel: SEL) -> int
			response := (Run_Proc(imp_run))(alert, sel_run_modal)

			// Aktifkan kembali jendela SDL agar langsung menjadi Key Window
			if sdl_window != nil && sdl_window.handle != nil {
				props := sdl3.GetWindowProperties(sdl_window.handle)
				nswindow := id(sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
				if nswindow != nil {
					cls_win := object_getClass(nswindow)
					sel_make_key := sel_registerName("makeKeyAndOrderFront:")
					imp_make_key := class_getMethodImplementation(cls_win, sel_make_key)
					if imp_make_key != nil {
						Make_Key_Proc :: #type proc "c" (target: id, sel: SEL, sender: id)
						(Make_Key_Proc(imp_make_key))(nswindow, sel_make_key, nil)
					}
				}
				sdl3.RaiseWindow(sdl_window.handle)
			}

			return response == 1000
		}

		return true
	} else {
		return true
	}
}


package platform_window

import "vendor:sdl3"

when ODIN_OS == .Darwin {
	foreign import libobjc "system:objc"
	foreign import CoreFoundation "system:CoreFoundation.framework"

	id :: distinct rawptr
	SEL :: distinct rawptr
	Class :: distinct rawptr
	BOOL :: bool

	kCFStringEncodingUTF8 :: 0x08000100
	APPLE_PRESS_AND_HOLD_ENABLED_KEY :: "ApplePressAndHoldEnabled"

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

	platform_disable_press_and_hold :: proc() {
		key_str := CFStringCreateWithCString(nil, APPLE_PRESS_AND_HOLD_ENABLED_KEY, kCFStringEncodingUTF8)
		if key_str == nil {
			return
		}
		defer CFRelease(key_str)

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

		CFPreferencesSetAppValue(key_str, kCFBooleanFalse, kCFPreferencesCurrentApplication)
		_ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
	}

	platform_disable_system_titlebar_double_click :: proc() {
		key_str := CFStringCreateWithCString(nil, "AppleActionOnDoubleClick", kCFStringEncodingUTF8)
		if key_str == nil do return
		defer CFRelease(key_str)

		val_str := CFStringCreateWithCString(nil, "None", kCFStringEncodingUTF8)
		if val_str == nil do return
		defer CFRelease(val_str)

		cls_user_defaults := objc_getClass("NSUserDefaults")
		if cls_user_defaults != nil {
			meta_cls := object_getClass(id(cls_user_defaults))
			sel_standard_user_defaults := sel_registerName("standardUserDefaults")
			sel_set_obj := sel_registerName("setObject:forKey:")

			imp_standard := class_getMethodImplementation(meta_cls, sel_standard_user_defaults)
			if imp_standard != nil {
				Get_Defaults_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
				defaults := (Get_Defaults_Proc(imp_standard))(cls_user_defaults, sel_standard_user_defaults)

				if defaults != nil {
					imp_set := class_getMethodImplementation(cls_user_defaults, sel_set_obj)
					if imp_set != nil {
						Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, value: rawptr, key: rawptr)
						(Set_Obj_Proc(imp_set))(defaults, sel_set_obj, val_str, key_str)
					}
				}
			}
		}

		CFPreferencesSetAppValue(key_str, val_str, kCFPreferencesCurrentApplication)
		_ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
	}

	platform_toggle_maximize :: proc(sdl_window: ^sdl3.Window) {
		if sdl_window == nil do return
		flags := sdl3.GetWindowFlags(sdl_window)
		if .MAXIMIZED in flags {
			sdl3.RestoreWindow(sdl_window)
		} else {
			sdl3.MaximizeWindow(sdl_window)
		}
	}

	platform_get_system_font_size :: proc() -> (size: f32, ok: bool) {
		cls_nsfont := objc_getClass("NSFont")
		if cls_nsfont == nil do return 0, false

		meta_cls := object_getClass(id(cls_nsfont))
		sel_system_size := sel_registerName("systemFontSize")
		imp := class_getMethodImplementation(meta_cls, sel_system_size)
		if imp == nil do return 0, false

		Get_Float_Proc :: #type proc "c" (cls: Class, sel: SEL) -> f64
		sz := (Get_Float_Proc(imp))(cls_nsfont, sel_system_size)
		if sz > 0 do return f32(sz), true
		return 0, false
	}

	_platform_configure_metal_layer :: proc(v: id, cf_top_left: rawptr, is_opaque: bool = false) {
		if v == nil do return
		cls_v := object_getClass(v)
		Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
		sel_layer := sel_registerName("layer")
		imp_layer := class_getMethodImplementation(cls_v, sel_layer)
		if imp_layer != nil {
			layer := (Get_Obj_Proc(imp_layer))(v, sel_layer)
			if layer != nil {
				cls_layer := object_getClass(layer)
				sel_set_gravity := sel_registerName("setContentsGravity:")
				if cf_top_left != nil {
					imp_set_gravity := class_getMethodImplementation(cls_layer, sel_set_gravity)
					if imp_set_gravity != nil {
						Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, obj: id)
						(Set_Obj_Proc(imp_set_gravity))(layer, sel_set_gravity, id(cf_top_left))
					}
				}

				sel_set_opaque := sel_registerName("setOpaque:")
				imp_set_opaque := class_getMethodImplementation(cls_layer, sel_set_opaque)
				if imp_set_opaque != nil {
					Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
					(Set_Bool_Proc(imp_set_opaque))(layer, sel_set_opaque, is_opaque)
				}

				sel_sublayers := sel_registerName("sublayers")
				imp_sublayers := class_getMethodImplementation(cls_layer, sel_sublayers)
				if imp_sublayers != nil {
					sublayers := (Get_Obj_Proc(imp_sublayers))(layer, sel_sublayers)
					if sublayers != nil {
						cls_arr := object_getClass(sublayers)
						sel_count := sel_registerName("count")
						sel_obj_at := sel_registerName("objectAtIndex:")
						imp_count := class_getMethodImplementation(cls_arr, sel_count)
						imp_obj_at := class_getMethodImplementation(cls_arr, sel_obj_at)
						if imp_count != nil && imp_obj_at != nil {
							Get_Count_Proc :: #type proc "c" (target: id, sel: SEL) -> uint
							Get_Obj_At_Proc :: #type proc "c" (target: id, sel: SEL, idx: uint) -> id
							cnt := (Get_Count_Proc(imp_count))(sublayers, sel_count)
							for i in 0..<cnt {
								sub_layer := (Get_Obj_At_Proc(imp_obj_at))(sublayers, sel_obj_at, i)
								if sub_layer != nil {
									cls_sub := object_getClass(sub_layer)
									if cf_top_left != nil {
										imp_sub_grav := class_getMethodImplementation(cls_sub, sel_set_gravity)
										if imp_sub_grav != nil {
											Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, obj: id)
											(Set_Obj_Proc(imp_sub_grav))(sub_layer, sel_set_gravity, id(cf_top_left))
										}
									}
									imp_sub_op := class_getMethodImplementation(cls_sub, sel_set_opaque)
									if imp_sub_op != nil {
										Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
										(Set_Bool_Proc(imp_sub_op))(sub_layer, sel_set_opaque, is_opaque)
									}
								}
							}
						}
					}
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
						_platform_configure_metal_layer(sub, cf_top_left, is_opaque)
					}
				}
			}
		}
	}

	platform_setup_metal_layer :: proc(sdl_window: ^sdl3.Window, is_opaque: bool = false) -> bool {
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

		_platform_configure_metal_layer(contentView, cf_top_left, is_opaque)
		return true
	}

	platform_setup_unified_titlebar :: proc(sdl_window: ^sdl3.Window) -> bool {
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
			NS_WINDOW_FULLSCREEN: uint : 1 << 14
			if current_mask & NS_WINDOW_FULLSCREEN != 0 {
				return false
			}
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
		platform_disable_system_titlebar_double_click()
		return true
	}

	platform_setup_window_vibrancy :: proc(sdl_window: ^sdl3.Window, enabled: bool) -> bool {
		if sdl_window == nil do return false
		props := sdl3.GetWindowProperties(sdl_window)
		nswindow := id(sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil do return false
		cls_win := object_getClass(nswindow)

		sel_set_opaque := sel_registerName("setOpaque:")
		imp_set_opaque := class_getMethodImplementation(cls_win, sel_set_opaque)
		if imp_set_opaque != nil {
			Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
			(Set_Bool_Proc(imp_set_opaque))(nswindow, sel_set_opaque, !enabled)
		}

		cls_nscolor := objc_getClass("NSColor")
		if cls_nscolor != nil {
			sel_clear_color := sel_registerName("clearColor")
			imp_clear_color := class_getMethodImplementation(object_getClass(id(cls_nscolor)), sel_clear_color)
			if imp_clear_color != nil {
				Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
				clear_color := (Get_Obj_Proc(imp_clear_color))(id(cls_nscolor), sel_clear_color)
				if clear_color != nil {
					sel_set_bg := sel_registerName("setBackgroundColor:")
					imp_set_bg := class_getMethodImplementation(cls_win, sel_set_bg)
					if imp_set_bg != nil {
						Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, obj: id)
						(Set_Obj_Proc(imp_set_bg))(nswindow, sel_set_bg, clear_color)
					}
				}
			}
		}

		sel_contentView := sel_registerName("contentView")
		imp_contentView := class_getMethodImplementation(cls_win, sel_contentView)
		if imp_contentView == nil do return false
		Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
		contentView := (Get_Obj_Proc(imp_contentView))(nswindow, sel_contentView)
		if contentView == nil do return false
		cls_cv := object_getClass(contentView)

		platform_setup_metal_layer(sdl_window, !enabled)

		cls_vev := objc_getClass("NSVisualEffectView")
		if cls_vev == nil do return false

		sel_subviews := sel_registerName("subviews")
		imp_subviews := class_getMethodImplementation(cls_cv, sel_subviews)
		if imp_subviews != nil {
			subviews := (Get_Obj_Proc(imp_subviews))(contentView, sel_subviews)
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
						if sub != nil && object_getClass(sub) == cls_vev {
							sel_set_hidden := sel_registerName("setHidden:")
							imp_set_hidden := class_getMethodImplementation(cls_vev, sel_set_hidden)
							if imp_set_hidden != nil {
								Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
								(Set_Bool_Proc(imp_set_hidden))(sub, sel_set_hidden, !enabled)
							}
							return true
						}
					}
				}
			}
		}

		if !enabled do return true

		sel_alloc := sel_registerName("alloc")
		imp_alloc := class_getMethodImplementation(object_getClass(id(cls_vev)), sel_alloc)
		if imp_alloc == nil do return false
		vev_alloc := (Get_Obj_Proc(imp_alloc))(id(cls_vev), sel_alloc)
		if vev_alloc == nil do return false

		NSRect :: struct {
			origin: [2]f64,
			size:   [2]f64,
		}
		sel_bounds := sel_registerName("bounds")
		imp_bounds := class_getMethodImplementation(cls_cv, sel_bounds)
		bounds: NSRect
		if imp_bounds != nil {
			Get_Rect_Proc :: #type proc "c" (target: id, sel: SEL) -> NSRect
			bounds = (Get_Rect_Proc(imp_bounds))(contentView, sel_bounds)
		}

		sel_initWithFrame := sel_registerName("initWithFrame:")
		imp_initWithFrame := class_getMethodImplementation(object_getClass(vev_alloc), sel_initWithFrame)
		if imp_initWithFrame == nil do return false
		Init_Frame_Proc :: #type proc "c" (target: id, sel: SEL, frame: NSRect) -> id
		vev := (Init_Frame_Proc(imp_initWithFrame))(vev_alloc, sel_initWithFrame, bounds)
		if vev == nil do return false

		cls_vev_inst := object_getClass(vev)

		// Material: 2 = UnderWindowBackground (native macOS vibrant blurred glass)
		sel_setMaterial := sel_registerName("setMaterial:")
		imp_setMaterial := class_getMethodImplementation(cls_vev_inst, sel_setMaterial)
		if imp_setMaterial != nil {
			Set_Int_Proc :: #type proc "c" (target: id, sel: SEL, val: int)
			(Set_Int_Proc(imp_setMaterial))(vev, sel_setMaterial, 2)
		}

		// BlendingMode: 0 = BehindWindow
		sel_setBlendingMode := sel_registerName("setBlendingMode:")
		imp_setBlendingMode := class_getMethodImplementation(cls_vev_inst, sel_setBlendingMode)
		if imp_setBlendingMode != nil {
			Set_Int_Proc :: #type proc "c" (target: id, sel: SEL, val: int)
			(Set_Int_Proc(imp_setBlendingMode))(vev, sel_setBlendingMode, 0)
		}

		// State: 1 = Active
		sel_setState := sel_registerName("setState:")
		imp_setState := class_getMethodImplementation(cls_vev_inst, sel_setState)
		if imp_setState != nil {
			Set_Int_Proc :: #type proc "c" (target: id, sel: SEL, val: int)
			(Set_Int_Proc(imp_setState))(vev, sel_setState, 1)
		}

		// AutoresizingMask: NSViewWidthSizable (2) | NSViewHeightSizable (16) = 18
		sel_setAutoresizingMask := sel_registerName("setAutoresizingMask:")
		imp_setAutoresizingMask := class_getMethodImplementation(cls_vev_inst, sel_setAutoresizingMask)
		if imp_setAutoresizingMask != nil {
			Set_Uint_Proc :: #type proc "c" (target: id, sel: SEL, val: uint)
			(Set_Uint_Proc(imp_setAutoresizingMask))(vev, sel_setAutoresizingMask, 18)
		}

		// Add subview positioned below all other views: NSWindowBelow = -1
		sel_addSubviewPositioned := sel_registerName("addSubview:positioned:relativeTo:")
		imp_addSubviewPositioned := class_getMethodImplementation(cls_cv, sel_addSubviewPositioned)
		if imp_addSubviewPositioned != nil {
			Add_Sub_Proc :: #type proc "c" (target: id, sel: SEL, view: id, pos: int, relativeTo: id)
			(Add_Sub_Proc(imp_addSubviewPositioned))(contentView, sel_addSubviewPositioned, vev, -1, nil)
		}

		return true
	}
}

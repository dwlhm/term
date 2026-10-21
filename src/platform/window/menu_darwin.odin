package platform_window

import "core:strings"
import "vendor:sdl3"

when ODIN_OS == .Darwin {
	foreign import libobjc "system:objc"
	foreign import CoreFoundation "system:CoreFoundation.framework"

	@(default_calling_convention="c")
	foreign libobjc {
		objc_allocateClassPair :: proc(superclass: Class, name: cstring, extraBytes: int) -> Class ---
		objc_registerClassPair :: proc(cls: Class) ---
		class_addMethod :: proc(cls: Class, name: SEL, imp: rawptr, types: cstring) -> BOOL ---
	}

	NSRect :: struct {
		origin: [2]f64,
		size:   [2]f64,
	}

	Release_Proc :: #type proc "c" (target: id, sel: SEL)
	@(private="file")
	g_menu_handler: id = nil
	@(private="file")
	g_selected_tag: int = 0

	@(private="file")
	_menu_item_action :: proc "c" (self: id, _cmd: SEL, sender: id) {
		if sender == nil do return
		cls_sender := object_getClass(sender)
		sel_tag := sel_registerName("tag")
		imp_tag := class_getMethodImplementation(cls_sender, sel_tag)
		if imp_tag != nil {
			Get_Tag_Proc :: #type proc "c" (target: id, sel: SEL) -> int
			g_selected_tag = (Get_Tag_Proc(imp_tag))(sender, sel_tag)
		}
	}

	@(private="file")
	_get_menu_handler :: proc() -> id {
		if g_menu_handler != nil do return g_menu_handler
		cls_handler := objc_getClass("TermNativeMenuHandler")
		if cls_handler == nil {
			cls_nsobject := objc_getClass("NSObject")
			cls_handler = objc_allocateClassPair(cls_nsobject, "TermNativeMenuHandler", 0)
			sel_action := sel_registerName("onMenuItemClicked:")
			_ = class_addMethod(cls_handler, sel_action, rawptr(_menu_item_action), "v@:@")
			objc_registerClassPair(cls_handler)
		}

		sel_alloc := sel_registerName("alloc")
		sel_init := sel_registerName("init")
		imp_alloc := class_getMethodImplementation(object_getClass(id(cls_handler)), sel_alloc)
		imp_init := class_getMethodImplementation(cls_handler, sel_init)
		if imp_alloc != nil && imp_init != nil {
			Alloc_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
			Init_Proc :: #type proc "c" (target: id, sel: SEL) -> id
			inst := (Alloc_Proc(imp_alloc))(cls_handler, sel_alloc)
			g_menu_handler = (Init_Proc(imp_init))(inst, sel_init)
		}
		return g_menu_handler
	}

	// platform_show_context_menu displays an authentic native macOS AppKit NSMenu
	// positioned at (x, y) relative to the SDL window's content view.
	// Returns the action_tag of the selected item, or 0 if cancelled.
	platform_show_context_menu :: proc(sdl_window: ^sdl3.Window, x, y: f32, items: []Platform_Menu_Item) -> int {
		if sdl_window == nil || len(items) == 0 do return 0
		props := sdl3.GetWindowProperties(sdl_window)
		nswindow := id(sdl3.GetPointerProperty(props, sdl3.PROP_WINDOW_COCOA_WINDOW_POINTER, nil))
		if nswindow == nil do return 0

		cls_win := object_getClass(nswindow)
		sel_contentView := sel_registerName("contentView")
		imp_contentView := class_getMethodImplementation(cls_win, sel_contentView)
		if imp_contentView == nil do return 0
		Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
		contentView := (Get_Obj_Proc(imp_contentView))(nswindow, sel_contentView)
		if contentView == nil do return 0

		cls_menu := objc_getClass("NSMenu")
		cls_item := objc_getClass("NSMenuItem")
		if cls_menu == nil || cls_item == nil do return 0

		handler := _get_menu_handler()
		sel_on_click := sel_registerName("onMenuItemClicked:")

		sel_alloc := sel_registerName("alloc")
		sel_initWithTitle := sel_registerName("initWithTitle:")
		imp_menu_alloc := class_getMethodImplementation(object_getClass(id(cls_menu)), sel_alloc)
		imp_menu_init := class_getMethodImplementation(cls_menu, sel_initWithTitle)
		if imp_menu_alloc == nil || imp_menu_init == nil do return 0

		Alloc_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
		Init_Title_Proc :: #type proc "c" (target: id, sel: SEL, title: id) -> id
		menu_alloc := (Alloc_Proc(imp_menu_alloc))(cls_menu, sel_alloc)
		cf_empty := CFStringCreateWithCString(nil, "", kCFStringEncodingUTF8)
		defer if cf_empty != nil do CFRelease(cf_empty)
		menu := (Init_Title_Proc(imp_menu_init))(menu_alloc, sel_initWithTitle, id(cf_empty))
		if menu == nil do return 0

		cls_menu_inst := object_getClass(menu)
		sel_release := sel_registerName("release")
		imp_release := class_getMethodImplementation(cls_menu_inst, sel_release)
		defer {
			if imp_release != nil {
				(Release_Proc(imp_release))(menu, sel_release)
			}
		}

		sel_setAutoenables := sel_registerName("setAutoenablesItems:")
		imp_setAutoenables := class_getMethodImplementation(cls_menu_inst, sel_setAutoenables)
		if imp_setAutoenables != nil {
			Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
			(Set_Bool_Proc(imp_setAutoenables))(menu, sel_setAutoenables, false)
		}

		sel_addItem := sel_registerName("addItem:")
		imp_addItem := class_getMethodImplementation(cls_menu_inst, sel_addItem)
		AddItem_Proc :: #type proc "c" (target: id, sel: SEL, item: id)

		sel_separator := sel_registerName("separatorItem")
		imp_separator := class_getMethodImplementation(object_getClass(id(cls_item)), sel_separator)

		sel_item_alloc := sel_registerName("alloc")
		sel_item_initWithTitle := sel_registerName("initWithTitle:action:keyEquivalent:")
		imp_item_alloc := class_getMethodImplementation(object_getClass(id(cls_item)), sel_item_alloc)
		imp_item_init := class_getMethodImplementation(cls_item, sel_item_initWithTitle)
		Init_Item_Proc :: #type proc "c" (target: id, sel: SEL, title: id, action: SEL, keyEq: id) -> id

		sel_setTarget := sel_registerName("setTarget:")
		sel_setTag := sel_registerName("setTag:")
		sel_setEnabled := sel_registerName("setEnabled:")
		sel_setModifierMask := sel_registerName("setKeyEquivalentModifierMask:")

		Set_Target_Proc :: #type proc "c" (target: id, sel: SEL, tgt: id)
		Set_Tag_Proc :: #type proc "c" (target: id, sel: SEL, tag: int)
		Set_Enabled_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
		Set_Mask_Proc :: #type proc "c" (target: id, sel: SEL, mask: uint)

		NSEventModifierFlagCommand: uint : 1 << 20
		NSEventModifierFlagShift:   uint : 1 << 17

		for it in items {
			if it.is_separator {
				if imp_separator != nil && imp_addItem != nil {
					sep := (Get_Obj_Proc(imp_separator))(id(cls_item), sel_separator)
					if sep != nil {
						(AddItem_Proc(imp_addItem))(menu, sel_addItem, sep)
					}
				}
				continue
			}

			cstr_title := strings.clone_to_cstring(it.title, context.temp_allocator)
			cf_title := CFStringCreateWithCString(nil, cstr_title, kCFStringEncodingUTF8)
			defer if cf_title != nil do CFRelease(cf_title)

			cstr_key := strings.clone_to_cstring(it.shortcut, context.temp_allocator)
			cf_key := CFStringCreateWithCString(nil, cstr_key, kCFStringEncodingUTF8)
			defer if cf_key != nil do CFRelease(cf_key)

			if imp_item_alloc != nil && imp_item_init != nil {
				it_alloc := (Alloc_Proc(imp_item_alloc))(cls_item, sel_item_alloc)
				it_obj := (Init_Item_Proc(imp_item_init))(it_alloc, sel_item_initWithTitle, id(cf_title), sel_on_click, id(cf_key))
				if it_obj != nil {
					cls_it_inst := object_getClass(it_obj)
					imp_target := class_getMethodImplementation(cls_it_inst, sel_setTarget)
					imp_tag := class_getMethodImplementation(cls_it_inst, sel_setTag)
					imp_enabled := class_getMethodImplementation(cls_it_inst, sel_setEnabled)

					if imp_target != nil do (Set_Target_Proc(imp_target))(it_obj, sel_setTarget, handler)
					if imp_tag != nil do (Set_Tag_Proc(imp_tag))(it_obj, sel_setTag, it.action_tag)
					if imp_enabled != nil do (Set_Enabled_Proc(imp_enabled))(it_obj, sel_setEnabled, it.enabled)

					mask := NSEventModifierFlagCommand
					if it.shift_mod do mask |= NSEventModifierFlagShift
					imp_mask := class_getMethodImplementation(cls_it_inst, sel_setModifierMask)
					if imp_mask != nil do (Set_Mask_Proc(imp_mask))(it_obj, sel_setModifierMask, mask)

					if imp_addItem != nil do (AddItem_Proc(imp_addItem))(menu, sel_addItem, it_obj)
					if imp_release != nil do (Release_Proc(imp_release))(it_obj, sel_release)
				}
			}
		}

		cls_cv := object_getClass(contentView)
		sel_bounds := sel_registerName("bounds")
		imp_bounds := class_getMethodImplementation(cls_cv, sel_bounds)
		bounds: NSRect
		if imp_bounds != nil {
			Get_Rect_Proc :: #type proc "c" (target: id, sel: SEL) -> NSRect
			bounds = (Get_Rect_Proc(imp_bounds))(contentView, sel_bounds)
		}

		sel_is_flipped := sel_registerName("isFlipped")
		imp_flipped := class_getMethodImplementation(cls_cv, sel_is_flipped)
		is_flipped := false
		if imp_flipped != nil {
			Flipped_Proc :: #type proc "c" (target: id, sel: SEL) -> BOOL
			is_flipped = bool((Flipped_Proc(imp_flipped))(contentView, sel_is_flipped))
		}

		location: [2]f64
		location.x = f64(x)
		location.y = f64(y) if is_flipped else (bounds.size[1] - f64(y))

		g_selected_tag = 0

		sel_popup := sel_registerName("popUpMenuPositioningItem:atLocation:inView:")
		imp_popup := class_getMethodImplementation(cls_menu_inst, sel_popup)
		if imp_popup != nil {
			PopUp_Proc :: #type proc "c" (target: id, sel: SEL, item: id, loc: [2]f64, view: id) -> BOOL
			_ = (PopUp_Proc(imp_popup))(menu, sel_popup, nil, location, contentView)
		}

		return g_selected_tag
	}
}

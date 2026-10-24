#+build darwin
package platform_window

// Native macOS Menu Bar Status Item (NSStatusItem)
// Platform Window Subsystem (src/platform/window/*).
//
// Invariant: Native Cocoa integration via direct Objective-C runtime calls.
// Zero third-party dependencies, zero memory allocations in steady-state polling.

import "core:c"
import "core:strings"

foreign import libobjc "system:objc"
foreign import Cocoa "system:Cocoa.framework"

@(private = "file")
BOOL :: bool

foreign libobjc {
	@(private = "file")
	objc_getClass                 :: proc(name: cstring) -> Class ---
	@(private = "file")
	object_getClass               :: proc(obj: id) -> Class ---
	@(private = "file")
	sel_registerName              :: proc(name: cstring) -> SEL ---
	@(private = "file")
	class_getMethodImplementation :: proc(cls: Class, sel: SEL) -> rawptr ---
}

@(private = "file")
Get_Obj_Proc :: #type proc "c" (target: id, sel: SEL) -> id
@(private = "file")
Get_Class_Obj_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
@(private = "file")
Make_Str_Proc :: #type proc "c" (cls: Class, sel: SEL, s: cstring) -> id
@(private = "file")
AddItem_Proc :: #type proc "c" (target: id, sel: SEL, title: id, action: SEL, key: id) -> id
@(private = "file")
Set_Obj_Proc :: #type proc "c" (target: id, sel: SEL, obj: id)
@(private = "file")
Set_Tag_Proc :: #type proc "c" (target: id, sel: SEL, tag: int)

@(private)
g_last_menu_bar_tag: int = 0
@(private)
g_menu_bar_handler: id = nil

@(private = "file")
_menu_bar_item_clicked :: proc "c" (self: id, _cmd: SEL, sender: id) {
	if sender == nil do return
	cls_sender := object_getClass(sender)
	sel_tag := sel_registerName("tag")
	imp_tag := class_getMethodImplementation(cls_sender, sel_tag)
	if imp_tag != nil {
		Get_Tag_Proc :: #type proc "c" (target: id, sel: SEL) -> int
		g_last_menu_bar_tag = (Get_Tag_Proc(imp_tag))(sender, sel_tag)
	}
}

@(private)
_get_menu_bar_handler :: proc() -> id {
	if g_menu_bar_handler != nil do return g_menu_bar_handler
	cls_handler := objc_getClass("TermMenuBarHandler")
	if cls_handler == nil {
		cls_nsobject := objc_getClass("NSObject")
		cls_handler = objc_allocateClassPair(cls_nsobject, "TermMenuBarHandler", 0)
		sel_action := sel_registerName("onMenuBarItemClicked:")
		_ = class_addMethod(cls_handler, sel_action, rawptr(_menu_bar_item_clicked), "v@:@")
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
		g_menu_bar_handler = (Init_Proc(imp_init))(inst, sel_init)
	}
	return g_menu_bar_handler
}

platform_menu_bar_take_action :: proc() -> int {
	tag := g_last_menu_bar_tag
	g_last_menu_bar_tag = 0
	return tag
}

platform_menu_bar_init :: proc() -> rawptr {
	cls_bar := objc_getClass("NSStatusBar")
	if cls_bar == nil do return nil
	sel_system := sel_registerName("systemStatusBar")
	imp_sys := class_getMethodImplementation(object_getClass(id(cls_bar)), sel_system)
	if imp_sys == nil do return nil
	bar := (Get_Class_Obj_Proc(imp_sys))(cls_bar, sel_system)
	if bar == nil do return nil

	sel_status_item := sel_registerName("statusItemWithLength:")
	imp_item := class_getMethodImplementation(object_getClass(bar), sel_status_item)
	if imp_item == nil do return nil
	Get_Item_Proc :: #type proc "c" (target: id, sel: SEL, len: f64) -> id
	status_item := (Get_Item_Proc(imp_item))(bar, sel_status_item, -1.0) // NSVariableStatusItemLength
	if status_item == nil do return nil

	// Set button title to icon
	sel_btn := sel_registerName("button")
	imp_btn := class_getMethodImplementation(object_getClass(status_item), sel_btn)
	if imp_btn != nil {
		button := (Get_Obj_Proc(imp_btn))(status_item, sel_btn)
		if button != nil {
			cls_str := objc_getClass("NSString")
			sel_utf8 := sel_registerName("stringWithUTF8String:")
			imp_utf8 := class_getMethodImplementation(object_getClass(id(cls_str)), sel_utf8)
			if imp_utf8 != nil {
				title_ns := (Make_Str_Proc(imp_utf8))(cls_str, sel_utf8, "● Term")
				sel_set_title := sel_registerName("setTitle:")
				imp_set_title := class_getMethodImplementation(object_getClass(button), sel_set_title)
				if imp_set_title != nil {
					(Set_Obj_Proc(imp_set_title))(button, sel_set_title, title_ns)
				}
			}
		}
	}

	return rawptr(status_item)
}

platform_menu_bar_update :: proc(handle: rawptr, header: string, items: []Platform_Menu_Bar_Item) {
	if handle == nil do return
	status_item := id(handle)

	cls_menu := objc_getClass("NSMenu")
	sel_alloc := sel_registerName("alloc")
	sel_init := sel_registerName("init")
	imp_alloc := class_getMethodImplementation(object_getClass(id(cls_menu)), sel_alloc)
	if imp_alloc == nil do return
	menu_raw := (Get_Class_Obj_Proc(imp_alloc))(cls_menu, sel_alloc)
	imp_init := class_getMethodImplementation(object_getClass(menu_raw), sel_init)
	if imp_init == nil do return
	menu := (Get_Obj_Proc(imp_init))(menu_raw, sel_init)
	if menu == nil do return

	cls_str := objc_getClass("NSString")
	sel_utf8 := sel_registerName("stringWithUTF8String:")
	imp_utf8 := class_getMethodImplementation(object_getClass(id(cls_str)), sel_utf8)
	if imp_utf8 == nil do return

	sel_add_item := sel_registerName("addItemWithTitle:action:keyEquivalent:")
	imp_add_item := class_getMethodImplementation(object_getClass(menu), sel_add_item)
	empty_ns := (Make_Str_Proc(imp_utf8))(cls_str, sel_utf8, "")

	// 1. Header item (disabled)
	header_cstr := strings.clone_to_cstring(header, context.temp_allocator)
	header_ns := (Make_Str_Proc(imp_utf8))(cls_str, sel_utf8, header_cstr)
	if imp_add_item != nil {
		h_item := (AddItem_Proc(imp_add_item))(menu, sel_add_item, header_ns, nil, empty_ns)
		if h_item != nil {
			sel_set_enabled := sel_registerName("setEnabled:")
			imp_set_enabled := class_getMethodImplementation(object_getClass(h_item), sel_set_enabled)
			if imp_set_enabled != nil {
				Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
				(Set_Bool_Proc(imp_set_enabled))(h_item, sel_set_enabled, false)
			}
		}
	}

	// 2. Separator
	sel_sep := sel_registerName("separatorItem")
	imp_sep := class_getMethodImplementation(object_getClass(id(objc_getClass("NSMenuItem"))), sel_sep)
	sel_add_obj := sel_registerName("addItem:")
	imp_add_obj := class_getMethodImplementation(object_getClass(menu), sel_add_obj)
	if imp_sep != nil && imp_add_obj != nil {
		sep := (Get_Class_Obj_Proc(imp_sep))(objc_getClass("NSMenuItem"), sel_sep)
		(Set_Obj_Proc(imp_add_obj))(menu, sel_add_obj, sep)
	}

	// 3. Dynamic items
	handler := _get_menu_bar_handler()
	sel_action := sel_registerName("onMenuBarItemClicked:")

	for it in items {
		if it.is_separator {
			if imp_sep != nil && imp_add_obj != nil {
				sep := (Get_Class_Obj_Proc(imp_sep))(objc_getClass("NSMenuItem"), sel_sep)
				(Set_Obj_Proc(imp_add_obj))(menu, sel_add_obj, sep)
			}
			continue
		}

		cstr := strings.clone_to_cstring(it.title, context.temp_allocator)
		ns_title := (Make_Str_Proc(imp_utf8))(cls_str, sel_utf8, cstr)
		if imp_add_item != nil {
			menu_item := (AddItem_Proc(imp_add_item))(menu, sel_add_item, ns_title, sel_action, empty_ns)
			if menu_item != nil {
				cls_it := object_getClass(menu_item)
				sel_target := sel_registerName("setTarget:")
				imp_target := class_getMethodImplementation(cls_it, sel_target)
				if imp_target != nil do (Set_Obj_Proc(imp_target))(menu_item, sel_target, handler)

				sel_tag := sel_registerName("setTag:")
				imp_tag := class_getMethodImplementation(cls_it, sel_tag)
				if imp_tag != nil do (Set_Tag_Proc(imp_tag))(menu_item, sel_tag, it.tag)

				if !it.is_enabled {
					sel_enabled := sel_registerName("setEnabled:")
					imp_enabled := class_getMethodImplementation(cls_it, sel_enabled)
					if imp_enabled != nil {
						Set_Bool_Proc :: #type proc "c" (target: id, sel: SEL, flag: BOOL)
						(Set_Bool_Proc(imp_enabled))(menu_item, sel_enabled, false)
					}
				}
			}
		}
	}

	// [status_item setMenu:menu]
	sel_set_menu := sel_registerName("setMenu:")
	imp_set_menu := class_getMethodImplementation(object_getClass(status_item), sel_set_menu)
	if imp_set_menu != nil {
		(Set_Obj_Proc(imp_set_menu))(status_item, sel_set_menu, menu)
	}
}

platform_menu_bar_destroy :: proc(handle: rawptr) {
	if handle == nil do return
	status_item := id(handle)

	cls_bar := objc_getClass("NSStatusBar")
	if cls_bar == nil do return
	sel_system := sel_registerName("systemStatusBar")
	imp_sys := class_getMethodImplementation(object_getClass(id(cls_bar)), sel_system)
	if imp_sys == nil do return
	bar := (Get_Class_Obj_Proc(imp_sys))(cls_bar, sel_system)
	if bar == nil do return

	sel_remove := sel_registerName("removeStatusItem:")
	imp_remove := class_getMethodImplementation(object_getClass(bar), sel_remove)
	if imp_remove != nil {
		(Set_Obj_Proc(imp_remove))(bar, sel_remove, status_item)
	}
}

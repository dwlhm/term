#+build darwin
package platform_window

import "core:testing"

foreign import AppKit "system:AppKit.framework"

foreign AppKit {
	NSApplicationLoad :: proc() -> bool ---
}

@(private = "file")
_create_test_nsmenuitem :: proc(tag: int) -> id {
	cls_item := objc_getClass("NSMenuItem")
	if cls_item == nil do return nil
	sel_alloc := sel_registerName("alloc")
	sel_init := sel_registerName("init")
	imp_alloc := class_getMethodImplementation(object_getClass(id(cls_item)), sel_alloc)
	imp_init := class_getMethodImplementation(cls_item, sel_init)
	if imp_alloc == nil || imp_init == nil do return nil

	Alloc_Proc :: #type proc "c" (cls: Class, sel: SEL) -> id
	Init_Proc :: #type proc "c" (target: id, sel: SEL) -> id
	item := (Init_Proc(imp_init))((Alloc_Proc(imp_alloc))(cls_item, sel_alloc), sel_init)
	if item == nil do return nil

	sel_set_tag := sel_registerName("setTag:")
	imp_set_tag := class_getMethodImplementation(cls_item, sel_set_tag)
	if imp_set_tag != nil {
		Set_Tag_Fn :: #type proc "c" (target: id, sel: SEL, tag: int)
		(Set_Tag_Fn(imp_set_tag))(item, sel_set_tag, tag)
	}
	return item
}

@test
test_menu_bar_handler_dispatch_roundtrip :: proc(t: ^testing.T) {
	_ = NSApplicationLoad()

	handler := _get_menu_bar_handler()
	testing.expect(t, handler != nil, "Menu bar handler must be initialized")

	cls_handler := object_getClass(handler)
	sel_action := sel_registerName("onMenuBarItemClicked:")
	imp_action := class_getMethodImplementation(cls_handler, sel_action)
	testing.expect(t, imp_action != nil, "onMenuBarItemClicked: implementation must exist")

	Action_Fn :: #type proc "c" (target: id, sel: SEL, sender: id)
	Release_Fn :: #type proc "c" (target: id, sel: SEL)

	item := _create_test_nsmenuitem(2042)
	testing.expect(t, item != nil, "NSMenuItem instance must be allocated")
	defer {
		sel_release := sel_registerName("release")
		if imp_rel := class_getMethodImplementation(object_getClass(item), sel_release); imp_rel != nil {
			(Release_Fn(imp_rel))(item, sel_release)
		}
	}

	// Dispatch Cocoa action message: [handler onMenuBarItemClicked:item]
	(Action_Fn(imp_action))(handler, sel_action, item)

	// Verify that the Cocoa runtime execution wrote tag 2042 to g_last_menu_bar_tag
	tag := platform_menu_bar_take_action()
	testing.expect_value(t, tag, 2042)
	testing.expect_value(t, platform_menu_bar_take_action(), 0)
}

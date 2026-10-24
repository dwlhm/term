package modals

// Interactive Session Safety Confirmation Dialog (Metal UI Modal Sheet)
// Part of core_chrome: Tier 1 Autonomous Core Primitives.
//
// Invariant: Two-way interactive state transfer between background and killed lists,
// collapsible killed section, and zero GPU dependencies in geometry generation.

import "base:runtime"

Session_Action_Choice :: enum u8 {
	Background,
	Kill,
}

Session_Dialog_Action :: enum u8 {
	None,
	Repaint,
	Cancel,
	Apply,
}

Dialog_Session_Item :: struct {
	session_id:    u32,
	tab_index:     int,
	pane_id:       u32,
	title:         string,
	process_name:  string,
	pid:           int,
	is_active_job: bool,
	status_msg:    string,
	choice:        Session_Action_Choice,
	// Interactive bounding boxes for hit testing
	btn_rect:      [4]f32,
}

Session_Dialog_State :: struct {
	items:           [dynamic]Dialog_Session_Item,
	killed_expanded: bool,
	visible:         bool,
	rect:            [4]f32,
	toggle_rect:     [4]f32,
	cancel_rect:     [4]f32,
	apply_rect:      [4]f32,
	allocator:       runtime.Allocator,
}

session_dialog_init :: proc(dlg: ^Session_Dialog_State, allocator := context.allocator) {
	if dlg == nil do return
	dlg.allocator = allocator
	dlg.items = make([dynamic]Dialog_Session_Item, allocator)
	dlg.killed_expanded = false
	dlg.visible = false
}

session_dialog_destroy :: proc(dlg: ^Session_Dialog_State) {
	if dlg == nil do return
	delete(dlg.items)
	dlg.items = nil
	dlg.visible = false
}

session_dialog_reset :: proc(dlg: ^Session_Dialog_State) {
	if dlg == nil do return
	clear(&dlg.items)
	dlg.killed_expanded = false
	dlg.visible = false
}

@(private = "file")
_pt_in_rect :: proc "contextless" (pt: [2]f32, rect: [4]f32) -> bool {
	return pt.x >= rect[0] && pt.x <= rect[0] + rect[2] &&
	       pt.y >= rect[1] && pt.y <= rect[1] + rect[3]
}

session_dialog_handle_click :: proc(dlg: ^Session_Dialog_State, mx, my: f32) -> Session_Dialog_Action {
	if dlg == nil || !dlg.visible do return .None
	pt := [2]f32{mx, my}

	if _pt_in_rect(pt, dlg.cancel_rect) do return .Cancel
	if _pt_in_rect(pt, dlg.apply_rect) do return .Apply

	if dlg.toggle_rect[2] > 0.0 && _pt_in_rect(pt, dlg.toggle_rect) {
		dlg.killed_expanded = !dlg.killed_expanded
		return .Repaint
	}

	for i in 0..<len(dlg.items) {
		item := &dlg.items[i]
		if item.btn_rect[2] > 0.0 && _pt_in_rect(pt, item.btn_rect) {
			if item.choice == .Background {
				item.choice = .Kill
			} else {
				item.choice = .Background
			}
			return .Repaint
		}
	}
	return .None
}

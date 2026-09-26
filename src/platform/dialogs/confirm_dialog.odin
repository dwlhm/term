package platform_dialogs

import input "../input"
import platform_tabs "../tabs"

// Rect_f32 defines a 2D floating-point rectangle.
Rect_f32 :: platform_tabs.Rect_f32

// point_in_rect performs a half-open bounding box check for (x, y) within r.
point_in_rect :: platform_tabs.point_in_rect

CONFIRM_DIALOG_WIDTH:         f32 : 340.0
CONFIRM_DIALOG_HEIGHT:        f32 : 130.0
CONFIRM_BTN_CANCEL_W:         f32 : 90.0
CONFIRM_BTN_CONFIRM_W:        f32 : 100.0
CONFIRM_BTN_HEIGHT:           f32 : 28.0
CONFIRM_BTN_CANCEL_OFFSET_X:  f32 : 210.0
CONFIRM_BTN_CONFIRM_OFFSET_X: f32 : 110.0
CONFIRM_BTN_OFFSET_Y:         f32 : 38.0

Confirm_Dialog_Action :: enum u8 {
	None = 0,
	Confirm,
	Cancel,
}

Confirm_Dialog_Target :: enum u8 {
	None = 0,
	Btn_Confirm,
	Btn_Cancel,
}

Confirm_Dialog_State :: struct {
	visible:        bool,
	rect:           Rect_f32,
	target_tab_idx: int,
	target_tab_id:  u32,
	confirm_rect:   Rect_f32,
	cancel_rect:    Rect_f32,
	hover_target:   Confirm_Dialog_Target,
}

confirm_dialog_init :: proc(state: ^Confirm_Dialog_State) {
	if state == nil do return
	state.visible = false
	state.rect = Rect_f32{}
	state.target_tab_idx = -1
	state.target_tab_id = 0
	state.confirm_rect = Rect_f32{}
	state.cancel_rect = Rect_f32{}
	state.hover_target = .None
}

// confirm_dialog_show opens the dialog for a tab.
confirm_dialog_show :: proc(state: ^Confirm_Dialog_State, target_idx: int, target_tab_id: u32 = 0) {
	if state == nil do return
	state.visible = true
	state.target_tab_idx = target_idx
	state.target_tab_id = target_tab_id
	state.hover_target = .None
}

confirm_dialog_hide :: proc(state: ^Confirm_Dialog_State) {
	if state == nil do return
	state.visible = false
	state.hover_target = .None
}

confirm_dialog_layout :: proc(state: ^Confirm_Dialog_State, window_w, window_h: f32) {
	if state == nil do return
	w := CONFIRM_DIALOG_WIDTH
	h := CONFIRM_DIALOG_HEIGHT
	x := max(0, (window_w - w) * 0.5)
	y := max(0, (window_h - h) * 0.5)
	state.rect = Rect_f32{x = x, y = y, w = w, h = h}

	state.cancel_rect = Rect_f32{
		x = x + w - CONFIRM_BTN_CANCEL_OFFSET_X,
		y = y + h - CONFIRM_BTN_OFFSET_Y,
		w = CONFIRM_BTN_CANCEL_W,
		h = CONFIRM_BTN_HEIGHT,
	}
	state.confirm_rect = Rect_f32{
		x = x + w - CONFIRM_BTN_CONFIRM_OFFSET_X,
		y = y + h - CONFIRM_BTN_OFFSET_Y,
		w = CONFIRM_BTN_CONFIRM_W,
		h = CONFIRM_BTN_HEIGHT,
	}
}

confirm_dialog_dispatch_pointer :: proc(state: ^Confirm_Dialog_State, px, py: f32, click: bool) -> (consumed: bool, action: Confirm_Dialog_Action) {
	if state == nil || !state.visible do return false, .None

	in_confirm := point_in_rect(px, py, state.confirm_rect)
	in_cancel  := point_in_rect(px, py, state.cancel_rect)

	if in_confirm {
		state.hover_target = .Btn_Confirm
	} else if in_cancel {
		state.hover_target = .Btn_Cancel
	} else {
		state.hover_target = .None
	}

	if click {
		if in_confirm {
			return true, .Confirm
		}
		if in_cancel {
			return true, .Cancel
		}
		if !point_in_rect(px, py, state.rect) {
			return true, .Cancel
		}
	}

	return true, .None
}

confirm_dialog_dispatch_key :: proc(state: ^Confirm_Dialog_State, ev: input.Input_Event) -> (consumed: bool, action: Confirm_Dialog_Action) {
	if state == nil || !state.visible do return false, .None
	if ev.is_release do return true, .None

	if ev.kind == .Enter || ev.rune == 'y' || ev.rune == 'Y' {
		return true, .Confirm
	}
	if ev.kind == .Escape || ev.rune == 'n' || ev.rune == 'N' {
		return true, .Cancel
	}
	return true, .None
}
